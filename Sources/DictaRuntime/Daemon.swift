import DictaCore
import DictaIPC
import Foundation

// The resident daemon: the control socket, the pure state machine, the six seams, and nothing else.
//
// It decides nothing. Every rule of §6 lives in `StateMachine` as a transition, every string that
// reaches a terminal goes through `Sanitizer`, and every effect leaves through a seam. What is left
// here is the part that is genuinely about wiring, and it is worth naming what that means in
// practice, because the two mistakes this file could make are both invisible in a diff:
//
//   • The order in which effects are performed IS the behaviour. `.beginCapture` must be performed
//     without announcing anything (D13, invariant 4), and `.inject` must be performed after the
//     text exists and after the record has it (invariant 10, Task 7).
//   • The state machine must be mutated under one lock and effects performed OUTSIDE it. Effects
//     re-enter -- transcribing produces `.recognised`, which produces `.inject`, which produces
//     `.injectionFinished` -- and a lock held across that would deadlock on the second hop.

/// The half of the agterm adapter the daemon needs before an attempt exists: session id in, target
/// out (§5). A protocol rather than a concrete `Agterm` because D6's fail-closed rules -- no active
/// pane, two candidates, `agtermctl` missing -- have to be producible on demand, and a live
/// terminal cannot produce them.
public protocol TargetResolver: Sendable {
    func resolveTarget(sessionID: String) throws -> Target

    /// Both halves of the target, from live focus and from ONE tree read (§5, D5).
    ///
    /// `allowingPicker` is D24's exception and exists for exactly one caller: a dictation whose
    /// text a script is waiting for (D29) has somewhere to go even when a dialog is in front, so
    /// the refusal that protects the pane behind it does not apply.
    ///
    /// The hold trigger carries no session, so both halves have to be resolved here rather than
    /// one being handed in. Reading them together is not only a subprocess cheaper than asking
    /// twice -- it is the only way the two describe the same instant. Two reads thirty
    /// milliseconds apart can disagree, and a target assembled out of two moments is a target
    /// nobody chose.
    func resolveFocusedTarget(allowingPicker: Bool) throws -> Target
}

extension Agterm: TargetResolver {}

/// One caller waiting for the next dictation's text (D29).
///
/// A semaphore rather than a callback, because the waiting happens on the socket thread serving
/// `dictate` and that thread has nothing else to do — and because a callback would have to be
/// invoked from `deliver`, which runs on whatever thread finished the attempt, with the daemon's
/// locks in unknown states. The text crosses between them as a value and nothing else does.
final class Claim: @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var text: String?

    /// Called from the attempt's own thread.
    func deliver(_ final: String) {
        lock.withLock { if text == nil { text = final } }
        gate.signal()
    }

    /// Called from the socket thread. Returns the text, or `nil` if nobody spoke in time.
    func wait(_ seconds: TimeInterval) -> String? {
        _ = gate.wait(timeout: .now() + seconds)
        return lock.withLock { text }
    }
}

public final class Daemon: @unchecked Sendable {
    /// The three agterm-facing seams, together, because all three address the same agterm instance.
    ///
    /// They travel as one value so that `$AGT_SOCKET` from the keypress can select that instance
    /// (F3, §5): resolving a pane through the default socket and then typing into a different
    /// agterm would be the same class of mistake as D4's substitution.
    public struct Terminal: Sendable {
        public var resolver: any TargetResolver
        public var injector: any Injector
        public var notifier: any Notifier

        public init(resolver: any TargetResolver, injector: any Injector, notifier: any Notifier) {
            self.resolver = resolver
            self.injector = injector
            self.notifier = notifier
        }
    }

    /// Builds the trio for the agterm socket the chord carried; `nil` means agterm's default.
    ///
    /// Answers `nil` when there is no agterm to build it for -- `agtermctl` is not installed, which
    /// `--focused-fields` makes survivable (D31). Every agterm chord is then refused with a reason
    /// naming `agtermctl`, and feedback that belongs to no pane goes through `feedback` instead.
    public typealias TerminalProvider = @Sendable (String?) -> Terminal?

    /// What the focused-field path needs (D31), handed over only when `--focused-fields` is on. A
    /// daemon without it refuses every field start before reaching any accessibility call, which is
    /// how the option off means no permission prompt (D5, invariant 14).
    public struct FocusedFields: Sendable {
        /// The checks before capture: the grant, Secure Input, and the one focused-element read.
        public var access: any FocusedFieldAccess
        /// Delivery into the field, handed the element this attempt captured.
        public var injector: any FieldInjector

        public init(access: any FocusedFieldAccess, injector: any FieldInjector) {
            self.access = access
            self.injector = injector
        }
    }

    /// Which attempt is live and which attempts hold a field handle, read in one acquisition, so a
    /// test can assert that no handle outlives -- or precedes -- its accepted attempt.
    public struct FieldOwnership: Equatable, Sendable {
        public var live: AttemptID?
        public var held: [AttemptID]

        public init(live: AttemptID?, held: [AttemptID]) {
            self.live = live
            self.held = held
        }
    }

    /// The Tier 0 dictionary for the attempt about to be processed (D9a).
    ///
    /// A closure rather than a stored value, because the file is re-read per attempt: the workflow
    /// step 3 is scored on is "edit a rule, dictate once, read the record", and a dictionary the
    /// daemon cached at login would answer with the previous version of the file.
    public typealias DictionaryProvider = @Sendable () -> ReplacementDictionary

    public struct Configuration: Sendable {
        public var socketPath: String
        /// Where the live attempt's target is parked, so that a crash mid-attempt can be cleaned up
        /// after: §7's "daemon crashed leaving a stale indicator" row is only answerable if the
        /// next start knows which pane to put back. Removed as soon as the attempt ends.
        public var activeTargetFile: URL
        /// How long `warming` may last before the attempt is a capture fault. Generous next to the
        /// 150 ms budget (F4): this catches a wedged engine, not a slow one.
        public var warmupTimeout: TimeInterval
        /// How long a drain may take. §7's "daemon wedged during an attempt" row -- without it, a
        /// capture that never hands the audio over holds `recording` forever and every later chord
        /// is refused with "already recording".
        public var drainTimeout: TimeInterval
        /// D15's cap, counted from the moment capture confirms it is running. Ten minutes of
        /// forgotten, unrelated speech landing in an agent's prompt is worse than losing it.
        ///
        /// It lives here rather than inside `AudioCapture` for two reasons. It must outlast the
        /// device: a drain that wedges after nine minutes is still a capped attempt, and a timer
        /// owned by the engine would die with it. And the daemon is what holds the injected `Clock`
        /// (§7's watchdog), so this is the only place where "ten minutes" has a test that does not
        /// take ten minutes.
        public var durationCap: TimeInterval

        /// `activeTargetFile` has no default, for the reason `history` has none: the obvious one --
        /// `Paths.current.support` -- points at the file a LIVE daemon parks its target in, so a
        /// test that forgot the parameter would delete the parked target of a real dictation in
        /// progress and leave §7's stale-indicator row unanswerable, then leave a fabricated target
        /// behind for the next real start to clear through a socket that does not exist.
        public init(
            socketPath: String = Paths.current.socket.path,
            activeTargetFile: URL,
            warmupTimeout: TimeInterval = 5,
            drainTimeout: TimeInterval = 10,
            durationCap: TimeInterval = 600
        ) {
            self.socketPath = socketPath
            self.activeTargetFile = activeTargetFile
            self.warmupTimeout = warmupTimeout
            self.drainTimeout = drainTimeout
            self.durationCap = durationCap
        }
    }

    /// What the watchdog is currently watching. Only the two states in which the daemon is waiting
    /// on the audio hardware have one; `processing` and `injecting` are bounded by their own
    /// synchronous calls, and `recording` is bounded by the duration cap (D15, Task 9).
    private enum Watched: Equatable {
        case nothing
        case warming(AttemptID)
        case draining(AttemptID)
    }

    /// The §9 entry being assembled for the live attempt.
    ///
    /// It exists from `warming`, before there is any text, because §9 records attempts that never
    /// reached recognition too (D17): an outcome and a reason with no text is the honest record
    /// and a gap is not. Every field is filled by the stage that knows it; the entry is written by
    /// whichever stage turns out to be the last one.
    private struct Draft {
        let id: AttemptID
        let target: Target
        /// Chosen by the STOPPING chord (D3), so it is `clean` until one arrives.
        var mode: Mode = .clean
        var recognised = ""
        var final = ""
        var rules = RulesApplied.none
        /// The reasons the user was shown, in order. Joined into §9's `error`: an attempt can have
        /// both a filter fallback and a delivery failure, and dropping one would be a lie.
        var notes: [String] = []
        /// The outcome that supersedes `injected` for an attempt whose text still arrives -- the
        /// filter having fallen back (§7), or the dictionary being degraded (Task 11). Kept as
        /// a value rather than a flag because §9's `outcome` is one field with eleven values.
        var degraded: AttemptOutcome?
        /// §9's speech window (D25). On the DRAFT rather than passed to `append`, because `append`
        /// is the one place a line reaches the record whichever route produced it -- so a
        /// superseding line carries the window for free, and cannot be the one route that drops it.
        var speechStartedAt: Date?
        var speechEndedAt: Date?
        var audioSeconds: Double?
    }

    public let configuration: Configuration
    private let capture: any Capture
    private let transcriber: any Transcriber
    private let filter: any Filter
    private let history: any History
    private let clock: any Clock
    private let provider: TerminalProvider
    /// Where a notification goes when there is no agterm to show it, and everything a focused
    /// field is told, since a field has no indicator (D13, D31).
    private let feedback: any Notifier
    /// `nil` while `--focused-fields` is off.
    private let fields: FocusedFields?
    private let dictionary: DictionaryProvider

