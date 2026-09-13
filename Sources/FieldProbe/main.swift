// FieldProbe -- a throwaway measurement tool for plan 20260912-dicta-focused-fields, Task 1 (F11).
//
// It is deleted once F11 is written; the commit that carried it is cited from SPEC.md instead.
// It runs as a LaunchAgent inside its own signed bundle, with the daemon's run-loop shape (a live
// main run loop holding the workspace observer, the work on background threads), because a probe
// launched from a terminal would measure the terminal's TCC grant rather than a bundle's.
// Commands arrive as text lines on a Unix socket (`Scripts/field-probe.sh` is the client).

import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

// MARK: - plumbing

let supportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/dev.personal.dicta.fieldprobe")
let socketPath = supportDir.appendingPathComponent("probe.sock").path
let expectedPath = supportDir.appendingPathComponent("last-typed.txt")

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(Date()) field-probe: \(message)\n".utf8))
}

func milliseconds(since start: DispatchTime) -> String {
    let nanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
    return String(format: "%.1f ms", Double(nanos) / 1_000_000)
}

func escaped(_ text: String) -> String {
    var out = ""
    for scalar in text.unicodeScalars {
        if scalar.value >= 0x20, scalar.value < 0x7F {
            out.unicodeScalars.append(scalar)
        } else {
            out += String(format: "\\u{%X}", scalar.value)
        }
    }
    return out
}

// MARK: - frontmost, observer-backed (F8a)

final class Frontmost: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (bundleID: String?, pid: pid_t, name: String?) = (nil, 0, nil)
    private var observer: NSObjectProtocol?

    init() {
        if let app = NSWorkspace.shared.frontmostApplication { store(app) }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            let key = NSWorkspace.applicationUserInfoKey
            if let app = note.userInfo?[key] as? NSRunningApplication {
                self?.store(app)
            }
        }
    }

    private func store(_ app: NSRunningApplication) {
        lock.lock()
        value = (app.bundleIdentifier, app.processIdentifier, app.localizedName)
        lock.unlock()
    }

    var current: (bundleID: String?, pid: pid_t, name: String?) {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

let frontmost = Frontmost()

// MARK: - AX

nonisolated(unsafe) let systemWide = AXUIElementCreateSystemWide()
nonisolated(unsafe) var savedElements: [String: AXUIElement] = [:]

func axErrorName(_ error: AXError) -> String {
    switch error {
    case .success: "success"
    case .failure: "failure"
    case .illegalArgument: "illegalArgument"
    case .invalidUIElement: "invalidUIElement"
    case .invalidUIElementObserver: "invalidUIElementObserver"
    case .cannotComplete: "cannotComplete"
    case .attributeUnsupported: "attributeUnsupported"
    case .actionUnsupported: "actionUnsupported"
    case .notificationUnsupported: "notificationUnsupported"
    case .notImplemented: "notImplemented"
    case .notificationAlreadyRegistered: "notificationAlreadyRegistered"
    case .notificationNotRegistered: "notificationNotRegistered"
    case .apiDisabled: "apiDisabled"
    case .noValue: "noValue"
    case .parameterizedAttributeUnsupported: "parameterizedAttributeUnsupported"
    case .notEnoughPrecision: "notEnoughPrecision"
    @unknown default: "unknown(\(error.rawValue))"
    }
}

func copyAttribute(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return (error, value)
}

func stringAttribute(_ element: AXUIElement, _ name: String) -> String {
    let (error, value) = copyAttribute(element, name)
    guard error == .success else { return "<\(axErrorName(error))>" }
    return (value as? String) ?? "<non-string>"
}

/// Metadata only: role, subrole, settability of the value, presence of a selected-text range.
/// The value itself and the selected text are never read.
func describe(_ element: AXUIElement) -> [String] {
    var pid: pid_t = 0
    let pidError = AXUIElementGetPid(element, &pid)
    var settable: DarwinBoolean = false
    let settableError = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString,
                                                       &settable)
    var names: CFArray?
    let namesError = AXUIElementCopyAttributeNames(element, &names)
    let nameList = (names as? [String]) ?? []
    return [
        "  element pid: \(pid) (\(axErrorName(pidError)))",
        "  role: \(stringAttribute(element, kAXRoleAttribute))",
        "  subrole: \(stringAttribute(element, kAXSubroleAttribute))",
        "  roleDescription: \(stringAttribute(element, kAXRoleDescriptionAttribute))",
        "  value settable: \(settable.boolValue) (\(axErrorName(settableError)))",
        "  has AXSelectedTextRange: \(nameList.contains(kAXSelectedTextRangeAttribute)) "
            + "(attribute names: \(axErrorName(namesError)), \(nameList.count) names)",
        "  has AXValue: \(nameList.contains(kAXValueAttribute)); "
            + "has AXEditable-ish AXInsertionPointLineNumber: "
            + "\(nameList.contains(kAXInsertionPointLineNumberAttribute))",
    ]
}

