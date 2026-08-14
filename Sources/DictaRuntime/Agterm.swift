import DictaCore
import Foundation

// The adapter over `agtermctl`: the only place in the project that knows agterm's command line.
//
// Everything it does is one of four things -- resolve a target from the live tree, type into it,
// set an indicator, post a notification -- and all four go through a `CommandRunner` seam
// rather than through `Process` directly. That seam is not ceremony: the rules worth asserting here
// are what happens when the tree names no pane, or two, or when `agtermctl` is not installed,
// and none of those can be produced on demand from a live terminal.
//
// Fail closed, everywhere (D6). A target this file cannot name exactly is not a target it guesses
// at: the alternative is somebody else's agent receiving the user's prompt (D4, invariant 3).

/// What one `agtermctl` invocation produced.
public struct CommandOutput: Sendable, Equatable {
    public var status: Int32
    public var standardOutput: String
    public var standardError: String

    public init(status: Int32, standardOutput: String = "", standardError: String = "") {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var succeeded: Bool { status == 0 }
}

/// Running a subprocess, behind a seam so the tests can hand back canned trees and canned failures.
public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput
}

/// Everything the agterm side can refuse to do, in the words the user reads.
public enum AgtermError: Error, Equatable, CustomStringConvertible {
    /// Not installed, or not where it was last seen. §7's loudest configuration failure: every
    /// chord is dead until it is fixed.
    case executableMissing(String)
    case launchFailed(verb: String, reason: String)
    /// The child ran past `ProcessRunner.deadline` and was killed. Its own case rather than a
    /// `launchFailed`, because the two answer opposite questions about the input line: nothing was
    /// launched versus something ran and where it got to is unknown.
    case timedOut(verb: String, seconds: TimeInterval)
    case commandFailed(verb: String, status: Int32, message: String)
    case malformedTree(String)
    case sessionNotFound(String)
    /// The tree names no active pane for the session. The attempt does not start (D6).
    case noActivePane(session: String)
    /// More than one. Picking one would be a coin flip with the user's prompt as the stake.
    case ambiguousPane(session: String, panes: [String])
    /// Exactly one, of a kind this build does not know. Accepting it would be D4's forbidden
    /// substitution wearing a different hat.
    case unrecognisedPane(session: String, kind: String)

    public var description: String {
        switch self {
        case let .executableMissing(path):
            "agtermctl is not installed at \(path) -- dicta cannot reach agterm"
        case let .launchFailed(verb, reason):
            "agtermctl \(verb) could not be run: \(reason)"
        case let .timedOut(verb, seconds):
            "agtermctl \(verb) did not answer within \(Int(seconds)) s -- agterm is not responding"
        case let .commandFailed(verb, status, message):
            message.isEmpty
                ? "agtermctl \(verb) failed with status \(status)"
                : "agtermctl \(verb) failed: \(message)"
        case let .malformedTree(detail):
            "agterm's session tree could not be read: \(detail)"
        case let .sessionNotFound(session):
            "session \(session) is gone"
        case let .noActivePane(session):
            "session \(session) has no active pane -- refusing to guess where the text goes"
        case let .ambiguousPane(session, panes):
            "session \(session) has \(panes.count) active panes (\(panes.joined(separator: ", ")))"
                + " -- refusing to guess where the text goes"
        case let .unrecognisedPane(session, kind):
            "session \(session)'s active pane is a \(kind), which this build does not know"
        }
    }
}

/// A pane as the tree describes it, before it is known to be one dicta can type into.
struct TreeSurface: Equatable {
    var kind: String
    var active: Bool
}

/// `agtermctl`, adapted.
public struct Agterm: Injector, Notifier, Sendable {
    /// Where the tool is looked for, in order. A LaunchAgent's PATH is not a login shell's, so the
    /// absolute paths come first and `PATH` is only the fallback (§12).
    public static let candidatePaths = ["/opt/homebrew/bin/agtermctl", "/usr/local/bin/agtermctl"]

    /// §6's colours. Red for listening, amber for working -- the indicator's default tint says
    /// "an agent is busy", which is precisely the state dicta must not be confused with.
    static let listeningColor = "#FF3B30"
    static let workingColor = "#FFB100"

    public let executable: String
    /// `$AGT_SOCKET` from the keypress, so a non-default agterm instance still resolves rather than
    /// whichever instance answers the default socket first.
    public let agtermSocket: String?
    private let runner: any CommandRunner