    /// Guards the machine and the small amount of per-attempt state that travels with it. Held for
    /// the duration of a `machine.apply` and never across an effect.
    private let stateLock = NSLock()
    /// Orders the side effects of `sync` -- the watchdog, the cap and the parked target -- against
    /// each other. Separate from `stateLock` because those effects acquire `stateLock` themselves
    /// and one of them writes a file; see `sync`.
    private let effectLock = NSLock()
    private var machine = StateMachine()
    /// **Guarded by `stateLock`.** The caller waiting for the next dictation's text (D29). One at
    /// a time: two scripts each expecting "the next thing the user says" cannot both be right, and
    /// the second is refused rather than silently handed somebody else's sentence.
    private var claim: Claim?
    /// **Guarded by `stateLock`.** The focused element each field attempt captured before its
    /// microphone opened, by attempt id and never by "the current one" (D31). Inserted in the SAME
    /// critical section that accepts the start and removed in the same one that ends the attempt,
    /// so no other thread can observe a handle without its accepted attempt -- see `apply`.
    private var fieldHandles: [AttemptID: FieldHandle] = [:]
    /// **Guarded by `stateLock`.** A test's code, run inside the critical section that accepts a
    /// field start. See `duringFieldAcceptance`.
    private var fieldAcceptanceHook: (@Sendable (AttemptID, Bool) -> Void)?
    /// **Guarded by `stateLock`.** Attempts whose audio belongs to the record and to nothing else
    /// (D26), because they were cancelled, capped or faulted after the microphone had opened.
    private var journalling: Set<AttemptID> = []
    /// The audio of the attempt being processed, held in RAM and nowhere else (D14).
    private var drained: (attempt: AttemptID, audio: Audio)?
    /// **final** for the attempt about to be injected -- already replaced, already filtered or
    /// deliberately not, already sanitised (invariant 1).
    private var pendingFinal: (attempt: AttemptID, text: String)?
    /// The last target dicta actually used. Notifications about an attempt that has already ended
    /// need somewhere to land, and this is that somewhere.
    private var rememberedTarget: Target?
    private var parkedAttempt: AttemptID?
    private var draft: Draft?
    /// A record append that failed, waiting to be said out loud. §7 puts the injection first and
    /// the complaint second, so it is parked here rather than notified where it happens.
    private var historyTrouble: String?
    /// Guards `faculties` and `lastPublishedSequence`. A lock of its own, and not `stateLock`,
    /// because publishing must never be able to wait on a transition — the whole promise of D27 is
    /// that the UI cannot slow a dictation down, and sharing the machine's lock would make that a
    /// matter of luck about who takes it first.
    private let readinessLock = NSLock()
    /// **Guarded by `readinessLock`.** What has been established about the daemon's ability to
    /// dictate. Written from outside (`observe`), because each fact is already known by the code
    /// that owns it — the warm-up thread, the microphone callback, the `agtermctl` lookup.
    private var faculties = Faculties()
    /// **Guarded by `readinessLock`.** The newest transition already sent to watchers, so a stale
    /// one that lost a race is dropped rather than rewriting the UI backwards.
    private var lastPublishedSequence: UInt64 = 0
    /// `nil` when the provider found no agterm; see `TerminalProvider`.
    private var terminal: Terminal?
    /// The `$AGT_SOCKET` `terminal` was built from, kept so the parked target can name the agterm
    /// instance the attempt belongs to (§7's stale-indicator row).
    private var adoptedSocket: String?
    /// Monotonic, stamped inside the critical section that produces a transition, so that `sync`
    /// can tell a phase it has already superseded from a new one. See `apply`.
    private var transitionSequence: UInt64 = 0
    private var syncedSequence: UInt64 = 0
    private var watched: Watched = .nothing
    private var watchdog: (any ScheduledWork)?
    /// D15's cap, and the attempt it is counting for. Separate from the watchdog because the two
    /// overlap: a stop chord at 9:58 arms the drain watchdog while the cap is still running.
    private var capped: AttemptID?
    private var capTimer: (any ScheduledWork)?
    /// Which kind of capture fault the live attempt suffered, parked here between capture reporting
    /// it and `recordEnd` choosing §9's outcome. The state machine deliberately does not carry it:
    /// every fault cancels the attempt identically (D16), and only the record and the wording
    /// differ (D15).
    private var faultKind: (attempt: AttemptID, kind: FaultKind)?
    private var server: ControlServer?

    /// Orders the record's two concurrent writers against each other: the thread ending an attempt
    /// and the pipeline thread that is still recognising it. Held across `history.append`, because
    /// what has to be ordered is the bytes on disk and not merely the decision to write them --
    /// §9's superseding line is only a superseding line if it lands second.
    ///
    /// Never taken while `stateLock` is held. `append` takes `stateLock` on failure, so the one
    /// order that exists here is `appendLock` → `stateLock`.
    private let appendLock = NSLock()
    /// **Guarded by `appendLock`.** The ending already written for an attempt that can still be
    /// handed text (see `keepsLateRecognisedText`), kept so that text can supersede it.
    private var supersedable: Ending?
    /// **Guarded by `appendLock`.** Recognised text that arrived before the ending which must carry
    /// it was written, parked for `appendEnding` to fold in. Cleared by every ending, so it can
    /// never reach the attempt after the one that produced it.
    private var lateRecognised: (attempt: AttemptID, text: String)?

    // MARK: - construction

    /// `history` has no default, deliberately. The obvious one -- `FileHistory()` -- points at the
    /// user's real record, and a test that forgot the parameter would append to the file holding
    /// every word they have ever dictated.
    ///
    /// `dictionary` does have one -- an empty dictionary rather than the user's file. The asymmetry
    /// is deliberate: a forgotten `history` would append to the file holding every word they have
    /// dictated, while a forgotten dictionary only means no rule fires, and a default that read the
    /// real file would make every test's output depend on what the user happens to have written in
    /// it. The daemon executable passes `FileDictionary` explicitly.
    ///
    /// `feedback` has no default either, for `history`'s reason in a quieter key: the obvious
    /// one -- `SystemFeedback()` -- plays real sounds and posts real notifications from a test run.
    ///
    /// `fields` does, and the default is the option off: a daemon nobody asked to type into other
    /// applications makes no accessibility call (invariant 14).
    public init(
        configuration: Configuration,
        capture: any Capture,
        transcriber: any Transcriber,
        filter: any Filter = NoFilter(),
        history: any History,
        clock: any Clock = SystemClock(),
        dictionary: @escaping DictionaryProvider = { .none },
        feedback: any Notifier,
        fields: FocusedFields? = nil,
        terminal provider: @escaping TerminalProvider
    ) {
        self.configuration = configuration
        self.capture = capture
        self.transcriber = transcriber
        self.filter = filter
        self.history = history
        self.clock = clock
        self.dictionary = dictionary
        self.provider = provider
        self.feedback = feedback
        self.fields = fields
        // Known at construction, unlike the three faculties: whether a missing `agtermctl` blocks
        // dictation or is only a notice is decided by the option, and the option is this argument.
        faculties = Faculties(focusedFields: fields != nil)
        terminal = provider(nil)
        machine = StateMachine(nextID: Self.firstUnusedID(in: history))
    }

    /// Where this process's attempt ids start, read off the record it is about to append to.
    ///
    /// `StateMachine.nextID` is monotonic within a process and the record outlives the process, so
    /// a daemon that always started at 1 would hand a restarted run the ids the previous one had
    /// already used -- and `install.sh` restarts it on every install. §9's superseding rule keys on
    /// the id alone, so `Record.entries` would then collapse the new attempt #1 onto the old one:
    /// the old entry disappears from the reader, and `dictactl last` -- which is `entries.last`,
    /// ordered by where each id FIRST appears -- hands back whichever attempt the previous run
    /// happened to end on rather than the dictation that has just finished. Invariant 10's recovery
    /// path is exactly that read, so the id has to be unique across the file and not merely across
    /// the process.
    ///
    /// A record that cannot be read leaves it at 1: this runs at construction, the alternative is
    /// refusing to start over a file that a fresh install does not have, and a daemon whose appends
    /// are going to fail has a louder problem than its numbering.
    private static func firstUnusedID(in history: any History) -> AttemptID {
        guard let entries = try? history.entries() else { return 1 }
        return (entries.map(\.id).max() ?? 0) + 1
    }

    /// One fixed agterm, for tests and for any caller that does not care about `$AGT_SOCKET`.
    public convenience init(
        configuration: Configuration,
        capture: any Capture,
        transcriber: any Transcriber,
        filter: any Filter = NoFilter(),
        history: any History,
        clock: any Clock = SystemClock(),
        dictionary: @escaping DictionaryProvider = { .none },
        resolver: any TargetResolver,
        injector: any Injector,
        notifier: any Notifier
    ) {
        let fixed = Terminal(resolver: resolver, injector: injector, notifier: notifier)
        self.init(configuration: configuration, capture: capture, transcriber: transcriber,
                  filter: filter, history: history, clock: clock, dictionary: dictionary,
                  feedback: notifier, terminal: { _ in fixed })
    }

    // MARK: - lifecycle

    /// Binds the control socket and starts serving. Throws `alreadyRunning` when a live daemon
    /// already owns the path (§7): one daemon, one microphone.
    ///
    /// `onFrontDoorLost` is called, on the accept thread, if the accept loop dies of something it
    /// cannot retry. The daemon has no way to serve a chord after that and no way to rebind from
    /// inside itself, so the only honest recovery is for the owner to end the process and let
    /// `KeepAlive` start a fresh one. Defaulted to nothing for the tests, which own the lifetime of
    /// the process they run in.
    public func start(onFrontDoorLost: (@Sendable () -> Void)? = nil) throws {
        let server = ControlServer(path: configuration.socketPath,
                                   onUnexpectedExit: onFrontDoorLost) { [weak self] incoming in
            guard let self else {
                return Response(kind: .rejected, state: .idle, message: "dicta is shutting down")
            }
            return handle(incoming)
        }
        try server.start()
        self.server = server
        // AFTER binding, deliberately. If another daemon owns the socket it is possibly recording
        // right now, and clearing "the known target" would put out a light that is telling the
        // truth. Only the instance that won the socket gets to tidy up after the one that died.
        clearStaleIndicator()
    }

    public func stop() {
        server?.stop()
        server = nil
        setWatchdog(.nothing)
        setCap(nil)
    }

