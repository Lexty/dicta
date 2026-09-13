import AppKit
import CoreGraphics
import DictaCore
import DictaIPC
import Foundation

// Push-to-talk (D5): the half that touches the world.
//
// What it is NOT is as load-bearing as what it is. This is not an event tap and not a keyboard
// monitor: `CGEventSource.flagsState` reports the state of the modifier keys and carries no key
// code and no character, which is why macOS asks for no permission and why dicta cannot observe
// what the user types even in principle (F6, invariant 11). Nothing else in this file may reach for
// an API that would change that -- `Scripts/linkage.sh` checks the built binary for the event-tap
// symbols, because a comment is not a guard.
//
// It reaches the daemon through the daemon's own control socket, exactly as `dictactl` does, rather
// than calling into `Daemon` in-process. That is deliberate. `ControlServer` is where commands are
// serialised, and a second door into the lifecycle that skipped it would be a code path no chord
// has -- so every property already asserted about the socket (D7's atomicity, `abort` overtaking,
// the per-verb read ceilings) covers the held key for free. The cost is one round trip, measured at
// 0-20 ms against F4's 155-252 ms.

/// The state of the modifier keys, as one word of flags.
public protocol ModifierSource: Sendable {
    func flags() -> UInt64
}

/// The real one. `.combinedSessionState` is the hardware state across the login session, which is
/// what makes this work with no window and no keyboard focus (F6).
public struct SystemModifiers: ModifierSource {
    public init() {}

    public func flags() -> UInt64 {
        CGEventSource.flagsState(.combinedSessionState).rawValue
    }
}

/// Which application the user is actually looking at (D22, D31).
///
/// One value per read, never three properties: the bundle identifier, the pid and the name must
/// come from the same activation, or a field target could name VS Code's bundle with Safari's
/// pid. It is also the ONLY frontmost source in the daemon -- the trigger and the focused-field
/// injector share one instance -- because a second, unobserved one would bring back F8a's frozen
/// value.
public protocol FrontmostApplication: Sendable {
    var current: FrontmostFacts? { get }
}

/// The real one, and the observer below is the entire reason it works. DO NOT DELETE IT because it
/// looks unused (F8a).
///
/// `NSWorkspace.shared.frontmostApplication` reads a value this process CACHES. A process that has
/// never registered an observer on the workspace notification centre never subscribes to the window
/// server's activation notifications, so that cache is filled by the first read and then never
/// changes again -- for the life of the process. Measured 2026-08-23 in a process shaped exactly
/// like the daemon, a background thread polling while the main thread runs a CFRunLoop: with no
/// observer it reported the same application for all 17 samples while focus moved through three
/// apps; with this observer registered it tracked every switch. A main-thread run loop is necessary
/// and is NOT sufficient, and reading it once on the main thread first changes nothing.
///
/// That failure has the worst possible shape for D22. It is never nil and never obviously wrong --
/// it is a plausible bundle identifier, frozen at whatever was frontmost when the daemon started.
/// If that happened to be agterm, the hold key arms everywhere, for ever, and dictates into a
/// terminal the user is not looking at.
///
/// The value is therefore kept from the notification stream rather than read back out of the cache:
/// the subscription and the answer are then the same mechanism, and there is nothing that can look
/// like dead code to a future reader. It is seeded once at construction, which is accurate -- a
/// first read always is; it is only the second that lies.
///
/// `CGWindowListCopyWindowInfo` is not the fix. It tracks with no observer, but it answers a
/// different question -- who owns the topmost layer-0 window -- and the same run measured the two
/// disagreeing: while Finder was frontmost with no window open it named another application
/// entirely. D22 must not report an app frontmost that is not.
///
/// Note that AppKit is usable here and was not for `NSEvent.modifierFlags`, which reported nothing
/// at all in a process with no `NSApplication` (F6). The two are not the same kind of API: one
/// reports what the window server tells this process, the other replays an event stream it never
/// receives.
///
/// All three facts are taken from the notification's own `NSRunningApplication`, together, and
/// never by reading `NSWorkspace.shared.frontmostApplication` again -- that read is the cache.
public final class SystemFrontmost: FrontmostApplication, @unchecked Sendable {
    private let lock = NSLock()
    private var facts: FrontmostFacts?
    private var observer: (any NSObjectProtocol)?