    public init(executable: String? = nil,
                agtermSocket: String? = nil,
                runner: any CommandRunner = ProcessRunner()) {
        self.executable = executable ?? Agterm.locate() ?? Agterm.candidatePaths[0]
        self.agtermSocket = agtermSocket
        self.runner = runner
    }

    /// The first `agtermctl` that exists, or `nil` when there is none anywhere -- which is a
    /// startup-time diagnosis, not something to discover on the first chord.
    ///
    /// The candidate list is a parameter so this has a test: on the machine that runs the suite,
    /// `/opt/homebrew/bin/agtermctl` exists, and a lookup that always finds it asserts nothing.
    public static func locate(
        candidates: [String] = Agterm.candidatePaths,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let searchPath = (environment["PATH"] ?? "").split(separator: ":").map {
            "\($0)/agtermctl"
        }
        return (candidates + searchPath).first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    // MARK: - target resolution (§5, D6)

    /// The session id is keypress-accurate; the pane is live focus roughly 40 ms later (F4, §5).
    /// This is where that second half is decided, and where it is refused.
    public func resolveTarget(sessionID: String) throws -> Target {
        let surfaces = try surfaces(ofSession: sessionID)
        let active = surfaces.filter(\.active)
        guard active.count == 1 else {
            throw active.isEmpty
                ? AgtermError.noActivePane(session: sessionID)
                : AgtermError.ambiguousPane(session: sessionID, panes: active.map(\.kind))
        }
        guard let pane = Pane(rawValue: active[0].kind) else {
            throw AgtermError.unrecognisedPane(session: sessionID, kind: active[0].kind)
        }
        return Target(sessionID: sessionID, pane: pane)
    }

    /// Re-validation immediately before injection (§5, D4).
    ///
    /// Both halves, and only existence: the pane does not have to still be FOCUSED. Focus having
    /// moved to the sibling pane is not a reason to follow it -- the text belongs where the user
    /// was when they started speaking, and re-aiming is the one thing invariant 3 forbids.
    public func validate(_ target: Target) throws {
        let surfaces: [TreeSurface]
        do {
            surfaces = try self.surfaces(ofSession: target.sessionID)
        } catch {
            // Including "agtermctl is not installed any more": whatever the reason, the target
            // cannot be confirmed, and an unconfirmed target is never typed into (invariant 3).
            throw DeliveryFailure.targetGone(target, reason: Self.reason(error))
        }
        guard surfaces.contains(where: { $0.kind == target.pane.rawValue }) else {
            throw DeliveryFailure.targetGone(
                target,
                reason: "the \(target.pane.rawValue) pane of \(target.sessionID) is gone"
            )
        }
    }

    private func surfaces(ofSession sessionID: String) throws -> [TreeSurface] {
        let output = try invoke("tree", ["tree", "--json"])
        guard output.succeeded else {
            throw AgtermError.commandFailed(verb: "tree", status: output.status,
                                            message: Self.message(in: output))
        }
        return try Self.surfaces(inTree: output.standardOutput, session: sessionID)
    }

    // MARK: - injection

    /// Types **final** into the captured target. The text arrives after `--`, so a dictation that
    /// begins with a dash is text and not a flag.
    ///
    /// What is NOT here: a retry. §7 is explicit -- a retry after keystrokes have begun doubles
    /// part of the text, and the user is told the insertion may be partial instead.
    public func inject(_ text: String, into target: Target) throws {
        try validate(target)

        let arguments = ["session", "type", "--pane", target.pane.rawValue,
                         "--target", target.sessionID, "--json", "--", text]
        let output: CommandOutput
        do {
            output = try invoke("session type", arguments)
        } catch let error as AgtermError {
            if case .timedOut = error {
                // The one failure on this path that may NOT claim the input line is untouched:
                // `agtermctl` ran, typed for as long as it liked, and was killed at the deadline.
                // Where it got to is what nobody knows -- §7's own words for `mayBePartial`.
                throw DeliveryFailure.mayBePartial(target, reason: Self.reason(error))
            }
            // Nothing was launched, so no keystroke can have been delivered. This is the one
            // delivery failure that may honestly claim the input line is untouched.
            throw DeliveryFailure.notStarted(target, reason: Self.reason(error))
        } catch {
            throw DeliveryFailure.notStarted(target, reason: Self.reason(error))
        }
        if output.succeeded { return }
        if let refusal = Self.refusal(in: output) {
            // agterm answered `{"ok":false}`: it decided not to type, before typing anything.
            throw DeliveryFailure.notStarted(target, reason: refusal)
        }
        // It neither typed nor refused cleanly -- it died partway through, and where it got to is
        // exactly what nobody knows. §7 makes that its own row for that reason.
        throw DeliveryFailure.mayBePartial(
            target,
            reason: "agtermctl session type exited with status \(output.status)"
        )
    }

    // MARK: - feedback (§6)

    public func announce(_ feedback: Feedback, for target: Target) {
        _ = try? invoke("session status", Self.statusArguments(feedback, target: target))
    }

    /// Best effort by design, and loud by preference: if agterm cannot show it, `osascript` can.
    /// agterm may be the very thing that is broken, and §7's point is that the user finds out.
    public func notify(_ message: String, for target: Target?) {
        // After `--`, for the same reason `inject` is: a message is not always a fixed literal --
        // `commandFailed` carries agtermctl's own stderr and `loadFailed` an arbitrary error
        // description -- and one that begins with a dash would be eaten as a flag. §7's whole
        // premise is that these are the failures nobody is watching, so losing one is the worst
        // outcome available.
        var arguments = ["notify", "--title", "dicta"]
        if let target { arguments += ["--target", target.sessionID] }
        arguments += ["--", message]
        if let output = try? invoke("notify", arguments), output.succeeded { return }
        let script = "display notification \(Self.quoted(message)) with title \"dicta\""
        _ = try? runner.run("/usr/bin/osascript", ["-e", script])
    }

    public func clearIndicator(for target: Target) {
        _ = try? invoke("session status", ["session", "status", "idle",
                                           "--pane", target.pane.rawValue,
                                           "--target", target.sessionID])
    }

    static func statusArguments(_ feedback: Feedback, target: Target) -> [String] {
        var arguments = ["session", "status"]
        switch feedback {
        case .listening:
            arguments += ["active", "--blink", "--sound", "Pop", "--color", listeningColor]
        case .working:
            arguments += ["active", "--color", workingColor]
        case .done:
            arguments += ["completed", "--auto-reset", "--sound", "Tink"]
        case .blocked:
            // Always paired with a notification carrying the reason: an indicator that goes red
            // with nothing to read is "lost silently" wearing a colour.
            arguments += ["blocked", "--sound", "Basso"]
        }
        return arguments + ["--pane", target.pane.rawValue, "--target", target.sessionID]
    }

    // MARK: - running it

    private func invoke(_ verb: String, _ arguments: [String]) throws -> CommandOutput {
        let arguments = Self.withSocket(agtermSocket, in: arguments)
        do {
            return try runner.run(executable, arguments)
        } catch let AgtermError.timedOut(_, seconds) {
            // The runner knows only the executable; the verb is what the user needs to read, and
            // `inject` needs the case to survive intact to classify the delivery.
            throw AgtermError.timedOut(verb: verb, seconds: seconds)
        } catch let error as AgtermError {
            throw error
        } catch {
            throw AgtermError.launchFailed(verb: verb, reason: "\(error)")
        }
    }

    /// `--socket` goes BEFORE the `--` separator, never after it.
    ///
    /// Everything past `--` is positional, and `agtermctl session type` declares exactly one
    /// positional. Appending the socket at the end therefore turned every injection into
    /// `Error: 2 unexpected arguments: '--socket', '…'` -- and since that exit carries no
    /// `{"ok":false}`, `refusal(in:)` reads nothing and the failure reports as `mayBePartial`:
    /// the user is warned the insertion may be partial when in truth not one keystroke was sent.
    /// The keymap snippet passes `--socket "$AGT_SOCKET"`, so this was the normal path.
    static func withSocket(_ socket: String?, in arguments: [String]) -> [String] {
        guard let socket else { return arguments }
        guard let separator = arguments.firstIndex(of: "--") else {
            return arguments + ["--socket", socket]
        }
        var spliced = arguments
        spliced.insert(contentsOf: ["--socket", socket], at: separator)
        return spliced
    }

    // MARK: - reading what came back

    /// agterm's own sentence, when it produced one. Its JSON error beats stderr: it names the thing
    /// that went wrong ("no such session: …") rather than describing a failed process.
    static func message(in output: CommandOutput) -> String {
        if let refusal = refusal(in: output) { return refusal }
        let stderr = output.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr.isEmpty
            ? output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            : stderr
    }

    /// `{"ok":false,"error":"…"}` -- a deliberate refusal, as opposed to a process that fell over.
    /// The difference decides whether the user is told the input line is untouched.
    static func refusal(in output: CommandOutput) -> String? {
        guard let data = output.standardOutput.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ok"] as? Bool == false
        else { return nil }
        return (object["error"] as? String) ?? "agterm refused the command"
    }

    static func reason(_ error: any Error) -> String {
        (error as? AgtermError)?.description ?? "\(error)"
    }

    /// An AppleScript string literal. The line breaks matter: a raw newline inside one is a syntax
    /// error, so a multi-line reason -- agtermctl's stderr, most of the time -- would lose the
    /// notification on the very path that exists because agterm is already broken.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    // MARK: - the tree

    /// Only the fields target resolution reads. Everything else agterm sends -- titles, cwds, font
    /// sizes -- is ignored on purpose: a decoder that insisted on the whole payload would break on
    /// the next agterm release for no gain.
    private struct TreeEnvelope: Decodable {
        struct Envelope: Decodable { let tree: Tree }
        struct Tree: Decodable { let workspaces: [Workspace] }
        struct Workspace: Decodable { let sessions: [Session]? }
        struct Session: Decodable {
            let id: String
            let surfaces: [Surface]?
        }

        struct Surface: Decodable {
            let kind: String
            let active: Bool?
        }

        let ok: Bool?
        let error: String?
        let result: Envelope?
    }

    /// Pure, so every shape of tree in `AgtermTests` is a value rather than a running terminal.
    static func surfaces(inTree json: String, session: String) throws -> [TreeSurface] {
        guard let data = json.data(using: .utf8), !data.isEmpty else {
            throw AgtermError.malformedTree("agtermctl tree printed nothing")
        }
        let envelope: TreeEnvelope
        do {
            envelope = try JSONDecoder().decode(TreeEnvelope.self, from: data)
        } catch {
            throw AgtermError.malformedTree("the output is not the JSON tree this build expects")
        }
        if envelope.ok == false {
            throw AgtermError.commandFailed(verb: "tree", status: 0,
                                            message: envelope.error ?? "agterm refused to answer")
        }
        guard let result = envelope.result else {
            throw AgtermError.malformedTree("the answer carries no tree")
        }
        let sessions = result.tree.workspaces.flatMap { $0.sessions ?? [] }
        guard let found = sessions.first(where: { $0.id == session }) else {
            throw AgtermError.sessionNotFound(session)
        }
        return (found.surfaces ?? []).map {
            TreeSurface(kind: $0.kind, active: $0.active ?? false)
        }
    }
}

// MARK: - the real runner

/// One pipe's bytes, handed between the draining thread and the thread that waits for it. A class
/// with a lock rather than a captured `var`, because the closure crosses a thread boundary.
private final class DrainedPipe: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ value: Data) { lock.withLock { data = value } }
    func get() -> Data { lock.withLock { data } }
}