    /// §7's stale-indicator row. The parked file exists only while an attempt is live, so finding
    /// one at startup means the previous daemon died mid-attempt with a light still on.
    private func clearStaleIndicator() {
        guard let data = try? Data(contentsOf: configuration.activeTargetFile) else { return }
        guard let parked = ParkedAttempt.decode(data) else {
            // A file that names no target names no indicator to clear, so keeping it buys nothing
            // -- and leaving it makes it permanent litter that every later start re-reads and
            // re-fails on. The removal used to sit past this guard, so only the decodable ones
            // were ever cleaned up.
            try? FileManager.default.removeItem(at: configuration.activeTargetFile)
            return
        }
        // Through the agterm the dead attempt was addressed at, not through this daemon's current
        // `terminal` -- which at this point in `start()` is still `provider(nil)`, i.e. whichever
        // instance answers the default socket. Clearing there after a crash in a second agterm
        // instance reports success and leaves the red "listening" light burning on a session that
        // is not recording, which is the very row this exists to close.
        // With no agterm there is no light to put out, and nothing to ask. Nor for a focused field,
        // which never had one: it is not handed to agterm, whose own notifier would ignore it, and
        // no agterm is built to ignore it (D31).
        if case .agterm = parked.target {
            provider(parked.agtermSocket)?.notifier.clearIndicator(for: parked.target)
        }
        try? FileManager.default.removeItem(at: configuration.activeTargetFile)
    }

    // MARK: - what a test drives

    public var state: LifecycleState { stateLock.withLock { machine.state } }
    public var currentAttempt: Attempt? { stateLock.withLock { machine.currentAttempt } }
    /// The internal phase, which distinguishes `draining` from `recording` (§8.9).
    public var phase: Phase { stateLock.withLock { machine.phase } }

    /// The field handle attempt `attempt` owns, if it is a live field attempt.
    public func fieldHandle(for attempt: AttemptID) -> FieldHandle? {
        stateLock.withLock { fieldHandles[attempt] }
    }

    /// The live attempt and the attempts holding a field handle, from one acquisition.
    public var fieldHandleAttempts: FieldOwnership {
        stateLock.withLock {
            FieldOwnership(live: machine.currentAttempt?.id, held: fieldHandles.keys.sorted())
        }
    }

    /// Runs `body` inside the critical section that accepts a field start, before the lock is
    /// released -- the one window in which an abort or a fault on another thread could otherwise
    /// end the attempt before its handle was stored -- with whether that attempt's handle is
    /// ALREADY stored at that point.
    ///
    /// `apply` calls it, not the field start's own insert, so it reports the section's state
    /// whatever the insert does: an insert moved to a later acquisition is `false` here on every
    /// run, where a contending abort would catch it only when the scheduler happened to agree.
    /// `body` must not wait for anything that takes the daemon's lock: it is holding it.
    public func duringFieldAcceptance(_ body: (@Sendable (AttemptID, Bool) -> Void)?) {
        stateLock.withLock { fieldAcceptanceHook = body }
    }

    /// The target a notification about the current or most recent attempt belongs to.
    public var knownTarget: Target? {
        stateLock.withLock { machine.currentAttempt?.target ?? rememberedTarget }
    }

    // MARK: - the command path

    public func handle(_ incoming: ControlServer.Incoming) -> Response {
        switch incoming {
        case let .request(request):
            return handle(request)
        case let .undecodable(detail):
            // Loud (§7), and notification-only: a frame the daemon cannot read is not about any
            // attempt, so there is no pane whose indicator would be telling the truth.
            let message = "dicta could not read the command: \(detail)"
            let target = knownTarget
            notifier(for: target).notify(message, for: target)
            return response(.rejected, message: message)
        }
    }

    private func handle(_ request: Request) -> Response {
        switch request.cmd {
        case .status:
            return response(.accepted)
        // The handshake of a `watch` stream, and nothing more (D27). It answers exactly what
        // `status` answers, because that is what it is: the daemon's state right now, which the
        // stream then keeps up to date. Whether there is ROOM for another watcher was settled by
        // `ControlServer` before this ran — a cap on open sockets is a property of the transport,
        // and the daemon has no idea how many are open. Nothing here changes, which is what lets
        // the verb be served concurrently.
        case .watch:
            return response(.accepted)
        case .last:
            return answerLast(verbatim: request.verbatim == true)
        case .stop:
            return respond(to: apply(.stop(mode: request.mode ?? .clean, attempt: request.attempt)))
        case .abort:
            return respond(to: apply(.abort(attempt: request.attempt,
                                            silent: request.silent == true)))
        case .dictate:
            return awaitDictation(request)
        case .start, .toggle:
            return begin(request)
        // On the wire before the daemon can serve them, so the build holds while the store and the
        // switch are wired in. Refused out loud rather than accepted: nothing was saved.
        case .configure, .accessibility:
            return response(.rejected,
                            message: "\(request.cmd.rawValue) is not available in this build")
        }
    }

    /// D29: block until the user dictates, then hand the text back instead of typing it.
    ///
    /// Served concurrently (`Command.isServedConcurrently`), and it must be: this waits for a
    /// person to speak, and the `start` and `stop` that produce what it is waiting for run through
    /// the same handler. Held under that lock it would wait for an event it was itself preventing.
    private func awaitDictation(_ request: Request) -> Response {
        let seconds = request.timeout ?? ControlTimeouts.dictateWait
        let mine = Claim()
        let taken: Bool = stateLock.withLock {
            guard claim == nil else { return false }
            claim = mine
            return true
        }
        guard taken else {
            return reject("another caller is already waiting for the next dictation")
        }
        let final = mine.wait(seconds)
        // Cleared whichever way it ended, and only if it is still OURS: a claim that timed out and
        // was replaced by a later caller's must not be torn down by the loser.
        stateLock.withLock { if claim === mine { claim = nil } }
        guard let final else {
            return response(.noop, message: "nobody dictated anything within \(Int(seconds)) s")
        }
        let state = stateLock.withLock { machine.state }
        return Response(kind: .accepted, state: state, text: final)
    }

    /// Whether a caller is waiting, read where the answer decides what a target is FOR (D29).
    private var hasClaim: Bool { stateLock.withLock { claim != nil } }

    /// The same fact, for a caller outside. Public because a test cannot otherwise know when the
    /// claim has been registered, and starting a dictation before it is registered would be a race
    /// the suite loses at random rather than a rule it asserts.
    public var isAwaitingDictation: Bool { hasClaim }

    /// Takes the claim, if one is outstanding. Exactly once: the attempt that takes it owns it.
    private func takeClaim() -> Claim? {
        stateLock.withLock {
            let held = claim
            claim = nil
            return held
        }
    }

    /// The two verbs that can begin an attempt, and therefore the two that need a target (§5).
    ///
    /// The start-or-stop decision still belongs to the machine (D7): what is decided here is only
    /// whether a pane must be resolved, and that costs an `agtermctl tree --json` -- 38 ms of the
    /// 150 ms budget (F4), which is not worth spending on a chord that turns out to mean "stop".
    private func begin(_ request: Request) -> Response {
        if let conflict = request.conflict {
            // Two places to type, and choosing either is D4's substitution decided by field order.
            return reject(conflict.description)
        }
        if request.cmd == .toggle, currentAttempt != nil {
            // A toggle with an attempt in flight means STOP, and `.stop` says so without carrying a
            // target -- which is the point. `currentAttempt` and `machine.apply` are two separate
            // acquisitions of `stateLock`, and an attempt can end in the window between them
            // without going through the socket at all: the duration cap, the drain watchdog, or a
            // route-change fault on capture's own thread. A `.toggle` landing on the machine it has
            // just found idle takes the START branch and builds the attempt out of the FINISHED
            // one's target -- a pane in another session, never re-resolved and never re-validated.
            // That is exactly the substitution D4 and invariant 3 forbid, arriving through the one
            // door that resolves nothing. `.stop` in idle is a refusal instead, which costs the
            // user one more keypress in a window microseconds wide.
            return respond(to: apply(.stop(mode: request.mode ?? .clean, attempt: request.attempt)))
        }
        if let field = request.field {
            return beginField(request, field)
        }
        // BEFORE the guard, so the refusal below is announced through the agterm the chord fired in
        // rather than through whichever one this daemon last adopted -- or, on a fresh daemon, the
        // default socket. This is §7's "a keymap line that has stopped matching the build" case,
        // found by pressing a chord and seeing nothing happen, so the message reaching the screen
        // the user is looking at is the whole of its value. Safe here for the same reason it was
        // safe below: `adoptTerminal` refuses to rebind while an attempt is live.
        adoptTerminal(agtermSocket: request.agtermSocket)
        guard let terminal = currentTerminal else {
            // Both roads here -- a session chord and the hold key in front of agterm -- need a
            // pane, and without `agtermctl` there is none to resolve (D31). Refused rather than
            // guessed, and through `feedback`, since the agterm that would have shown it is absent.
            return reject("\(request.cmd.rawValue) needs agterm: \(Self.agtermMissing)")
        }
        let target: Target
        do {
            if request.focus == true {
                // The hold trigger (D5). Both halves at once, from one tree read -- and note that
                // this branch is reached only because the caller ASKED for it, never because a
                // session was missing. A start with no session is still a refusal below.
                // `allowingPicker` is D24 answered rather than overridden. That rule refuses
                // because a dictation started in front of a dialog has nowhere to go but the pane
                // behind it. With a caller waiting, it has somewhere: the caller (D29). The target
                // is still resolved, because §6's indicator belongs in the session the user is
                // looking at either way.
                target = try terminal.resolver
                    .resolveFocusedTarget(allowingPicker: hasClaim)
            } else {
                guard let sessionID = request.sessionID, !sessionID.isEmpty else {
                    return reject("\(request.cmd.rawValue) needs the session the chord fired in")
                }
                target = try terminal.resolver.resolveTarget(sessionID: sessionID)
            }
        } catch {
            // Fail closed (D6). A pane this build cannot name exactly is not one it guesses at:
            // the alternative is somebody else's agent receiving the user's prompt.
            return reject(Self.reason(error))
        }
        return respond(to: apply(event(for: request, target: target)))
    }