func focused(label: String?) -> [String] {
    var lines: [String] = []
    let front = frontmost.current
    lines.append("frontmost: \(front.bundleID ?? "nil") pid \(front.pid) \(front.name ?? "")")

    let start = DispatchTime.now()
    let (error, value) = copyAttribute(systemWide, kAXFocusedUIElementAttribute)
    lines.append("system-wide kAXFocusedUIElement: \(axErrorName(error)) "
        + "in \(milliseconds(since: start))")
    if error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
        let element = value as! AXUIElement // swiftlint:disable:this force_cast
        lines += describe(element)
    }

    let appElement = AXUIElementCreateApplication(front.pid)
    let appStart = DispatchTime.now()
    let (appError, appValue) = copyAttribute(appElement, kAXFocusedUIElementAttribute)
    lines.append("app-level kAXFocusedUIElement: \(axErrorName(appError)) "
        + "in \(milliseconds(since: appStart))")
    if appError == .success, let appValue, CFGetTypeID(appValue) == AXUIElementGetTypeID() {
        let element = appValue as! AXUIElement // swiftlint:disable:this force_cast
        lines += describe(element)
        if error == .success, let value {
            lines.append("  CFEqual to system-wide answer: \(CFEqual(value, element))")
        }
        for (name, saved) in savedElements.sorted(by: { $0.key < $1.key }) {
            lines.append("  CFEqual to saved '\(name)': \(CFEqual(saved, element))")
        }
        if let label {
            savedElements[label] = element
            lines.append("  saved as '\(label)'")
        }
    }
    return lines
}

func setAppAttribute(bundleID: String, attribute: String, on: Bool) -> [String] {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    guard !apps.isEmpty else { return ["no running application with bundle id \(bundleID)"] }
    return apps.map { app in
        let element = AXUIElementCreateApplication(app.processIdentifier)
        let flag = (on ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef
        let error = AXUIElementSetAttributeValue(element, attribute as CFString, flag)
        return "\(attribute)=\(on) on pid \(app.processIdentifier): \(axErrorName(error))"
    }
}

// MARK: - the text that gets typed

/// ~2000 characters: escaped Cyrillic, Latin, emoji, and the punctuation VS Code auto-closes or
/// treats as a suggestion commit character.
func sampleText(kind: String) -> String {
    let cyrillic = "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}, \u{044D}\u{0442}\u{043E} "
        + "\u{0442}\u{0435}\u{0441}\u{0442} \u{0434}\u{0438}\u{043A}\u{0442}\u{043E}\u{0432}"
        + "\u{043A}\u{0438}. "
    let latin = "FluidAudio and Package.swift go through the dictionary; "
    let punctuation = "call(foo.bar) with \"quotes\" and 'single' [brackets] {braces} <angle> "
    let emoji = "\u{1F600} \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} e\u{0301} "
    switch kind {
    case "ascii":
        return String(repeating: latin, count: 36).trimmingCharacters(in: .whitespaces)
    case "cyrillic":
        return String(repeating: cyrillic, count: 55).trimmingCharacters(in: .whitespaces)
    case "short":
        return cyrillic + latin + punctuation + emoji
    default:
        let unit = cyrillic + latin + punctuation + emoji
        var text = ""
        while text.count < 2000 { text += unit }
        return String(text.prefix(2000)).trimmingCharacters(in: .whitespaces)
    }
}

/// Greedy packing on Character boundaries up to `target` UTF-16 units.
func chunks(of text: String, target: Int) -> [String] {
    var result: [String] = []
    var current = ""
    var units = 0
    for character in text {
        let size = character.utf16.count
        if units + size > target, !current.isEmpty {
            result.append(current)
            current = ""
            units = 0
        }
        current.append(character)
        units += size
    }
    if !current.isEmpty { result.append(current) }
    return result
}

nonisolated(unsafe) let eventSource = CGEventSource(stateID: .privateState)

func post(_ chunk: String, pid: pid_t, hid: Bool, keycode: CGKeyCode) {
    let units = Array(chunk.utf16)
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: keycode,
                                  keyDown: down) else {
            continue
        }
        event.flags = []
        units.withUnsafeBufferPointer { buffer in
            event.keyboardSetUnicodeString(stringLength: buffer.count,
                                           unicodeString: buffer.baseAddress)
        }
        if hid {
            event.post(tap: .cghidEventTap)
        } else {
            event.postToPid(pid)
        }
    }
}

