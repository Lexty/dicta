import DictaCore
import Foundation

/// Every effect the menu's logic has on the world, as capabilities handed in (D19, D27).
///
/// The menu's view model lives in this library rather than in the `DictaMenu` executable because
/// SwiftPM cannot import an executable target, so nothing written there is reachable from the test
/// runner. What makes it testable once it is here is that it touches nothing directly: the socket,
/// the record, the subprocesses, the threads, the clock, the timers and AppKit all arrive through
/// this struct. `DictaMenu` builds the real one; the test runner builds a fake one.
///
/// A struct of closures, not a protocol per seam, and not a facade object: the same idiom as
/// `FocusedFieldWiring.Adapters` and `Daemon.TerminalProvider`. The view model stays real and only
/// the lowest seam is replaced, which is the principle acta's `ControlAPI` follows too.
public struct MenuWorld: Sendable {
    /// Whether a daemon socket exists at the path. An absent socket is "not running", never a
    /// reason to launch anything.
    public var socketExists: @Sendable (String) -> Bool
    /// `ControlClient.watch`: blocks for the life of the stream, calls back per event, returns
    /// normally only on a clean `.end`, and throws for everything else.
    public var watch: @Sendable (String, @escaping @Sendable (WatchEvent) -> Void) throws -> Void
    /// `ControlClient.send`, answer dropped: every consequence arrives on the watch stream.
    public var send: @Sendable (Request, String) throws -> Void
    /// The last `count` entries of the record at the URL, newest last, as `RecordReader.tail`
    /// gives them. Throws when a file that exists cannot be read.
    public var readRecent: @Sendable (URL, Int) throws -> [RecordEntry]
    /// Where `agtermctl` is. `nil` means no lookup is started at all, not even a thread.
    public var locateAgterm: @Sendable () -> String?
    /// Session id to name, from a live tree asked through the tool at the given path.
    public var sessionNames: @Sendable (String) -> [String: String]
    /// Runs blocking work off the main actor, on a worker named by the first argument.
    public var offMain: @Sendable (String, @escaping @Sendable () -> Void) -> Void
    /// Hops back to the main actor. Separate from `offMain` so a test decides completion order.
    public var toMain: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    /// The wall clock.
    public var now: @Sendable () -> Date
    /// Schedules a repeating tick at the interval; the answer stops it.
    public var scheduleTicker: @MainActor (TimeInterval, @escaping @MainActor () -> Void)
        -> MenuCancel
    /// Runs the closure once, on the main actor, after the delay: the reconnect backoff.
    public var after: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
    /// What the panel's buttons reach outside the daemon.
    public var effects: MenuEffects

    public init(
        socketExists: @escaping @Sendable (String) -> Bool,
        watch: @escaping @Sendable (String, @escaping @Sendable (WatchEvent) -> Void) throws
            -> Void,
        send: @escaping @Sendable (Request, String) throws -> Void,
        readRecent: @escaping @Sendable (URL, Int) throws -> [RecordEntry],
        locateAgterm: @escaping @Sendable () -> String?,
        sessionNames: @escaping @Sendable (String) -> [String: String],
        offMain: @escaping @Sendable (String, @escaping @Sendable () -> Void) -> Void,
        toMain: @escaping @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void,
        now: @escaping @Sendable () -> Date,
        scheduleTicker: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void)
            -> MenuCancel,
        after: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void,
        effects: MenuEffects
    ) {
        self.socketExists = socketExists
        self.watch = watch
        self.send = send
        self.readRecent = readRecent
        self.locateAgterm = locateAgterm
        self.sessionNames = sessionNames
        self.offMain = offMain
        self.toMain = toMain
        self.now = now
        self.scheduleTicker = scheduleTicker
        self.after = after
        self.effects = effects
    }
}

/// The effects a click has that are not a request to the daemon: AppKit and subprocesses.
public struct MenuEffects: Sendable {
    /// `NSWorkspace.open`: a System Settings pane.
    public var openURL: @MainActor @Sendable (URL) -> Void
    /// `NSWorkspace.activateFileViewerSelecting`: the record, shown in Finder.
    public var revealInFinder: @MainActor @Sendable (URL) -> Void
    /// The general pasteboard, cleared and set to the string.
    public var copy: @MainActor @Sendable (String) -> Void
    /// Launches an executable with arguments and does not wait: `launchctl`, `--fetch-models`.
    public var run: @Sendable (String, [String]) -> Void

    public init(
        openURL: @escaping @MainActor @Sendable (URL) -> Void,
        revealInFinder: @escaping @MainActor @Sendable (URL) -> Void,
        copy: @escaping @MainActor @Sendable (String) -> Void,
        run: @escaping @Sendable (String, [String]) -> Void
    ) {
        self.openURL = openURL
        self.revealInFinder = revealInFinder
        self.copy = copy
        self.run = run
    }
}

/// Stops something `MenuWorld` started: the ticker's timer, today.
public struct MenuCancel: Sendable {
    private let action: @MainActor @Sendable () -> Void

    public init(_ action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
    }

    @MainActor
    public func cancel() {
        action()
    }
}

/// What shows the setup window, in acta's `ReminderPresenting` shape: the AppKit controller lives
/// in `DictaMenu` and adopts this, and the view model holds it weakly and asks it to `show()`.
///
/// The presenter is attached before the model starts, because the first snapshot of a launch is
/// the one moment the window may open by itself (`FirstSnapshotLatch`) and that moment is consumed
/// whether or not anything is there to show it.
@MainActor
public protocol SetupWindowPresenting: AnyObject {
    /// Opens the window if needed, and brings it forward.
    func show()
}