    /// A start into another application's focused field (D31), refused BEFORE capture unless every
    /// check passes: the option is on, the grant is held, Secure Input is off, and the application
    /// the trigger captured at the press has a focused element that is an eligible text field.
    ///
    /// Every accessibility call is made here, on the socket thread, with no lock held: a hung
    /// application can hold one for the messaging timeout, and `abort` must still be decided at
    /// once. What they produce is a LOCAL handle, stored only by the transition that accepts the
    /// start; a start the machine refuses -- "already recording" -- drops it and touches nothing.
    ///
    /// No agterm is adopted or needed, so a daemon without `agtermctl` still takes this road.
    private func beginField(_ request: Request, _ field: FieldTarget) -> Response {
        let target = Target.focusedField(field)
        guard let fields else {
            return reject("dicta was not started with --focused-fields, so it does not type into "
                          + "\(field.appName)", for: target)
        }
        guard fields.access.isTrusted else {
            return reject("dicta cannot type into \(field.appName) without the Accessibility "
                          + "grant: allow Dicta in System Settings > Privacy & Security > "
                          + "Accessibility", for: target)
        }
        // System-wide, so this names no field: some process has Secure Input on, and keystrokes
        // posted now would be discarded or, worse, be the password being typed.
        guard !fields.access.isSecureInputOn else {
            return reject("dicta will not type into \(field.appName) while Secure Input is on "
                          + "(a password field, or another application holding it)", for: target)
        }
        let element: FocusedElement
        do {
            element = try fields.access.focusedElement(expectedPID: field.pid)
        } catch {
            return reject("dicta cannot type into \(field.appName): \(Self.reason(error))",
                          for: target)
        }
        switch FieldEligibility.classify(element.facts) {
        case .eligible:
            break
        case .ineligible:
            return reject("dicta will not type into \(field.appName): the focused element is not "
                          + "a text field", for: target)
        case .unknown:
            return reject("dicta will not type into \(field.appName): accessibility could not tell "
                          + "whether the focused element is a text field", for: target)
        }
        let handle = element.handle
        return respond(to: apply(event(for: request, target: target)) { attempt in
            self.fieldHandles[attempt] = handle
        })
    }

    private func event(for request: Request, target: Target) -> Event {
        request.cmd == .toggle
            ? .toggle(mode: request.mode ?? .clean, target: target, at: clock.now,
                      attempt: request.attempt)
            : .start(target: target, at: clock.now)
    }

    /// `dictactl last`: the most recent attempt's text, read back out of the record (§9).
    ///
    /// Reading is not injection, so invariant 1 does not apply and nothing here sanitises anything.
    /// `--recognised` hands back the recogniser's output byte for byte, newlines included. That is
    /// the point of storing both fields: a replacement misfire is only diagnosable by comparing
    /// them.
    private func answerLast(verbatim: Bool) -> Response {
        let entries: [RecordEntry]
        do {
            entries = try history.entries()
        } catch {
            // Not notified: `last` is typed at a shell, where the message on stdout and a non-zero
            // exit are already in front of the person who asked. A desktop notification is for the
            // failures nobody is looking at (§7).
            return response(.rejected, message: "dicta could not read the record: "
                + Self.reason(error))
        }
        guard let entry = entries.last else {
            return response(.noop, message: "dicta has no record yet")
        }
        let text = verbatim ? entry.recognised : entry.final
        guard !text.isEmpty else {
            // The honest answer for an attempt that produced no text (D17), rather than an empty
            // line -- which reads as "you have never dictated anything".
            let detail = entry.error.map { " — \($0)" } ?? ""
            return response(.noop, message: "attempt #\(entry.id) produced no "
                + (verbatim ? "recognised" : "final")
                + " text (\(entry.outcome.rawValue))\(detail)")
        }
        let state = stateLock.withLock { machine.state }
        return Response(kind: .accepted, state: state, attempt: entry.id, target: entry.target,
                        text: text)
    }

    /// A refusal the machine never saw, because the command did not survive far enough to become an
    /// event. Notification-only for the same reason as an undecodable frame: no target could be
    /// named, and lighting the previous attempt's pane would be D4's substitution wearing a colour.
    ///
    /// A field start names its target in the request itself, so its refusal goes where a field is
    /// told things -- `feedback` -- rather than to agterm, which has nothing to show it on. There
    /// it is `Basso` as well as the notification, because a Focus mode suppresses the notification
    /// (F11), and it is said here once: the trigger that sent the start says nothing more.
    private func reject(_ message: String, for target: Target? = nil) -> Response {
        let notifier = notifier(for: target)
        if let target, case .focusedField = target { notifier.announce(.blocked, for: target) }
        notifier.notify(message, for: target)
        return response(.rejected, message: message)
    }

    // MARK: - applying an event

    /// `onAcceptedStartLocked` runs with `stateLock` held, in the critical section that accepted a
    /// start, and only if one was accepted. It is how a field handle is stored: inserting after
    /// `apply` returned would let an abort or a fault on another thread end the attempt in between
    /// and run its cleanup first, and the insert would then resurrect the handle of an attempt that
    /// is already over. The same section removes the handle of whichever attempt this event ended,
    /// by that attempt's id alone, so a late teardown of attempt N cannot touch N+1's.
    @discardableResult
    private func apply(_ event: Event,
                       onAcceptedStartLocked: ((AttemptID) -> Void)? = nil) -> Transition {
        // The phase before and after, read under the same lock as the transition: the record needs
        // to know whether this event ENDED an attempt, and asking afterwards would race a chord.
        //
        // The sequence number is stamped in the SAME critical section, and `sync` refuses to apply
        // an older one. `apply` is reached from two threads that share no lock -- the socket
        // handler, and capture's own thread by way of `faulted`, the drain watchdog and D15's cap
        // -- and only the transition itself was serialised. A fault ending attempt N could
        // therefore read its phase, be descheduled, and run `sync(.idle)` AFTER a chord on the
        // socket thread had already run `sync(.warming(N+1))`: the warm-up watchdog it had just
        // armed was disarmed and the target it had just parked was unparked. Attempt N+1 then sat
        // in `warming` for ever if capture never confirmed -- with no watchdog, which is the one
        // case the watchdog exists for -- and refused every later chord as "already recording".
        //
        // The draft the record needs is snapshotted in that SAME critical section, for the same
        // reason and against the same interleaving. Reading it afterwards, as `recordEnd` used to,
        // left the one gap the sequence number does not close: a fault ending attempt N could leave
        // the lock, be descheduled, and find `draft` already replaced by attempt N+1's when it came
        // back -- `record`'s `current.id == id` guard then matched nothing and the line was never
        // written. Attempt N vanished from `record.jsonl` entirely, which is D17 and property 2
        // breaking for precisely the capped and faulted attempts §9 exists to preserve.
        //
        // The TARGET the announcements and notifications are aimed at is snapshotted there too,
        // and for the third time for the same reason. `.announce` and `.notify` carry no target of
        // their own -- unlike `.beginCapture` and `.inject` -- so they used to read `knownTarget`
        // at perform time, i.e. after the lock had been released. A fault or D15's cap ending
        // attempt N on the clock or capture thread could be descheduled between the transition and
        // its effects, and a chord arriving in that window parks attempt N+1's target: N's
        // `blocked` indicator -- which carries no `--auto-reset` -- and N's failure notification
        // then landed on a pane that was at that moment recording somebody else's dictation.
        let (transition, phase, sequence, ending, target) = stateLock.withLock {
            let before = machine.phase
            let transition = machine.apply(event)
            if let ended = before.attempt, machine.phase.attempt?.id != ended.id {
                fieldHandles[ended.id] = nil
            }
            if before.attempt == nil, let started = machine.phase.attempt,
               let onAcceptedStartLocked {
                onAcceptedStartLocked(started.id)
                fieldAcceptanceHook?(started.id, fieldHandles[started.id] != nil)
            }
            transitionSequence += 1
            let ending = endingLocked(event, before: before, after: machine.phase,
                                      transition: transition)
            return (transition, machine.phase, transitionSequence, ending,
                    machine.currentAttempt?.target ?? rememberedTarget)
        }
        // Before `sync`, which drops the draft when the attempt is over, and before the effects, so
        // that the notification the user reads is never ahead of the entry that explains it.
        if let ending { appendEnding(ending) }
        // Before the effects, so that `.beginCapture` and `.drainCapture` are already being watched
        // when they are performed -- a capture that reports synchronously would otherwise leave a
        // watchdog armed on an attempt that has already moved on.
        sync(phase, sequence)
        // BEFORE the effects, and the position is load-bearing in a way that is easy to get exactly
        // backwards.
        //
        // Publishing AFTER the loop looks safer — nothing inserted ahead of the user's own
        // indicator — and is wrong, because the effects RE-ENTER. The real `AudioCapture` hands its
        // audio over from inside `drain`, so `.drainCapture` runs recognition, injection and the
        // terminal announcement before this line would be reached: the inner transitions would
        // publish `idle` first and this one would then publish `processing` on top of it, leaving
        // the menu-bar glyph amber over a dictation that finished seconds ago. The sequence guard
        // would not save it either, since the outer transition's stamp is the older one.
        //
        // It costs nothing measurable in front of the announcement: `publish` takes a lock, copies
        // a snapshot and signals — no syscall, no subprocess. Which is also why the temptation this
        // forecloses must stay foreclosed: the ~35 ms `Scripts/measure.sh` attributes to the
        // indicator is an `agtermctl` subprocess (F4), and moving the indicator behind the UI would
        // buy a better number and not one millisecond of a lit indicator. Publishing may never
        // reorder, delay or replace an announcement.
        publish(sequence: sequence)
        for effect in transition.effects { perform(effect, aimedAt: target) }
        // Last, so §7's order holds: the injection is attempted first and the complaint about the
        // record comes after it.
        reportHistoryTrouble(aimedAt: target)
        return transition
    }

    /// `target` is the one snapshotted with the transition, never the daemon's live one -- see the
    /// third paragraph of `apply`'s note.
    private func perform(_ effect: Effect, aimedAt target: Target?) {
        switch effect {
        case let .beginCapture(id, _):
            // Announces NOTHING (D13, invariant 4). The user is told to speak by `.captureReady`.
            // The target travelled with the phase and is already parked (see `sync`).
            capture.begin(attempt: id) { [weak self] event in self?.receive(event) }
        case let .drainCapture(id):
            capture.drain(attempt: id)
        case let .discardCapture(id):
            capture.discard(attempt: id)
            forget(id)
        case let .retainCapture(id):
            // Marked BEFORE the drain, because the real `AudioCapture` hands the audio over from
            // inside `drain` -- synchronously, re-entering `receive` before this line returns. A
            // mark set afterwards would arrive after the audio it is supposed to route (D26).
            beginJournalling(id)
            capture.drain(attempt: id)
        case let .retainDrainingCapture(id):
            // No `drain` call: one is already in flight and two race for the same buffer. This
            // only says where the audio belongs when it arrives.
            beginJournalling(id)
        case let .transcribe(id, mode):
            recognise(id, mode: mode, aimedAt: target)
        case let .inject(id, injectionTarget):
            deliver(id, to: injectionTarget)
        case let .announce(feedback):
            // An indicator needs a pane. There is one for every announcement the machine emits,
            // because each is about an attempt that reached a state.
            if let target { notifier(for: target).announce(feedback, for: target) }
        case let .notify(message):
            notifier(for: target).notify(message, for: target)
        }
    }