func type(delay: Double, target: Int, gapMs: Double, mode: String, kind: String,
          keycode: CGKeyCode) -> [String] {
    Thread.sleep(forTimeInterval: delay)
    let text = sampleText(kind: kind)
    try? text.write(to: expectedPath, atomically: true, encoding: .utf8)
    let front = frontmost.current
    let pieces = chunks(of: text, target: target)
    var switches = 0
    let start = DispatchTime.now()
    for (index, piece) in pieces.enumerated() {
        if index > 0 {
            if frontmost.current.pid != front.pid { switches += 1 }
            if gapMs > 0 { Thread.sleep(forTimeInterval: gapMs / 1000) }
        }
        post(piece, pid: front.pid, hid: mode == "hid", keycode: keycode)
    }
    return [
        "typed into: \(front.bundleID ?? "nil") pid \(front.pid) \(front.name ?? "")",
        "mode \(mode), keycode \(keycode), text \(kind): \(text.count) characters, "
            + "\(text.utf16.count) UTF-16 units, \(pieces.count) chunks of <= \(target), "
            + "gap \(gapMs) ms",
        "posting took \(milliseconds(since: start)); "
            + "frontmost pid differed before \(switches) chunks",
        "select the field's text, copy it, then run: compare",
    ]
}

// MARK: - compare against the pasteboard

func compare() -> [String] {
    guard let expected = try? String(contentsOf: expectedPath, encoding: .utf8) else {
        return ["nothing typed yet"]
    }
    let pasted = NSPasteboard.general.string(forType: .string) ?? ""
    let expectedChars = Array(expected)
    let pastedChars = Array(pasted)
    if expectedChars == pastedChars { return ["IDENTICAL: \(expectedChars.count) characters"] }

    // LCS over characters, to count what was lost and what was added.
    let rows = expectedChars.count, cols = pastedChars.count
    var previous = [Int](repeating: 0, count: cols + 1)
    var current = previous
    for i in 1 ... max(rows, 1) where rows > 0 {
        for j in 1 ... max(cols, 1) where cols > 0 {
            current[j] = expectedChars[i - 1] == pastedChars[j - 1]
                ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
        }
        swap(&previous, &current)
    }
    let common = previous[cols]
    var firstDiff = 0
    while firstDiff < min(rows, cols), expectedChars[firstDiff] == pastedChars[firstDiff] {
        firstDiff += 1
    }
    let context = { (chars: [Character]) -> String in
        let from = max(0, firstDiff - 15), to = min(chars.count, firstDiff + 30)
        return from < to ? escaped(String(chars[from ..< to])) : ""
    }
    return [
        "DIFFERENT: expected \(rows) characters, pasteboard has \(cols)",
        "lost \(rows - common), added \(cols - common) (by longest common subsequence)",
        "first difference at character \(firstDiff)",
        "  expected: \(context(expectedChars))",
        "  got:      \(context(pastedChars))",
    ]
}

// MARK: - held-combination durations

func holds(seconds: Double) -> [String] {
    let bits: [(String, UInt64)] = [
        ("right Command", 0x10), ("right Control", 0x2000), ("left Command", 0x8),
    ]
    var downSince: [String: DispatchTime] = [:]
    var durations: [String: [Double]] = [:]
    let end = DispatchTime.now() + seconds
    while DispatchTime.now() < end {
        let flags = CGEventSource.flagsState(.combinedSessionState).rawValue
        for (name, bit) in bits {
            let down = flags & bit != 0
            if down, downSince[name] == nil { downSince[name] = .now() }
            if !down, let since = downSince.removeValue(forKey: name) {
                durations[name, default: []].append(
                    Double(DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds)
                        / 1_000_000)
            }
        }
        Thread.sleep(forTimeInterval: 0.016)
    }
    return bits.map { name, _ in
        let list = durations[name] ?? []
        let over = list.filter { $0 >= 300 }.count
        let rendered = list.map { String(format: "%.0f", $0) }.joined(separator: " ")
        return "\(name): \(list.count) holds, \(over) >= 300 ms: [\(rendered)]"
    }
}

// MARK: - commands