/// A one-way flag set on the deadline thread and read on the thread that waited for the child.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func raise() { lock.withLock { value = true } }
    var isRaised: Bool { lock.withLock { value } }
}

/// `Process`, with the two failure modes that matter kept apart: a tool that is not installed, and
/// one that ran and disagreed.
public struct ProcessRunner: CommandRunner {
    /// The ceiling on one `agtermctl` invocation, and the reason the daemon cannot be wedged by a
    /// beachballed agterm.
    ///
    /// `agtermctl` has no client-side timeout of its own: pointed at a control socket that accepts
    /// and never answers, it blocks for ever. Every invocation here runs inside `ControlServer`'s
    /// handler lock, which serialises EVERY command -- so one hung `tree --json` on the keypress
    /// path took the whole daemon down with it: later chords blocked on the lock and reported
    /// "dicta did not answer", `status`/`abort`/`last` died too, and `KeepAlive` could not help
    /// because the process was alive. It never recovered without a manual `launchctl kickstart`.
    ///
    /// Five seconds is about 125x the measured cost of the slowest verb (`tree --json`, 38 ms, F4),
    /// so it is a wedge detector rather than a budget anything real has to fit inside.
    public static let defaultDeadline: TimeInterval = 5.0

    /// How many of these calls ONE `stop` can make before the daemon answers, worst case.
    ///
    /// Enumerated rather than estimated, because `daemonCeilingsFitTheClientTimeout` multiplies it
    /// by `defaultDeadline` to assert that the daemon is never willing to spend longer than
    /// `ControlTimeouts.pipelineRead`. It read `3` -- "validate, session type, announce" -- which
    /// left fifteen seconds standing in for what can be sixty, and the assertion passed while the
    /// property it names did not hold. Every notification is TWO calls, not one: `Agterm.notify`
    /// falls back to `osascript` when agtermctl will not answer, which is exactly the case where
    /// both spend their whole deadline.
    ///
    ///  1. `.announce(.working)`
    ///  2. the dictionary's degradation notice, and 3. its `osascript` fallback
    ///  4. the filter's fallback notice, and 5. its `osascript` fallback (step 4's `Filter`; the
    ///     seam is `NoFilter` today, and the budget must already fit when it is not)
    ///  6. `validate` -- `agtermctl tree --json`
    ///  7. `session type`
    ///  8. the terminal `.announce(.done)` or `.announce(.blocked)`
    ///  9. the delivery failure's `.notify`, and 10. its `osascript` fallback
    /// 11. the record's "recovery is unavailable" notice, and 12. its `osascript` fallback
    public static let worstCaseCallsPerStop = 12