    /// Attempts whose audio, when it arrives, belongs to the record and to nothing else (D26).
    ///
    /// A set rather than a flag: a cancelled attempt's drain can still be in flight while the next
    /// attempt is already recording, and routing the wrong buffer into the journal would attribute
    /// one dictation's words to another's line.
    private func beginJournalling(_ id: AttemptID) {
        stateLock.withLock { _ = journalling.insert(id) }
    }

    private func endJournalling(_ id: AttemptID) {
        stateLock.withLock { journalling.remove(id) }
    }

    private func isJournalling(_ id: AttemptID) -> Bool {
        stateLock.withLock { journalling.contains(id) }
    }

    /// What capture reports, on capture's own thread.
    private func receive(_ event: CaptureEvent) {
        // Before the switch, and it is the whole structural guarantee of D26: audio belonging to a
        // cancelled attempt never reaches `apply` at all, so no transition exists that could carry
        // it to `.inject`. The text cannot be delivered because no state machine event is ever
        // raised for it -- not because a branch declines to.
        if case let .drained(id, audio) = event, isJournalling(id) {
            journalRecognise(id, audio: audio)
            return
        }
        if case let .fault(id, _, _) = event, isJournalling(id) {
            // The attempt is already over and already recorded. A fault on the way out has nothing
            // left to report and no text to offer.
            endJournalling(id)
            return
        }
        switch event {
        case let .ready(id):
            // Before `apply`, which can run the whole tail of the attempt synchronously -- record
            // line included. Capture confirming is the moment speech could first be collected, and
            // it is the same instant D13 gates its announcement on (D25).
            updateDraft(id) { $0.speechStartedAt = self.clock.now }
            apply(.captureReady(id))
        case let .drained(id, audio):
            // Stored before the event, because the `.transcribe` effect the event produces is
            // performed synchronously and needs it. Stored against the id, so a drain belonging to
            // an abandoned attempt cannot become the next attempt's audio.
            stateLock.withLock { drained = (id, audio) }
            // Also before `apply`, and for the same reason. The buffer's own length travels with
            // it: it is the measurement a moved clock cannot corrupt (D25).
            updateDraft(id) {
                $0.speechEndedAt = self.clock.now
                $0.audioSeconds = audio.duration
            }
            apply(.captureDrained(id))
        case let .fault(id, kind, reason):
            // Always discards, never injects (D16, invariant 6), and always worded as a hardware
            // fault rather than as silence (invariant 7) -- the reason travels from capture.
            faulted(id, kind: kind, reason: reason)
        }
    }

    /// Recognition for the record ONLY (D26): an attempt the user cancelled, one the cap ended, or
    /// one a fault killed. The words were spoken into an open microphone and are in whatever else
    /// was listening, so refusing to write them down does not unmake them -- it only makes them
    /// unattributable, which is the harm rather than the protection.
    ///
    /// A real `Thread`, for the reason the whole of this project uses them: `transcribe` blocks on
    /// a semaphore bridging FluidAudio's actor, and blocking a cooperative thread on Darwin's
    /// non-overcommit pool is the deadlock AGENTS.md records about the control socket. It also
    /// keeps `abort` fast, which is the one verb served concurrently precisely so that a cancel is
    /// decided at once (§6).
    ///
    /// Nothing here calls `apply`. That is deliberate and is D26's structural half.
    private func journalRecognise(_ id: AttemptID, audio: Audio) {
        let thread = Thread { [weak self] in
            guard let self else { return }
            defer { self.endJournalling(id) }
            var text = ""
            var note: String?
            do {
                let spoken = try self.transcriber.transcribe(audio)
                // The same judgement the delivery path applies (§7): text too large to travel back
                // through the socket must not be accepted into a record that promises
                // `dictactl last` can read it out again.
                if case let .text(usable) = RecognisedText.validate(spoken) {
                    text = usable
                } else {
                    note = "the words spoken before this attempt ended could not be used"
                }
            } catch {
                note = "the words spoken before this attempt ended could not be recognised: "
                    + Self.reason(error)
            }
            // Written even when there is NO text, which is the part worth being deliberate about.
            // `audioSeconds` is then the evidence that a recogniser looked at this buffer and heard
            // nothing — as opposed to an entry from a build that never looked at all. Those two are
            // different facts and a reader cannot tell them apart from a missing field.
            //
            // The note keeps the third case distinguishable from the second: a recogniser that
            // FAILED did not establish silence, and an entry with a measured buffer and no text
            // would otherwise claim it did.
            self.recordLateRecognised(id, text, audioSeconds: audio.duration, note: note)
        }
        thread.name = "dicta.journal"
        thread.start()
    }

    /// Every capture fault goes through here, whatever raised it: the device, the watchdog, or
    /// D15's cap. The kind is parked before the event so that `recordEnd`, which runs inside
    /// `apply`, can tell `capped` from `capture-fault` (§9).
    private func faulted(_ id: AttemptID, kind: FaultKind, reason: String) {
        stateLock.withLock { faultKind = (id, kind) }
        apply(.fault(id, reason: reason))
    }

    // MARK: - the text pipeline (§2)

    /// `target` is the attempt's own, snapshotted with the transition that started this stage --
    /// §7's config notifications are about THIS dictation, so they go where it was aimed rather
    /// than at whatever the daemon is doing by the time the recogniser answers.
    private func recognise(_ id: AttemptID, mode: Mode, aimedAt target: Target?) {
        guard let audio = takeAudio(id) else {
            apply(.recognised(id, .failed(reason: "the audio was lost before it could be read")))
            return
        }
        let spoken: String
        do {
            spoken = try transcriber.transcribe(audio)
        } catch {
            // §7: no injection, notify, and the attempt is recorded with its error and no text --
            // `recordEnd` writes that row from the transition this produces.
            apply(.recognised(id, .failed(reason: "the recogniser failed: \(Self.reason(error))")))
            return
        }
        // §7's third recogniser row: output that is not valid UTF-8, or longer than the frame
        // limit, is a processing failure carrying the BYTE LENGTH rather than the text. Judged
        // before the draft is touched, deliberately -- an entry whose `recognised` held 200 KB
        // nobody can read back through the socket would be a record that lies about being
        // recoverable.
        let recognised: String
        switch RecognisedText.validate(spoken) {
        case let .text(text):
            recognised = text
        case let unusable:
            let reason = unusable.failureReason ?? "the recogniser returned unusable text"
            apply(.recognised(id, .failed(reason: reason)))
            return
        }
        // §9's `recognised`, verbatim: no cleaning, no trimming, and stored BEFORE any later stage
        // can touch the text. An entry whose `recognised` had already been through the dictionary
        // would make a misfire invisible, which is the one thing the field exists to prevent.
        //
        // Not `updateDraft`: recognition is the one stage long enough for the attempt to end
        // underneath it -- D15's cap fires from the clock's thread, and a sleep or a route change
        // from capture's -- and a draft that is dropped a moment later takes the text with it. The
        // store therefore answers whether the attempt is still live, and text that missed goes to
        // the record by the one route left (invariant 10, §7's cap row).
        if !storeRecognised(id, recognised) { recordLateRecognised(id, recognised) }

        // **replaced** (§2, D9a): the Tier 0 dictionary, applied in BOTH modes. raw skips the
        // filter and nothing else (D3), so this stage is above the mode check rather than inside
        // it. Read per attempt, so a rule edited a moment ago is the rule that fires.
        let book = dictionary()
        let replacement = Replacements.apply(book, to: recognised)
        let replaced = replacement.text
        // §9's `rules`, stored whether or not anything fired: comparing `recognised` with `final`
        // is only a diagnosis when the list of rules that ran is beside them.
        updateDraft(id) { $0.rules = replacement.applied }
        if let degraded = book.degradedReason {
            // §7: skip only the offending rules, apply the rest, never block a dictation over a
            // config file. The text still arrives, so this is a superseding outcome and not a
            // failure -- the same shape as the filter's fallback below.
            updateDraft(id) {
                $0.notes.append(degraded)
                $0.degraded = .dictionaryDegraded
            }
        }

        var text = replaced
        var filterFailure: String?
        if mode == .clean {
            // raw skips exactly this stage and nothing else (§2, D3).
            do {
                let filtered = try filter.filter(replaced)
                if Sanitizer.sanitize(filtered) == .empty, Sanitizer.sanitize(replaced) != .empty {
                    // §7's row is "fails, times out **or returns empty**", and all three fall back
                    // to **replaced**. Written the other way round, a filter that answered with
                    // nothing ended the attempt as an empty dictation and the user was told their
                    // microphone heard silence -- the one reading §7 forbids. Guarded on `replaced`
                    // having had something in it, so a genuinely empty dictation is still empty and
                    // is not reported as a filter that misbehaved.
                    text = replaced
                    filterFailure = "the filter did not run: it returned nothing"
                } else {
                    text = filtered
                }
            } catch {
                // §7: a failing filter must never cost the user their words, so it falls back to
                // **replaced** rather than ending the attempt.
                text = replaced
                filterFailure = "the filter did not run: \(Self.reason(error))"
            }
        }
        if let filterFailure {
            // The text still arrives, so the entry is not a failure -- but `filter-fell-back` is
            // the fact worth keeping about it, and it supersedes `injected` (§7, §9). It also
            // supersedes a dictionary degradation, because §9's `outcome` is one field and a whole
            // stage not running is the larger fact; both reasons survive in `notes` either way.
            updateDraft(id) {
                $0.notes.append(filterFailure)
                $0.degraded = .filterFellBack
            }
        }

        // Last, always (invariant 1): both stages above can introduce a newline, and
        // `agtermctl session type` turns a newline into a Return that SUBMITS the input line (D8).
        // §7's filter and dictionary rows: once each per attempt, whatever the number of broken
        // rules, and never instead of the attempt's own report. Told AFTER the outcome has been
        // applied, so the entry that explains the notification is already on disk.
        func reportConfigTrouble() {
            if let degraded = book.degradedReason {
                notifier(for: target).notify(degraded, for: target)
            }
            if let filterFailure { notifier(for: target).notify(filterFailure, for: target) }
        }

        switch Sanitizer.sanitize(text) {
        case .empty:
            // An empty insertion is worse than none (§7) -- but never a silent one. A dictation the
            // recogniser HEARD and the dictionary then deleted is reported as exactly that, so the
            // user looks at the rule they wrote rather than at their microphone.
            apply(.recognised(id, .empty(reason: Self.emptiedBy(recognised: recognised,
                                                                replaced: replaced,
                                                                rules: replacement.applied))))
            // A broken dictionary is reported on this branch too. It used to be told only when text
            // survived, so a user who had just broken `replacements.conf` and then dictated into
            // silence was told nothing about the file -- the moment the sentence is most useful.
            reportConfigTrouble()
        case let .line(final):
            updateDraft(id) { $0.final = final }
            stateLock.withLock { pendingFinal = (id, final) }
            let transition = apply(.recognised(id, .text))
            guard transition.effects.contains(where: \.isInjection) else {
                // The attempt was abandoned while the recogniser was running -- an abort arriving
                // mid-inference is exactly the case §6 calls a cancel. Nothing is injected, and the
                // text does not sit around waiting for a later path to find it.
                forget(id)
                return
            }
            // Told after the delivery has been arranged rather than before: an attempt the user has
            // already cancelled does not need a report about its config files.
            reportConfigTrouble()
        }
    }