func handle(_ line: String) -> [String] {
    let words = line.split(separator: " ").map(String.init)
    guard let command = words.first else { return [] }
    let args = Array(words.dropFirst())
    func string(_ index: Int, _ fallback: String) -> String {
        index < args.count ? args[index] : fallback
    }
    func double(_ index: Int, _ fallback: Double) -> Double {
        Double(string(index, "")) ?? fallback
    }
    func int(_ index: Int, _ fallback: Int) -> Int { Int(string(index, "")) ?? fallback }

    switch command {
    case "ping":
        let front = frontmost.current
        return [
            "bundle \(Bundle.main.bundleIdentifier ?? "nil"), pid \(getpid())",
            "executable \(Bundle.main.executablePath ?? "?")",
            "main thread run loop mode: "
                + (RunLoop.main.currentMode?.rawValue ?? "none (not inside run)"),
            "frontmost: \(front.bundleID ?? "nil") pid \(front.pid)",
        ]
    case "trust":
        return [
            "AXIsProcessTrusted: \(AXIsProcessTrusted())",
            "CGPreflightPostEventAccess: \(CGPreflightPostEventAccess())",
            "CGPreflightListenEventAccess: \(CGPreflightListenEventAccess()) (reported only)",
        ]
    case "prompt-ax":
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return ["AXIsProcessTrustedWithOptions(prompt): \(AXIsProcessTrustedWithOptions(options))"]
    case "request-post":
        return ["CGRequestPostEventAccess: \(CGRequestPostEventAccess())"]
    case "secure":
        let background = IsSecureEventInputEnabled()
        let onMain = DispatchQueue.main.sync { IsSecureEventInputEnabled() }
        return ["IsSecureEventInputEnabled: background thread \(background), main thread \(onMain)"]
    case "front":
        let front = frontmost.current
        let direct = NSWorkspace.shared.frontmostApplication
        return [
            "observer: \(front.bundleID ?? "nil") pid \(front.pid) \(front.name ?? "")",
            "direct:   \(direct?.bundleIdentifier ?? "nil") pid \(direct?.processIdentifier ?? 0)",
        ]
    case "timeout":
        let seconds = Float(double(0, 0.25))
        return ["AXUIElementSetMessagingTimeout(system-wide, \(seconds)): "
            + axErrorName(AXUIElementSetMessagingTimeout(systemWide, seconds))]
    case "focus":
        Thread.sleep(forTimeInterval: double(0, 3))
        return focused(label: args.count > 1 ? args[1] : nil)
    case "forget":
        savedElements.removeAll()
        return ["saved elements cleared"]
    case "attr":
        guard args.count >= 3 else { return ["usage: attr <bundle-id> <attribute> on|off"] }
        return setAppAttribute(bundleID: args[0], attribute: args[1], on: args[2] == "on")
    case "type":
        return type(delay: double(0, 3), target: int(1, 20), gapMs: double(2, 0),
                    mode: string(3, "pid"),
                    kind: string(4, "mixed"), keycode: CGKeyCode(int(5, 0)))
    case "compare":
        return compare()
    case "sound":
        let name = string(0, "Pop")
        if string(1, "nssound") == "afplay" {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            process.arguments = ["/System/Library/Sounds/\(name).aiff"]
            do { try process.run() } catch { return ["afplay failed: \(error)"] }
            process.waitUntilExit()
            return ["afplay \(name): exit \(process.terminationStatus) -- did you hear it?"]
        }
        guard let sound = NSSound(named: NSSound.Name(name)) else {
            return ["NSSound(named: \(name)) is nil"]
        }
        let started = sound.play()
        Thread.sleep(forTimeInterval: 1)
        return ["NSSound \(name) play() returned \(started) -- did you hear it?"]
    case "notify":
        let text = args.isEmpty ? "field probe notification" : args.joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \"\(text)\" with title \"dicta probe\""]
        let errors = Pipe()
        process.standardError = errors
        do { try process.run() } catch { return ["osascript failed to launch: \(error)"] }
        process.waitUntilExit()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: data, encoding: .utf8) ?? ""
        return ["osascript exit \(process.terminationStatus) \(stderr) -- did one appear?"]
    case "holds":
        return holds(seconds: double(0, 30))
    default:
        return ["unknown command: \(command)"]
    }
}

// MARK: - the socket

func serve() {
    try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    unlink(socketPath)
    let server = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        let target = buffer.baseAddress!.assumingMemoryBound(to: CChar.self)
        _ = socketPath.withCString { strncpy(target, $0, buffer.count - 1) }
    }
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bound == 0, listen(server, 4) == 0 else {
        log("cannot listen on \(socketPath): \(String(cString: strerror(errno)))")
        exit(1)
    }
    log("listening on \(socketPath)")
    while true {
        let client = accept(server, nil, nil)
        guard client >= 0 else { continue }
        var data = Data()
        var byte: UInt8 = 0
        while read(client, &byte, 1) == 1, byte != 10 { data.append(byte) }
        let line = String(data: data, encoding: .utf8) ?? ""
        log("command: \(line)")
        let reply = handle(line).joined(separator: "\n") + "\n"
        _ = reply.withCString { write(client, $0, strlen($0)) }
        close(client)
    }
}

let server = Thread { serve() }
server.name = "field-probe.server"
server.start()
RunLoop.main.run()
