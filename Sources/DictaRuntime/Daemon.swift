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
}

extension Agterm: TargetResolver {}

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
    public typealias TerminalProvider = @Sendable (String?) -> Terminal

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

        public init(
            socketPath: String = Paths.current.socket.path,
            activeTargetFile: URL = Paths.current.support
                .appendingPathComponent("active-target.json"),
            warmupTimeout: TimeInterval = 5,
            drainTimeout: TimeInterval = 10
        ) {
            self.socketPath = socketPath
            self.activeTargetFile = activeTargetFile
            self.warmupTimeout = warmupTimeout
            self.drainTimeout = drainTimeout
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

    public let configuration: Configuration
    private let capture: any Capture
    private let transcriber: any Transcriber
    private let filter: any Filter
    private let clock: any Clock
    private let provider: TerminalProvider

    /// Guards the machine and the small amount of per-attempt state that travels with it. Held for
    /// the duration of a `machine.apply` and never across an effect.
    private let stateLock = NSLock()
    private var machine = StateMachine()
    /// The audio of the attempt being processed, held in RAM and nowhere else (D14).
    private var drained: (attempt: AttemptID, audio: Audio)?
    /// **final** for the attempt about to be injected -- already replaced, already filtered or
    /// deliberately not, already sanitised (invariant 1).
    private var pendingFinal: (attempt: AttemptID, text: String)?
    /// The last target dicta actually used. Notifications about an attempt that has already ended
    /// need somewhere to land, and this is that somewhere.
    private var rememberedTarget: Target?
    private var parkedAttempt: AttemptID?
    private var terminal: Terminal
    private var watched: Watched = .nothing
    private var watchdog: (any ScheduledWork)?
    private var server: ControlServer?

    // MARK: - construction

    public init(
        configuration: Configuration = Configuration(),
        capture: any Capture,
        transcriber: any Transcriber,
        filter: any Filter = NoFilter(),
        clock: any Clock = SystemClock(),
        terminal provider: @escaping TerminalProvider
    ) {
        self.configuration = configuration
        self.capture = capture
        self.transcriber = transcriber
        self.filter = filter
        self.clock = clock
        self.provider = provider
        terminal = provider(nil)
    }

    /// One fixed agterm, for tests and for any caller that does not care about `$AGT_SOCKET`.
    public convenience init(
        configuration: Configuration = Configuration(),
        capture: any Capture,
        transcriber: any Transcriber,
        filter: any Filter = NoFilter(),
        clock: any Clock = SystemClock(),
        resolver: any TargetResolver,
        injector: any Injector,
        notifier: any Notifier
    ) {
        let fixed = Terminal(resolver: resolver, injector: injector, notifier: notifier)
        self.init(configuration: configuration, capture: capture, transcriber: transcriber,
                  filter: filter, clock: clock, terminal: { _ in fixed })
    }

    // MARK: - lifecycle

    /// Binds the control socket and starts serving. Throws `alreadyRunning` when a live daemon
    /// already owns the path (§7): one daemon, one microphone.
    public func start() throws {
        let server = ControlServer(path: configuration.socketPath) { [weak self] incoming in
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
    }

    /// §7's stale-indicator row. The parked file exists only while an attempt is live, so finding
    /// one at startup means the previous daemon died mid-attempt with a light still on.
    private func clearStaleIndicator() {
        guard let data = try? Data(contentsOf: configuration.activeTargetFile),
              let target = try? JSONDecoder().decode(Target.self, from: data)
        else { return }
        terminal.notifier.clearIndicator(for: target)
        try? FileManager.default.removeItem(at: configuration.activeTargetFile)
    }

    // MARK: - what a test drives

    public var state: LifecycleState { stateLock.withLock { machine.state } }
    public var currentAttempt: Attempt? { stateLock.withLock { machine.currentAttempt } }
    /// The internal phase, which distinguishes `draining` from `recording` (§8.9).
    public var phase: Phase { stateLock.withLock { machine.phase } }

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
            notifier.notify(message, for: knownTarget)
            return response(.rejected, message: message)
        }
    }

    private func handle(_ request: Request) -> Response {
        switch request.cmd {
        case .status:
            return response(.accepted)
        case .last:
            // The record arrives in Task 7. Saying so beats answering with an empty string, which
            // reads as "you have never dictated anything".
            return response(.noop, message: "dicta keeps no record yet")
        case .stop:
            return respond(to: apply(.stop(mode: request.mode ?? .clean, attempt: request.attempt)))
        case .abort:
            return respond(to: apply(.abort(attempt: request.attempt)))
        case .start, .toggle:
            return begin(request)
        }
    }

    /// The two verbs that can begin an attempt, and therefore the two that need a target (§5).
    ///
    /// The start-or-stop decision still belongs to the machine (D7): what is decided here is only
    /// whether a pane must be resolved, and that costs an `agtermctl tree --json` -- 38 ms of the
    /// 150 ms budget (F4), which is not worth spending on a chord that turns out to mean "stop".
    private func begin(_ request: Request) -> Response {
        if let live = currentAttempt {
            // The stop branch of `toggle` ignores the event's target entirely, and the live
            // attempt's own target is the only one D4 permits, so handing it over resolves nothing
            // and substitutes nothing.
            return respond(to: apply(event(for: request, target: live.target)))
        }
        guard let sessionID = request.sessionID, !sessionID.isEmpty else {
            return reject("\(request.cmd.rawValue) needs the session the chord fired in")
        }
        adoptTerminal(agtermSocket: request.agtermSocket)
        let target: Target
        do {
            target = try terminal.resolver.resolveTarget(sessionID: sessionID)
        } catch {
            // Fail closed (D6). A pane this build cannot name exactly is not one it guesses at:
            // the alternative is somebody else's agent receiving the user's prompt.
            return reject(Self.reason(error))
        }
        return respond(to: apply(event(for: request, target: target)))
    }

    private func event(for request: Request, target: Target) -> Event {
        request.cmd == .toggle
            ? .toggle(mode: request.mode ?? .clean, target: target, at: clock.now,
                      attempt: request.attempt)
            : .start(target: target, at: clock.now)
    }

    /// A refusal the machine never saw, because the command did not survive far enough to become an
    /// event. Notification-only for the same reason as an undecodable frame: no target could be
    /// named, and lighting the previous attempt's pane would be D4's substitution wearing a colour.
    private func reject(_ message: String) -> Response {
        notifier.notify(message, for: nil)
        return response(.rejected, message: message)
    }

    // MARK: - applying an event

    @discardableResult
    private func apply(_ event: Event) -> Transition {
        let (transition, phase) = stateLock.withLock {
            (machine.apply(event), machine.phase)
        }
        // Before the effects, so that `.beginCapture` and `.drainCapture` are already being watched
        // when they are performed -- a capture that reports synchronously would otherwise leave a
        // watchdog armed on an attempt that has already moved on.
        sync(phase)
        for effect in transition.effects { perform(effect) }
        return transition
    }

    private func perform(_ effect: Effect) {
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
        case let .transcribe(id, mode):
            recognise(id, mode: mode)
        case let .inject(id, target):
            deliver(id, to: target)
        case let .announce(feedback):
            // An indicator needs a pane. There is one for every announcement the machine emits,
            // because each is about an attempt that reached a state.
            if let target = knownTarget { notifier.announce(feedback, for: target) }
        case let .notify(message):
            notifier.notify(message, for: knownTarget)
        }
    }

    /// What capture reports, on capture's own thread.
    private func receive(_ event: CaptureEvent) {
        switch event {
        case let .ready(id):
            apply(.captureReady(id))
        case let .drained(id, audio):
            // Stored before the event, because the `.transcribe` effect the event produces is
            // performed synchronously and needs it. Stored against the id, so a drain belonging to
            // an abandoned attempt cannot become the next attempt's audio.
            stateLock.withLock { drained = (id, audio) }
            apply(.captureDrained(id))
        case let .fault(id, reason):
            // Always discards, never injects (D16, invariant 6), and always worded as a hardware
            // fault rather than as silence (invariant 7) -- the reason travels from capture.
            apply(.fault(id, reason: reason))
        }
    }

    // MARK: - the text pipeline (§2)

    private func recognise(_ id: AttemptID, mode: Mode) {
        guard let audio = takeAudio(id) else {
            apply(.recognised(id, .failed(reason: "the audio was lost before it could be read")))
            return
        }
        let recognised: String
        do {
            recognised = try transcriber.transcribe(audio)
        } catch {
            // §7: no injection, notify, and the attempt is recorded with its error and no text
            // (Task 7 writes that row).
            apply(.recognised(id, .failed(reason: "the recogniser failed: \(Self.reason(error))")))
            return
        }

        // **replaced** (§2). The Tier 0 dictionary arrives in Task 11; until then this stage is the
        // identity, which is why it is named rather than skipped -- the filter's fallback is
        // *replaced*, not *recognised*, and that distinction has to have somewhere to live.
        let replaced = recognised

        var text = replaced
        var filterFailure: String?
        if mode == .clean {
            // raw skips exactly this stage and nothing else (§2, D3).
            do {
                text = try filter.filter(replaced)
            } catch {
                // §7: a failing filter must never cost the user their words, so it falls back to
                // **replaced** rather than ending the attempt.
                text = replaced
                filterFailure = "the filter did not run: \(Self.reason(error))"
            }
        }

        // Last, always (invariant 1): both stages above can introduce a newline, and
        // `agtermctl session type` turns a newline into a Return that SUBMITS the input line (D8).
        switch Sanitizer.sanitize(text) {
        case .empty:
            // An empty insertion is worse than none (§7).
            apply(.recognised(id, .empty))
        case let .line(final):
            stateLock.withLock { pendingFinal = (id, final) }
            let transition = apply(.recognised(id, .text))
            guard transition.effects.contains(where: \.isInjection) else {
                // The attempt was abandoned while the recogniser was running -- an abort arriving
                // mid-inference is exactly the case §6 calls a cancel. Nothing is injected, and the
                // text does not sit around waiting for a later path to find it.
                forget(id)
                return
            }
            // §7's filter row, told after the fallback has been delivered rather than before: an
            // attempt the user has already cancelled does not need a report about its filter.
            if let filterFailure { notifier.notify(filterFailure, for: knownTarget) }
        }
    }

    private func deliver(_ id: AttemptID, to target: Target) {
        // Task 7 writes the record here, BEFORE the injection is attempted (invariant 10): that is
        // the only route by which the text survives a delivery failure.
        guard let final = takeFinal(id) else {
            apply(.injectionFinished(id, .failed(reason: "the text was lost before it was typed")))
            return
        }
        guard Sanitizer.isInjectable(final) else {
            // Unreachable through `Sanitizer.sanitize`, and asserted anyway: if it ever failed
            // here, injecting would submit a half-written prompt, and refusing is better (§8.2).
            apply(.injectionFinished(id, .failed(reason: "the text is not a single line")))
            return
        }
        do {
            // Re-validates both halves of the target itself (D4, §8.3) and never retries (§7).
            try terminal.injector.inject(final, into: target)
            apply(.injectionFinished(id, .delivered))
        } catch let failure as DeliveryFailure {
            apply(.injectionFinished(id, failure.injectionResult))
        } catch {
            apply(.injectionFinished(id, .failed(reason: Self.reason(error))))
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

    /// The notifier of the agterm this attempt belongs to.
    private var notifier: any Notifier { stateLock.withLock { terminal.notifier } }

    private func adoptTerminal(agtermSocket: String?) {
        stateLock.withLock { terminal = provider(agtermSocket) }
    }

    // MARK: - the watchdog, and the parked target

    /// Everything that must follow the phase rather than an individual event: which state is being
    /// watched, and whether a target is parked on disk for the next daemon to tidy up.
    private func sync(_ phase: Phase) {
        switch phase {
        case .idle:
            setWatchdog(.nothing)
            unpark()
        case let .warming(attempt):
            park(attempt)
            setWatchdog(.warming(attempt.id))
        case let .draining(attempt, _):
            setWatchdog(.draining(attempt.id))
        case .recording, .processing, .injecting:
            setWatchdog(.nothing)
        }
    }

    private func setWatchdog(_ next: Watched) {
        let previous = stateLock.withLock { () -> Watched in
            let previous = watched
            watched = next
            return previous
        }
        // Re-arming on every event would keep pushing the deadline away, so a wedged attempt that
        // is being poked by repeated chords would never time out.
        guard previous != next else { return }
        stateLock.withLock { watchdog?.cancel(); watchdog = nil }

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
        let work = clock.schedule(after: seconds) { [weak self] in
            // A capture fault, in the machine's own vocabulary: discard, no injection, and reported
            // as a hardware fault rather than as silence (§7, D16, invariant 7).
            self?.apply(.fault(id, reason: reason))
        }
        stateLock.withLock { watchdog = work }
    }

    private func park(_ attempt: Attempt) {
        let alreadyParked = stateLock.withLock { () -> Bool in
            rememberedTarget = attempt.target
            guard parkedAttempt != attempt.id else { return true }
            parkedAttempt = attempt.id
            return false
        }
        guard !alreadyParked else { return }
        // Best effort: a target that cannot be parked costs a stale indicator after a crash that
        // has not happened, and an attempt is never blocked over it.
        try? FileManager.default.createDirectory(
            at: configuration.activeTargetFile.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if let data = try? JSONEncoder().encode(attempt.target) {
            try? data.write(to: configuration.activeTargetFile, options: .atomic)
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
                        message: message)
    }

    static func reason(_ error: any Error) -> String {
        if let agterm = error as? AgtermError { return agterm.description }
        if let delivery = error as? DeliveryFailure { return delivery.description }
        return "\(error)"
    }
}