    public init() {
        facts = Self.facts(of: NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.set(Self.facts(of: app))
        }
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// The three facts of one running application, read off the one object.
    public static func facts(of app: NSRunningApplication?) -> FrontmostFacts? {
        guard let app else { return nil }
        return FrontmostFacts(bundleID: app.bundleIdentifier, pid: app.processIdentifier,
                              name: app.localizedName)
    }

    private func set(_ facts: FrontmostFacts?) {
        lock.withLock { self.facts = facts }
    }

    public var current: FrontmostFacts? { lock.withLock { facts } }
}

/// The loop that turns a held key into a dictation.
public final class HoldTrigger: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// The keys that arm push-to-talk, in the order a tie between them is broken.
        ///
        /// Right Control is D5's key and stays first: measured distinguishable from left Control,
        /// which is what makes `⌃C` typed with the other hand harmless (F6). Right Command joins it
        /// because **this laptop's built-in keyboard has no right Control key at all** (F6a) -- on
        /// the machine's own keyboard push-to-talk was not degraded but unreachable. Both are the
        /// same gesture and only one can be in flight, which is `HoldWatch`'s whole subject.
        ///
        /// Right Command is not free of collisions and the choice was made with them in view: it is
        /// the modifier of `⌘V`, `⌘K` and `⌘T`, all of which are ordinary presses that D21's floor
        /// discards (126 ms measured on this keyboard, against a 300 ms floor). The one gesture
        /// that does hold it past the floor is `⌘Tab`, and holding it with the RIGHT hand while
        /// agterm is frontmost opens the microphone for the length of the switch. That costs an
        /// attempt with no text in it, never an injection into the wrong place -- D22 read
        /// frontmost at the press, so the target is the pane the user was looking at.
        /// `--hold-key rightOption` is the escape hatch if it turns out to bite in practice: right
        /// Option has no such long-held gesture and was measured on the same keyboard (F6a).
        public var keys: [HoldKey]
        /// D21's floor.
        public var floor: TimeInterval
        /// 16 ms -- 62 samples a second, costing 0.03% of a core (F7).
        ///
        /// It is not free, and an earlier draft of this comment pretended it was by comparing it
        /// against the wrong number: F4's 155-252 ms is the WHOLE keypress path, not the part
        /// `capture.begin` spends inside it, so "invisible beside capture.begin" was a claim F4
        /// never made. What is true is smaller and sufficient. A press lands uniformly inside one
        /// poll period, so this adds 8 ms on average and 16 at worst, to a path that already misses
        /// its own budget. Halving the interval would halve that and double the wakeups; F7
        /// measured both, and 16 ms is the trade taken rather than a free lunch.
        public var pollInterval: TimeInterval
        /// agterm's bundle identifier, matched exactly. A display name would be a looser match for
        /// no gain: this is the one string that identifies the application rather than describing
        /// it.
        public var agtermBundleIdentifier: String
        /// dicta's own control socket -- the same one `dictactl` connects to.
        public var socketPath: String