    private func deliver(_ id: AttemptID, to target: Target) {
        guard let final = takeFinal(id) else {
            let reason = "the text was lost before it was typed"
            record(id, outcome: .injectionFailed, error: reason)
            apply(.injectionFinished(id, .failed(reason: reason)))
            return
        }
        guard Sanitizer.isInjectable(final) else {
            // Unreachable through `Sanitizer.sanitize`, and asserted anyway: if it ever failed
            // here, injecting would submit a half-written prompt, and refusing is better (§8.2).
            let reason = "the text is not a single line"
            record(id, outcome: .injectionFailed, error: reason)
            apply(.injectionFinished(id, .failed(reason: reason)))
            return
        }
        // D29, and this is the only place text leaves the daemon, which is what makes the claim
        // safe to express here rather than as a branch in five places. Nothing is typed: no
        // `injector` call is made, no target is touched, and the outcome says `returned` rather
        // than `injected` because a record claiming a keystroke that never happened would be lying
        // about the one thing this file exists to be trusted on.
        if let claimed = takeClaim() {
            record(id, outcome: stateLock.withLock { draft?.id == id ? draft?.degraded : nil }
                ?? .returned)
            claimed.deliver(final)
            apply(.injectionFinished(id, .delivered))
            return
        }
        // Invariant 10, and the reason this line sits above the injection rather than below it:
        // once the entry is on disk, no delivery failure can cost the user their words. A failed
        // append does NOT stop the delivery (§7) -- it parks a loud complaint for afterwards.
        // Guarded on the id like every other draft read in this file: the `degraded` outcome is
        // what a human reads out of §9 to decide what went wrong, and stamping another attempt's
        // `filter-fell-back` onto this entry would make it say so about the wrong dictation.
        record(id, outcome: stateLock.withLock { draft?.id == id ? draft?.degraded : nil }
            ?? .injected)
        do {
            // Each injector re-validates its own target (D4, §8.3) and never retries (§7).
            switch target {
            case .agterm:
                guard let injector = currentTerminal?.injector else {
                    // Unreachable while an attempt holds its agterm (`adoptTerminal` refuses to
                    // rebind one), and classified honestly anyway: nothing was typed.
                    throw DeliveryFailure.notStarted(target, reason: Self.agtermMissing)
                }
                try injector.inject(final, into: target)
            case let .focusedField(field):
                // The handle THIS attempt captured, by its id. Unreachable without one -- a field
                // start is accepted only together with its handle -- and nothing was typed.
                guard let fields, let handle = fieldHandle(for: id) else {
                    throw DeliveryFailure.notStarted(
                        target, reason: "the focused field was not captured for this attempt")
                }
                try fields.injector.inject(final, into: field, handle: handle)
            }
            apply(.injectionFinished(id, .delivered))
        } catch let failure as DeliveryFailure {
            // The file is append-only, so the line above cannot be corrected in place: this writes
            // a superseding line for the same attempt, and the reader takes the last one (§9).
            record(id, outcome: failure.recordOutcome, error: failure.description)
            apply(.injectionFinished(id, failure.injectionResult))
        } catch {
            let reason = Self.reason(error)
            record(id, outcome: .injectionFailed, error: reason)
            apply(.injectionFinished(id, .failed(reason: reason)))
        }
    }

    // MARK: - the record (§9)

    /// What the record needs about an attempt that has just ended, taken whole so that appending
    /// the line needs nothing from the daemon's state afterwards.
    private struct Ending {
        var draft: Draft
        let outcome: AttemptOutcome
    }

    /// Decides §9's outcome for an attempt that has ended, and snapshots the draft it will be
    /// written from. **Called with `stateLock` held**, inside the same critical section as the
    /// transition -- see `apply`. The delivery outcomes are absent on purpose: `deliver` owns
    /// those, because the entry has to exist BEFORE the keystrokes it describes (invariant 10).
    private func endingLocked(_ event: Event, before: Phase, after: Phase,
                              transition: Transition) -> Ending? {
        guard let attempt = before.attempt, after.attempt == nil,
              // A rejected or ignored command ended nothing, so it is not an attempt of its own.
              transition.outcome == .accepted,
              var snapshot = draft, snapshot.id == attempt.id
        else { return nil }
        let outcome: AttemptOutcome
        switch event {
        case .injectionFinished:
            return nil
        case .fault:
            // Never `empty`, whatever stage it arrived in (invariant 7). D15's cap is the one fault
            // with its own outcome, and the entry still carries whatever text was produced -- which
            // is the whole of "record whatever text was produced" in §7's cap row: the draft is
            // written as it stands, recognised text included.
            //
            // The kind is consumed here rather than through a second lock acquisition, so that a
            // fault on the NEXT attempt landing in between cannot make this one read as a plain
            // capture fault when it was D15's cap.
            var kind: FaultKind?
            if let held = faultKind, held.attempt == attempt.id {
                kind = held.kind
                faultKind = nil
            }
            outcome = kind == .durationCap ? .capped : .captureFault
        case let .recognised(_, result):
            switch result {
            case .text: return nil // moves to `injecting`; the attempt has not ended
            case .empty: outcome = .empty
            case .failed: outcome = .recognitionFailed
            }
        case .start, .captureReady, .captureDrained:
            return nil // none of these can end an attempt
        case .stop, .abort, .toggle:
            // Including a stop while `warming`, which §6 calls a cancel: no audio existed, so there
            // is nothing to report but the reason.
            outcome = .aborted
        }
        // The note goes onto the SNAPSHOT and is not written back: the attempt is over, so `sync`
        // is about to drop the draft anyway, and a write-back would be a second chance to touch a
        // draft that may by then belong to the attempt after this one.
        if let message = transition.message { snapshot.notes.append(message) }
        return Ending(draft: snapshot, outcome: outcome)
    }

    /// Appends one line for `id`, built from its draft. Called at most twice per attempt, and only
    /// ever a second time to supersede the pre-injection line with the delivery's verdict.
    ///
    /// This is `deliver`'s route, and it reads the live draft because the attempt is still in
    /// flight. An attempt that has ENDED goes through `endingLocked` instead.
    private func record(_ id: AttemptID, outcome: AttemptOutcome, error: String? = nil) {
        let snapshot = stateLock.withLock { () -> Draft? in
            guard var current = draft, current.id == id else { return nil }
            if let error { current.notes.append(error) }
            draft = current
            return current
        }
        guard let snapshot else { return }
        appendLock.withLock {
            // Every write to the record goes through this lock, so that "which line landed last"
            // is a fact rather than a race. Nothing can be waiting to supersede here -- an attempt
            // that reached delivery stored its text on the live draft -- so the two slots are
            // dropped rather than consulted, which is also what keeps a faulted attempt's draft
            // from being held past the dictation that follows it.
            supersedable = nil
            lateRecognised = nil
            append(snapshot, outcome: outcome)
        }
    }

    /// Whether an outcome may still be handed text produced after it was decided.
    ///
    /// The two capture faults may: §7's cap row and D15 both promise that whatever text the attempt
    /// produced still reaches the record, and a fault that lands while the recogniser is running
    /// leaves that text with nowhere else to go -- the audio is discarded and nothing is injected,
    /// so the record is the only copy (invariant 10).
    ///
    /// `aborted` deliberately may not. An abort is the user asking for the dictation to be dropped,
    /// and text arriving a moment later is text they have already said they do not want; keeping it
    /// would put a cancelled utterance into the file `dictactl last` reads back.
    private static func keepsLateRecognisedText(_ outcome: AttemptOutcome) -> Bool {
        // `aborted` joined this list under D26, and it is the reversal that decision exists to
        // record: it used to refuse the text on the grounds that the user had asked for the
        // dictation to be dropped. What they cancelled is the DELIVERY. The speaking already
        // happened, into a microphone that was open, and anything else recording the room has it.
        outcome == .capped || outcome == .captureFault || outcome == .aborted
    }

    /// Writes the line for an attempt that has ended, folding in text that arrived while it was
    /// being written. One of the two orders this function exists for; see `recordLateRecognised`
    /// for the other.
    private func appendEnding(_ ending: Ending) {
        appendLock.withLock {
            var draft = ending.draft
            let keepsText = Self.keepsLateRecognisedText(ending.outcome)
            if keepsText, draft.recognised.isEmpty,
               let late = lateRecognised, late.attempt == draft.id {
                draft.recognised = late.text
            }
            // Unconditionally, including for an ending that refuses the text: it belongs to this
            // attempt, and this attempt is over.
            lateRecognised = nil
            // `append` resolves D25's open-ended window, and the resolved draft is what becomes
            // supersedable -- otherwise a superseding line would recompute the end from a later
            // clock and the two lines for one attempt would disagree about when the speaking
            // stopped.
            let resolved = append(draft, outcome: ending.outcome)
            supersedable = keepsText ? Ending(draft: resolved, outcome: ending.outcome) : nil
        }
    }