    /// How long a child gets to honour SIGTERM before SIGKILL. A child that ignores the polite
    /// signal would otherwise hold this thread's pipes open, and the wedge would simply move here.
    private static let graceAfterTerminate: TimeInterval = 2.0

    private let deadline: TimeInterval

    public init(deadline: TimeInterval = ProcessRunner.defaultDeadline) {
        self.deadline = deadline
    }

    public func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw AgtermError.executableMissing(executable)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw AgtermError.launchFailed(verb: executable, reason: "\(error)")
        }
        // Read before waiting: a pipe that fills while nobody drains it wedges the child, and
        // `tree --json` on a busy machine is comfortably larger than a pipe buffer.
        //
        // BOTH pipes, concurrently, and that is the half that was missing. Draining stdout to EOF
        // and only then reading stderr deadlocks whenever the child fills stderr's buffer before
        // closing stdout: the child blocks writing, this thread blocks reading, and neither
        // `ProcessRunner` nor `Agterm` has a timeout to break it. Since this runs inside the
        // control socket's handler lock, one wedged `agtermctl` would wedge every chord.
        let collected = DrainedPipe()
        let stderrDrained = DispatchSemaphore(value: 0)
        let stderrThread = Thread {
            collected.set(err.fileHandleForReading.readDataToEndOfFile())
            stderrDrained.signal()
        }
        stderrThread.name = "dev.personal.dicta.process.stderr"
        stderrThread.start()

        // The deadline, on a thread of its own because the two reads below are what it exists to
        // unblock. Killing the child closes its ends of both pipes, so `readDataToEndOfFile`
        // returns and this whole call unwinds instead of hanging for ever.
        let finished = DispatchSemaphore(value: 0)
        let expired = Flag()
        let deadline = self.deadline
        let watchdog = Thread {
            guard finished.wait(timeout: .now() + deadline) == .timedOut else { return }
            expired.raise()
            process.terminate()
            guard finished.wait(timeout: .now() + Self.graceAfterTerminate) == .timedOut else {
                return
            }
            // `isRunning` is false only once Foundation has reaped the child, so the pid it hands
            // back here is still this child's and not a recycled one.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        watchdog.name = "dev.personal.dicta.process.deadline"
        watchdog.start()

        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        stderrDrained.wait()
        process.waitUntilExit()
        // One signal releases the watchdog whichever of its two waits it is sitting in.
        finished.signal()
        if expired.isRaised {
            // The verb is filled in by `Agterm.invoke`, which is the only caller that knows it.
            throw AgtermError.timedOut(verb: executable, seconds: deadline)
        }
        return CommandOutput(
            status: process.terminationStatus,
            standardOutput: String(decoding: stdout, as: UTF8.self),
            standardError: String(decoding: collected.get(), as: UTF8.self)
        )
    }
}