        public init(keys: [HoldKey] = [.rightControl, .rightCommand],
                    floor: TimeInterval = HoldToTalk.defaultFloor,
                    pollInterval: TimeInterval = 0.016,
                    agtermBundleIdentifier: String = HoldTrigger.agtermBundleIdentifier,
                    socketPath: String = Paths.current.socket.path) {
            self.keys = keys
            self.floor = floor
            self.pollInterval = pollInterval
            self.agtermBundleIdentifier = agtermBundleIdentifier
            self.socketPath = socketPath
        }
    }

    public static let agtermBundleIdentifier = "com.umputun.agterm"

    /// One unit of work for the sender thread: an edge, and what was true of the world at the
    /// instant it happened.
    public struct Pending: Sendable, Equatable {
        public var edge: ModifierWatch.Edge
        /// Which of the armed keys produced it. Nothing downstream branches on this -- the gesture
        /// is the same whichever key carries it -- but a `Pending` that did not name its key would
        /// make "first key wins" a rule assertable only through its consequences.
        public var key: HoldKey
        public var at: Date
        /// Captured in the poll loop rather than read by the sender, so D22 asks "was agterm
        /// frontmost when the key went down" and not "is it frontmost now that we got round to it".
        public var wasFrontmost: Bool
        /// The whole frontmost application at a `down`, from the same single read `wasFrontmost`
        /// was decided on; `nil` on an `up`, and when nothing was frontmost. The focused-field
        /// route (D31) builds its target from it.
        public var frontmost: FrontmostFacts?
    }

    public typealias Sender = @Sendable (Request) throws -> Response

    private let configuration: Configuration
    private let modifiers: any ModifierSource
    private let frontmost: any FrontmostApplication
    private let notifier: any Notifier
    private let clock: any Clock
    private let send: Sender

    private var watch: HoldWatch
    private var gesture: HoldToTalk

    private let lock = NSCondition()
    private var queue: [Pending] = []
    private var running = false
    private var pollThread: Thread?
    private var senderThread: Thread?

    public init(configuration: Configuration = Configuration(),
                modifiers: any ModifierSource = SystemModifiers(),
                frontmost: any FrontmostApplication = SystemFrontmost(),
                notifier: any Notifier,
                clock: any Clock = SystemClock(),
                send: @escaping Sender = { try ControlClient.send($0) }) {
        self.configuration = configuration
        self.modifiers = modifiers
        self.frontmost = frontmost
        self.notifier = notifier
        self.clock = clock
        self.send = send
        self.watch = HoldWatch(keys: configuration.keys)
        self.gesture = HoldToTalk(floor: configuration.floor)
    }

    /// Two real `Thread`s, never `DispatchQueue.global()` and never a `Task`.
    ///
    /// The sender blocks: one `stop` runs the whole tail of an attempt inside the daemon's handler
    /// and can take seconds. On Darwin, Swift concurrency's executor and `DispatchQueue.global()`
    /// share one non-overcommit worker pool that does not grow when its threads block, and this
    /// project has already watched that pool starve the control socket's own front door. The poll
    /// loop is a second real thread for a smaller reason that is just as fatal: 62 wakeups a second
    /// on a shared pool is a poor neighbour.
    public func start() {
        lock.withLock {
            guard !running else { return }
            running = true
        }
        let poll = Thread { [weak self] in self?.pollLoop() }
        poll.name = "dicta.hold.poll"
        // Small, because the loop's whole body is a flags read and a comparison. The default 512 KB
        // is not expensive either; naming the thread is what makes a sample trace readable.
        poll.stackSize = 64 * 1024
        let sender = Thread { [weak self] in self?.senderLoop() }
        sender.name = "dicta.hold.send"
        pollThread = poll
        senderThread = sender
        poll.start()
        sender.start()
    }

    public func stop() {
        lock.withLock {
            running = false
            queue.removeAll()
            lock.broadcast()
        }
    }

    public var isRunning: Bool { lock.withLock { running } }

    // MARK: - the poll loop

    private func pollLoop() {
        while lock.withLock({ running }) {
            if let pending = sample() {
                lock.withLock {
                    queue.append(pending)
                    lock.broadcast()
                }
            }
            Thread.sleep(forTimeInterval: configuration.pollInterval)
        }
    }

    /// One sample, and the work it produced. Separated from the loop and from the queue so that a
    /// test can drive a gesture a step at a time: the alternative is asserting about a keyboard by
    /// waiting in real seconds, which is how a suite becomes flaky and then becomes ignored.
    public func sample() -> Pending? {
        guard let held = watch.sample(modifiers.flags()) else { return nil }
        // Read at the edge and not in the sender: whether agterm was frontmost is a fact about the
        // keypress, and the sender can be several seconds behind it.
        // One read, so the bundle id D22 compares and the pid D31 targets are one activation's.
        let facts = held.edge == .down ? frontmost.current : nil
        let isAgterm = facts?.bundleID == configuration.agtermBundleIdentifier
        return Pending(edge: held.edge, key: held.key, at: clock.now, wasFrontmost: isAgterm,
                       frontmost: facts)
    }

    // MARK: - the sender

    private func senderLoop() {
        while true {
            let next: Pending? = lock.withLock {
                while running, queue.isEmpty { lock.wait() }
                guard running else { return nil }
                return queue.removeFirst()
            }
            guard let next else { return }
            perform(next)
        }
    }

    /// Performs one edge. `internal` rather than private so the suite can drive the whole decision
    /// path without threads: every rule worth asserting is in here and in `HoldToTalk`.
    public func perform(_ pending: Pending) {
        switch pending.edge {
        case .down:
            begin(pending)
        case .up:
            end(pending)
        }
    }

    private func begin(_ pending: Pending) {
        // D22, and silent on purpose: the key means nothing outside agterm, and §6's rule is that a
        // no-op makes no sound. A notification here would fire every time the user pressed a
        // combination with one of the armed keys in their browser -- and with right Command among
        // them (F6a) that is every `⌘V` and every `⌘W` they type all day.
        guard pending.wasFrontmost else { return }
        guard case .start = gesture.down(at: pending.at) else { return }

        do {
            // `focus: true`, and no session: the daemon reads both halves of the target out of ONE
            // `agtermctl tree --json` (§5). Resolving the session here and letting the daemon
            // resolve the pane afterwards would put a second subprocess on the hot path and would
            // build the target out of two different moments.
            let response = try send(Request(cmd: .start, focus: true))
            guard response.kind == .accepted, let attempt = response.attempt else {
                // A refusal is the daemon's to explain -- it already knows whether this was
                // "already recording", a tree that names no active session, or a pane it will not
                // guess at (D6) -- and it has the target to say it against. The key DID mean
                // something here and produced nothing, so unlike D22's silence this is said out
                // loud (§7). What matters locally is that the release must now be silent.
                gesture.abandon()
                if response.kind == .rejected, let message = response.message {
                    notifier.notify(message, for: response.target)
                }
                return
            }
            gesture.started(attempt: attempt)
        } catch {
            gesture.abandon()
            notifier.notify("dicta could not start a dictation: \(error)", for: nil)
        }
    }

    private func end(_ pending: Pending) {
        switch gesture.up(at: pending.at) {
        case let .deliver(attempt):
            // clean, always: the gesture that ends this dictation is letting go of the key that
            // began it, and one key cannot carry two modes (D3). raw stays on its chord.
            dispatch(Request(cmd: .stop, mode: .clean, attempt: attempt))
        case let .discard(attempt):
            // D21. Under the floor this was a combination the user typed with the key -- `⌃C`,
            // `⌘V` -- and not a dictation, so it dies with no text and no sound.
            dispatch(Request(cmd: .abort, attempt: attempt))
        case .start, .ignore:
            // Nothing was ever started under this key: either agterm was not frontmost, or the
            // start was refused, or a chord already ended the attempt and D23's spent id made the
            // release a no-op before it was ever sent.
            return
        }
    }

    private func dispatch(_ request: Request) {
        do {
            let response = try send(request)
            if response.kind == .rejected, let message = response.message {
                notifier.notify(message, for: response.target)
            }
        } catch {
            notifier.notify("dicta could not finish the dictation: \(error)", for: nil)
        }
    }
}