    /// Where recognised text goes when the attempt it belongs to has already ended.
    ///
    /// Two orders are possible and both are handled under `appendLock`, which is the whole point of
    /// that lock: either the ending has already been written -- in which case this appends a
    /// **superseding** line with the same id, which §9 defines as the last line winning -- or it
    /// has not, in which case the text is parked and `appendEnding` folds it into the one line that
    /// is still to come. Without the lock the two could write in either order and the text-less
    /// line could land second, which is the loss this is here to prevent.
    private func recordLateRecognised(_ id: AttemptID, _ text: String,
                                      audioSeconds: Double? = nil,
                                      note: String? = nil) {
        appendLock.withLock {
            guard var written = supersedable, written.draft.id == id else {
                // Only text can be parked; a duration with nothing to supersede has no line to
                // ride on, and inventing one would add an entry rather than correct one.
                if !text.isEmpty { lateRecognised = (id, text) }
                return
            }
            guard written.draft.recognised.isEmpty else { return }
            written.draft.recognised = text
            if let note { written.draft.notes.append(note) }
            // The buffer survived to be measured, which it does not on the path that discards it
            // (D25, D26). Only ever filled in, never overwritten: a drained attempt already has it.
            if let audioSeconds, written.draft.audioSeconds == nil {
                written.draft.audioSeconds = audioSeconds
            }
            supersedable = nil
            append(written.draft, outcome: written.outcome)
        }
    }

    /// The one place a line reaches the record, whichever route produced the draft. Returns the
    /// draft as written, which is not always the draft handed in: see D25's end time below.
    @discardableResult
    private func append(_ draft: Draft, outcome: AttemptOutcome) -> Draft {
        var draft = draft
        let at = clock.now
        // An attempt that ended while the microphone was still collecting -- an abort, a fault,
        // D15's cap -- has a start and no end: capture is told to discard AFTER this line is
        // written, so nothing later can fill it in. These are exactly the outcomes that carry no
        // text, where the window is the only evidence the attempt leaves (D25). `at` is the same
        // instant and is already being read, which matters: an extra `clock.now` here would consume
        // the one-shot a test uses to land a chord in the middle of this write.
        if draft.speechStartedAt != nil, draft.speechEndedAt == nil {
            draft.speechEndedAt = at
        }
        let entry = RecordEntry(
            id: draft.id,
            at: at,
            outcome: outcome,
            mode: draft.mode,
            recognised: draft.recognised,
            final: draft.final,
            rules: draft.rules,
            target: draft.target,
            error: draft.notes.isEmpty ? nil : draft.notes.joined(separator: "; "),
            speechStartedAt: draft.speechStartedAt,
            speechEndedAt: draft.speechEndedAt,
            audioSeconds: draft.audioSeconds
        )
        do {
            try history.append(entry)
        } catch {
            // §7's "history append fails" row. Property 2 -- nothing disappears quietly -- is
            // exactly what just broke, so this is loud, and it never blocks a delivery.
            stateLock.withLock {
                historyTrouble = "dicta could not save this dictation: \(Self.reason(error))"
                    + " -- recovery from the record is unavailable"
            }
        }
        return draft
    }

    private func reportHistoryTrouble(aimedAt target: Target?) {
        let message = stateLock.withLock { () -> String? in
            defer { historyTrouble = nil }
            return historyTrouble
        }
        guard let message else { return }
        notifier(for: target).notify(message, for: target)
    }

    /// Stores §9's `recognised` on the live draft, answering whether the attempt is still live.
    ///
    /// The MACHINE is the authority on that, not the draft: the draft outlives the transition that
    /// ended it by one `sync`, so a draft whose id still matches can already be doomed, and writing
    /// text into it would be writing text into something about to be dropped. Both this and
    /// `endingLocked` run under `stateLock`, which is what makes the two answers exhaustive -- an
    /// ending that has not happened yet is guaranteed to snapshot the text stored here, and one
    /// that has already happened is guaranteed to be visible as `false`.
    private func storeRecognised(_ id: AttemptID, _ text: String) -> Bool {
        stateLock.withLock {
            guard machine.currentAttempt?.id == id else { return false }
            if var current = draft, current.id == id {
                current.recognised = text
                draft = current
            }
            return true
        }
    }

    private func updateDraft(_ id: AttemptID, _ body: (inout Draft) -> Void) {
        stateLock.withLock {
            guard var current = draft, current.id == id else { return }
            body(&current)
            draft = current
        }
    }

    // MARK: - per-attempt bookkeeping

    private func takeAudio(_ id: AttemptID) -> Audio? {
        stateLock.withLock {
            guard let held = drained, held.attempt == id else { return nil }
            drained = nil
            return held.audio
        }
    }

    private func takeFinal(_ id: AttemptID) -> String? {
        stateLock.withLock {
            guard let held = pendingFinal, held.attempt == id else { return nil }
            pendingFinal = nil
            return held.text
        }
    }

    /// Drops an abandoned attempt's audio and text. Nothing recognisable survives a discard: the
    /// audio's integrity is what is in doubt, and keeping either invites a later path to use it.
    private func forget(_ id: AttemptID) {
        stateLock.withLock {
            if drained?.attempt == id { drained = nil }
            if pendingFinal?.attempt == id { pendingFinal = nil }
        }
    }

    /// Where anything about `target` is said: `feedback` for a focused field, which has no
    /// indicator, and otherwise the agterm the daemon is addressed at, or `feedback` when there is
    /// no agterm (D13, D31). agterm's notifier is silent for a field, so routing one there would
    /// lose the attempt's every sound.
    private func notifier(for target: Target?) -> any Notifier {
        if case .focusedField = target { return feedback }
        return stateLock.withLock { terminal?.notifier ?? feedback }
    }

    /// The reason every agterm chord is refused with when the provider found no agterm.
    static let agtermMissing = "agtermctl is not installed, so dicta cannot reach agterm"

    /// The whole three-existential struct, read under the lock that writes it.
    ///
    /// Reading `terminal` unlocked was a torn multi-word read, not a benign stale value: `begin`
    /// runs on the socket thread while `deliver` can be on capture's, since recognition and
    /// injection re-enter through `drainCapture`. Every use goes through here or `notifier(for:)`.
    private var currentTerminal: Terminal? { stateLock.withLock { terminal } }

    private func adoptTerminal(agtermSocket: String?) {
        stateLock.withLock {
            // A command that cannot begin an attempt must not rebind the agterm the live one is
            // addressed at. `start` while recording IS rejected -- but by the machine, further
            // down `begin`, and by then the in-flight attempt's remaining announcements and its
            // injection would already be travelling to whichever agterm the rejected chord named.
            // That is D4's substitution arriving through the one door that resolves nothing, the
            // same door `begin` already closes for `toggle`.
            guard machine.currentAttempt == nil else { return }
            terminal = provider(agtermSocket)
            adoptedSocket = agtermSocket
        }
    }

    // MARK: - the watchdog, and the parked target

    /// Everything that must follow the phase rather than an individual event: which state is being
    /// watched, and whether a target is parked on disk for the next daemon to tidy up.
    ///
    /// `sequence` is the stamp `apply` took under the lock that produced this phase. An application
    /// older than one already made is dropped whole -- draft included, since a stale `.idle` would
    /// otherwise throw away the draft of the attempt that has just begun. Dropping is correct
    /// rather than merely safe: whatever the newest sequence saw IS the machine's state, so the
    /// older phase describes a moment that has already been overwritten.
    private func sync(_ phase: Phase, _ sequence: UInt64) {
        // The mode is the stopping chord's (D3), so the draft learns it the moment a phase carries
        // one -- which is before any stage that could write the entry runs.
        let superseded = stateLock.withLock { () -> Bool in
            guard sequence > syncedSequence else { return true }
            syncedSequence = sequence
            switch phase {
            case .idle:
                draft = nil
            case let .warming(attempt):
                if draft?.id != attempt.id {
                    draft = Draft(id: attempt.id, target: attempt.target)
                }
            case .recording:
                break
            case let .draining(_, mode), let .processing(_, mode), let .injecting(_, mode):
                draft?.mode = mode
            }
            return false
        }
        guard !superseded else { return }
        // The effects are serialised on a lock of their own, and the sequence is re-checked inside
        // it. Claiming the sequence and performing the effects were two separate acquisitions, and
        // the window between them is reachable: `sync` runs on the socket thread and on capture's
        // own fault thread. A stale `.idle` that claimed its sequence and was then preempted would
        // resume AFTER the next attempt had parked its target and armed its warm-up watchdog, and
        // run `setWatchdog(.nothing)` + `unpark()` against it -- leaving the new attempt in
        // `warming` with nothing watching it, refusing every later chord as "already recording".
        // Whichever caller reaches the lock second sees the newer `syncedSequence` and drops its
        // whole application, which is the same rule the claim above applies, applied where the
        // effects actually happen. Taken after `stateLock` is released and never the other way
        // round: `setCap` and `setWatchdog` acquire `stateLock` from inside here.
        effectLock.lock()
        defer { effectLock.unlock() }
        guard stateLock.withLock({ sequence == syncedSequence }) else { return }
        switch phase {
        case .idle:
            setWatchdog(.nothing)
            setCap(nil)
            unpark()
            // The audio of an attempt whose drain event was ignored -- an abort landing between the
            // drain and its event, which `abort` alone is unserialised enough to do -- is otherwise
            // held until some later attempt drains over it. Minutes of PCM, on the one path where
            // nothing else is going to read it (D14: audio lives in RAM and nowhere else).
            stateLock.withLock { drained = nil }
        case let .warming(attempt):
            park(attempt)
            setWatchdog(.warming(attempt.id))
        case let .recording(attempt):
            setWatchdog(.nothing)
            // Armed here rather than at the keypress: the cap bounds how long the user has been
            // *speaking*, and `warming` is bounded by its own watchdog. It is deliberately NOT
            // disarmed by the stop chord -- an attempt that stops at 9:59 and then wedges in its
            // drain is still ten minutes of audio nobody is waiting for.
            setCap(attempt.id)
        case let .draining(attempt, _):
            setWatchdog(.draining(attempt.id))
        case .processing, .injecting:
            setWatchdog(.nothing)
        }
    }

