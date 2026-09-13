import AppKit
import DictaCore
import DictaIPC
import DictaMenuKit
import DictaRecord
import Foundation

// The one file that turns `MenuWorld`'s capabilities into the system: the socket, the record, the
// subprocesses, the threads, the clock, the timers and AppKit. Every decision about WHEN these run
// is `StatusViewModel`'s, in `DictaMenuKit`, where the test runner drives it through a fake world;
// what is left here is a call per capability and nothing to decide.

extension MenuWorld {
    /// The world the installed menu runs in.
    static let system = MenuWorld(
        socketExists: { FileManager.default.fileExists(atPath: $0) },
        watch: { path, onEvent in try ControlClient.watch(to: path, onEvent: onEvent) },
        send: { request, path in _ = try ControlClient.send(request, to: path) },
        readRecent: { url, count in try RecordReader.tail(of: url, entries: count).entries },
        locateAgterm: { AgtermTool.locate() },
        sessionNames: { tool in SessionNames.names(inTree: capture(tool, ["tree", "--json"])) },
        offMain: offMain,
        toMain: { work in Task { @MainActor in work() } },
        now: { Date() },
        scheduleTicker: scheduleTicker,
        after: { delay, work in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                work()
            }
        },
        effects: MenuEffects(
            openURL: { NSWorkspace.shared.open($0) },
            revealInFinder: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
            copy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            run: run))

    /// Runs work off the main actor on a real `Thread`.
    ///
    /// Not `DispatchQueue.global()`, and not a queue targeting it: on Darwin, Swift concurrency's
    /// executor shares that non-overcommit pool, and it does not grow when its threads block. A
    /// `stop` parked in there for the length of a dictation is one worker that is not running the
    /// watch stream. The daemon's socket server follows the same rule, for the same measured
    /// reason.
    private static func offMain(_ name: String, _ work: @escaping @Sendable () -> Void) {
        let thread = Thread { work() }
        thread.name = "dev.personal.dicta.menu.\(name)"
        thread.start()
    }

    /// A repeating timer on the main run loop, in `.common` mode so it keeps counting while the
    /// panel is tracking a click. Its block runs on the main thread, which is the main actor.
    @MainActor
    private static func scheduleTicker(_ interval: TimeInterval,
                                       _ tick: @escaping @MainActor () -> Void) -> MenuCancel {
        let box = TickBox(tick)
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { box.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        let handle = TimerBox(timer)
        return MenuCancel { handle.timer.invalidate() }
    }

    /// One subprocess, its stdout as text. Failure is an empty string: everything this runs is a
    /// caption, and a caption that cannot be resolved falls back to the id.
    private static func capture(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Launches an executable and does not wait for it.
    private static func run(_ executable: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try? process.run()
    }
}

/// The ticker's closure, carried into the timer's block. Only ever called on the main thread.
private final class TickBox: @unchecked Sendable {
    let tick: @MainActor () -> Void

    init(_ tick: @escaping @MainActor () -> Void) {
        self.tick = tick
    }
}

/// The timer, carried into the cancel closure. Only ever invalidated on the main actor.
private final class TimerBox: @unchecked Sendable {
    let timer: Timer

    init(_ timer: Timer) {
        self.timer = timer
    }
}