    /// Arms or disarms D15's cap. Idempotent per attempt: re-arming on every event would push the
    /// deadline away, and ten minutes of speech punctuated by chords would never reach it.
    /// Arming happens INSIDE the critical section that records what is armed, and the reason is a
    /// race rather than tidiness. `sync` is reached from two threads -- the socket handler and the
    /// capture-fault thread -- so a version that cancelled under one acquisition and stored under a
    /// second could interleave: the disarming call cancels a `nil` timer and returns, then the
    /// arming call stores its own work afterwards. The result is a timer running against state that
    /// says nothing is watched, which fires `faulted` at an attempt that has already moved on and
    /// discards a live recording mid-sentence.
    private func setCap(_ attempt: AttemptID?) {
        stateLock.withLock {
            guard capped != attempt else { return }
            capped = attempt
            capTimer?.cancel()
            capTimer = nil
            guard let attempt else { return }
            capTimer = clock.schedule(after: configuration.durationCap) { [weak self] in
                // A capture fault like any other -- discard, no injection (D16, invariant 6) --
                // with its own §9 outcome and its own words, because "ten minutes elapsed" is the
                // one fault the user caused and can avoid.
                self?.faulted(attempt, kind: .durationCap, reason: FaultReason.durationCap)
            }
        }
    }

    /// One critical section, for the reason spelled out on `setCap`.
    private func setWatchdog(_ next: Watched) {
        stateLock.withLock {
            // Re-arming on every event would keep pushing the deadline away, so a wedged attempt
            // that is being poked by repeated chords would never time out.
            guard watched != next else { return }
            watched = next
            watchdog?.cancel()
            watchdog = nil

            let (id, seconds, reason): (AttemptID, TimeInterval, String)
            switch next {
            case .nothing:
                return
            case let .warming(attempt):
                (id, seconds, reason) = (attempt, configuration.warmupTimeout,
                                         "the microphone did not start")
            case let .draining(attempt):
                (id, seconds, reason) = (attempt, configuration.drainTimeout,
                                         "the microphone did not stop")
            }
            watchdog = clock.schedule(after: seconds) { [weak self] in
                // A capture fault, in the machine's own vocabulary: discard, no injection, and
                // reported as a hardware fault rather than as silence (§7, D16, invariant 7).
                self?.faulted(id, kind: .hardware, reason: reason)
            }
        }
    }

    /// What is parked on disk while an attempt is live. The agterm socket is half of it: a target
    /// alone says WHERE the light is but not WHICH agterm is showing it, and the next daemon has no
    /// other way to find out -- the attempt that lit it is gone.
    private struct ParkedAttempt: Codable {
        var target: Target
        var agtermSocket: String?

        /// Tolerates a file written by an earlier build, which held a bare `Target` -- always an
        /// agterm pane, and it still decodes as `.agterm` because that case kept the flat shape. A
        /// parked file that cannot be read is a stale indicator nobody puts out, so the fallback is
        /// worth four lines.
        static func decode(_ data: Data) -> ParkedAttempt? {
            if let parked = try? JSONDecoder().decode(ParkedAttempt.self, from: data) {
                return parked
            }
            guard let target = try? JSONDecoder().decode(Target.self, from: data) else {
                return nil
            }
            return ParkedAttempt(target: target, agtermSocket: nil)
        }
    }

    private func park(_ attempt: Attempt) {
        let parked = stateLock.withLock { () -> ParkedAttempt? in
            rememberedTarget = attempt.target
            guard parkedAttempt != attempt.id else { return nil }
            parkedAttempt = attempt.id
            return ParkedAttempt(target: attempt.target, agtermSocket: adoptedSocket)
        }
        guard let parked else { return }
        // Best effort: a target that cannot be parked costs a stale indicator after a crash that
        // has not happened, and an attempt is never blocked over it.
        try? Paths.createPrivateDirectory(
            configuration.activeTargetFile.deletingLastPathComponent())
        if let data = try? JSONEncoder().encode(parked) {
            try? data.write(to: configuration.activeTargetFile, options: .atomic)
            // `.atomic` writes through a temporary file and renames it, which lands at 0644 -- the
            // one file dicta owns that was more readable than the socket and the record beside it.
            try? FileManager.default.setAttributes(
                [.posixPermissions: Paths.privateFileMode],
                ofItemAtPath: configuration.activeTargetFile.path
            )
        }
    }

    private func unpark() {
        let hadParked = stateLock.withLock { () -> Bool in
            defer { parkedAttempt = nil }
            return parkedAttempt != nil
        }
        guard hadParked else { return }
        try? FileManager.default.removeItem(at: configuration.activeTargetFile)
    }

    // MARK: - answering

    private func respond(to transition: Transition) -> Response {
        Response(kind: transition.outcome, state: transition.state, attempt: transition.attempt,
                 target: knownTarget, message: transition.message)
    }

    private func response(_ kind: CommandOutcome, message: String? = nil) -> Response {
        let (state, attempt) = stateLock.withLock { (machine.state, machine.currentAttempt?.id) }
        return Response(kind: kind, state: state, attempt: attempt, target: knownTarget,
                        message: message, snapshot: snapshot())
    }

    /// What the daemon is doing, as one value (D27).
    ///
    /// **One function, two callers** — `status` and the `watch` stream — and that is the whole
    /// reason it exists rather than each route assembling its own. Two assemblies would drift, and
    /// the drift would show up as a UI whose first frame disagrees with its second: the panel would
    /// open saying "Ready" and then, on the first event, admit the models were never downloaded.
    func snapshot() -> StatusSnapshot {
        let (state, attempt, target, speaking) = stateLock.withLock {
            (machine.state,
             machine.currentAttempt?.id,
             machine.currentAttempt?.target ?? rememberedTarget,
             draft?.speechStartedAt)
        }
        return StatusSnapshot(
            state: state,
            readiness: readinessLock.withLock { faculties.readiness },
            attempt: attempt,
            target: target,
            // Measured from the moment capture CONFIRMED, never from the keypress:
            // `speechStartedAt` is stamped by `.captureReady` (D13, D25), so the timer cannot
            // claim to have been
            // recording during the ~95 ms before the device was live.
            speakingSeconds: speaking.map { clock.now.timeIntervalSince($0) },
            capSeconds: configuration.durationCap
        )
    }

    /// What the daemon knows about its own ability to dictate.
    ///
    /// Set from outside rather than discovered here, and that is deliberate wiring rather than
    /// laziness: the facts live in three different places — the warm-up thread's load result, the
    /// microphone's TCC callback, and whether `agtermctl` was found — and each is already known by
    /// the code that owns it. A daemon that went looking again would be asking questions it has
    /// already been told the answers to, on the attempt path, in a value the UI polls.
    /// How many `watch` streams are attached (D27). Zero when the socket is not bound.
    ///
    /// Exposed for the same reason `ControlServer.watcherCount` is: a watcher registers on its own
    /// connection thread, so anything publishing immediately after connecting would be asserting
    /// on a race rather than on behaviour.
    public var watcherCount: Int { server?.watcherCount ?? 0 }

    /// Hands the current snapshot to every `watch` stream (D27).
    ///
    /// **`sequence` is what keeps a stream monotonic.** `apply` is entered from threads that share
    /// no lock — the socket handler, capture's own thread, the drain watchdog, D15's cap — and a
    /// transition descheduled between taking `stateLock` and reaching here can otherwise be
    /// published AFTER a newer one. The daemon already stamps transitions for exactly this hazard
    /// (see the note on `apply`); this is the third place that stamp is load-bearing. Without it a
    /// finished dictation could leave the menu-bar glyph red for ever.
    ///
    /// A `nil` sequence means "not a transition" — a readiness change — and is always published:
    /// it is the newest word on a fact that moves at most twice in a daemon's lifetime.
    private func publish(sequence: UInt64? = nil) {
        guard let server else { return }
        if let sequence {
            let isNewest = readinessLock.withLock { () -> Bool in
                guard sequence > lastPublishedSequence else { return false }
                lastPublishedSequence = sequence
                return true
            }
            guard isNewest else { return }
        }
        server.publish(.update(snapshot(), sequence: sequence))
    }

    public func observe(_ change: (inout Faculties) -> Void) {
        readinessLock.withLock { change(&faculties) }
        // Readiness is not a transition, so it carries no sequence number and cannot be dropped as
        // stale — it is the newest thing known about a fact that moves at most twice in a daemon's
        // life. It is published immediately because the whole value of the fault banner is that the
        // user sees "the models are not downloaded" at login rather than after losing an utterance.
        publish()
    }

    /// Why an attempt whose recogniser produced text is nevertheless empty (§7's "a replacement
    /// produces empty text" row).
    ///
    /// `nil` when the recogniser itself heard nothing: the machine's own "nothing was recognised"
    /// is right for a quiet room, and dressing it up would be noise. Anything else names the stage
    /// that did it, because the difference decides whether the user looks at their microphone or at
    /// the file they last edited.
    static func emptiedBy(recognised: String, replaced: String, rules: RulesApplied) -> String? {
        guard Sanitizer.sanitize(recognised) != .empty else { return nil }
        guard Sanitizer.sanitize(replaced) == .empty else {
            // The dictionary handed on real text and a later stage emptied it. v1 ships no filter
            // (D9c), so this is unreachable until step 4 -- and it is worded now anyway, because
            // the alternative when it becomes reachable is a silent deletion.
            return "the text was empty after processing -- nothing was typed"
        }
        let fired = rules.fired.isEmpty
            ? "no rule reported firing"
            : "the rules that fired were " + rules.fired.joined(separator: ", ")
        return "the replacement dictionary emptied this dictation (\(fired)) -- nothing was typed"
    }

    static func reason(_ error: any Error) -> String {
        if let agterm = error as? AgtermError { return agterm.description }
        if let delivery = error as? DeliveryFailure { return delivery.description }
        if let recognition = error as? RecognitionError { return recognition.description }
        return "\(error)"
    }
}
