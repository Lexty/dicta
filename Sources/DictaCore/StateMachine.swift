import Foundation

// The lifecycle of an attempt, as a pure value: an event goes in, a new state and a list of effects
// come out (D19). Nothing here opens a socket, spawns `agtermctl` or reads a clock of its own,
// which is what makes every rule of §6 assertable without a microphone -- including the rules that
// would otherwise only surface by mashing a chord at the wrong moment.
//
// Effects are DATA, never closures. A closure would be untestable by construction: `#expect` can
// compare `.inject(3, target)` against what the daemon was told to do, but it cannot compare two
// functions. It also keeps the ordering assertions of D13 and invariant 4 honest -- "announce only
// after capture confirms" is a statement about which transition emits `.announce(.listening)`, and
// that is only checkable if the announcement is a value sitting in a list.

/// One press-to-press cycle (§2), identified by a monotonic id that is never reused. The id is what
/// makes a late or duplicated command answerable: a `stop` naming a spent attempt is a no-op rather
/// than a second stop applied to whatever started meanwhile.
///
/// The target is captured here, at `start`, and is never substituted afterwards (D4, §5).
public struct Attempt: Equatable, Sendable {
    public let id: AttemptID
    public let target: Target
    public let startedAt: Date

    public init(id: AttemptID, target: Target, startedAt: Date) {
        self.id = id
        self.target = target
        self.startedAt = startedAt
    }
}

/// What the recogniser came back with. Deliberately carries no text: the machine decides, the
/// daemon holds the strings. `empty` is its own case because §7 makes it its own row -- an empty
/// insertion is worse than none -- and folding it into `failed` would lose that.
public enum RecognitionResult: Equatable, Sendable {
    case text
    case empty
    case failed(reason: String)
}

/// How injection ended. `partial` exists because §7 distinguishes it: once keystrokes have begun,
/// the user must be told the insertion may be incomplete, and there is never a retry.
public enum InjectionResult: Equatable, Sendable {
    case delivered
    case failed(reason: String)
    case partial(reason: String)
}

/// §6's feedback table, as the four things the user can be shown. The mapping to
/// `agtermctl session status` and to sounds lives in `DictaRuntime`; what is normative here is
/// WHICH transition emits which of these.
public enum Feedback: String, Equatable, Sendable, CaseIterable {
    /// `active --blink`, red, `Pop`. Emitted only once capture confirms it is running (D13).
    case listening
    /// `active`, amber. The user has stopped speaking and the text is on its way.
    case working
    /// `completed --auto-reset`, `Tink`.
    case done
    /// `blocked`, `Basso`, always paired with a `notify` carrying the reason.
    case blocked
}

/// What the daemon must DO about an event. The machine performs none of it.
public enum Effect: Equatable, Sendable {
    /// Open the microphone for this attempt. Announces nothing -- see `Feedback.listening`.
    case beginCapture(AttemptID, Target)
    /// Stop capturing and hand over the audio. The attempt stays in `recording` until the drain
    /// completes (§8.9), so that the next chord cannot start a second attempt over one device.
    case drainCapture(AttemptID)
    /// Stop capturing and throw the audio away. Every path that ends an attempt before text exists
    /// goes through here (D16).
    case discardCapture(AttemptID)
    /// Turn the drained audio into text, in this mode. The mode is the stopping chord's (D3).
    case transcribe(AttemptID, Mode)
    /// Deliver **final** to this target. The text reaches the record first (invariant 10), and the
    /// target is re-validated by the runtime immediately before the keystrokes (D4, §5).
    case inject(AttemptID, Target)
    case announce(Feedback)
    /// A desktop notification carrying the reason, in the words the user sees.
    case notify(String)

    /// Used by the tests, and by anything asserting D16: a capture fault must never produce one.
    public var isInjection: Bool {
        if case .inject = self { true } else { false }
    }
}

/// The internal lifecycle. Richer than `LifecycleState` by exactly one case: `draining` is
/// `recording` with a stop already requested and the audio not yet in hand. It reports to clients
/// as `recording` because invariant 9 says the state is released only once capture has been
/// drained.
public enum Phase: Equatable, Sendable {
    case idle
    case warming(Attempt)
    case recording(Attempt)
    case draining(Attempt, Mode)
    case processing(Attempt, Mode)
    case injecting(Attempt, Mode)

    /// What the wire calls this (§6).
    public var state: LifecycleState {
        switch self {
        case .idle: .idle
        case .warming: .warming
        case .recording, .draining: .recording
        case .processing: .processing
        case .injecting: .injecting
        }
    }

    public var attempt: Attempt? {
        switch self {
        case .idle: nil
        case let .warming(attempt), let .recording(attempt): attempt
        case let .draining(attempt, _), let .processing(attempt, _), let .injecting(attempt, _):
            attempt
        }
    }

    /// The mode the stopping chord chose, once one has (D3).
    public var mode: Mode? {
        switch self {
        case .idle, .warming, .recording: nil
        case let .draining(_, mode), let .processing(_, mode), let .injecting(_, mode): mode
        }
    }
}

/// The answer to one event: what the client is told, and what the daemon must do.
public struct Transition: Equatable, Sendable {
    /// §6's distinction, kept as two values rather than one flag read two ways: a rejection is
    /// audible, a no-op is silent.
    public var outcome: CommandOutcome
    /// The state AFTER the event, so the client never has to ask a second question.
    public var state: LifecycleState
    /// The attempt the event was about, including one that has just ended.
    public var attempt: AttemptID?
    public var message: String?
    public var effects: [Effect]

    public init(outcome: CommandOutcome, state: LifecycleState, attempt: AttemptID? = nil,
                message: String? = nil, effects: [Effect] = []) {
        self.outcome = outcome
        self.state = state
        self.attempt = attempt
        self.message = message
        self.effects = effects
    }
}

/// Everything that can move the lifecycle: three commands from the user, one toggle that resolves
/// to two of them (D7), and the runtime reporting back.
public enum Event: Equatable, Sendable {
    case start(target: Target, at: Date)
    case stop(mode: Mode, attempt: AttemptID?)
    case abort(attempt: AttemptID?)
    /// Start-or-stop, resolved INSIDE the machine. The chords call this and nothing else.
    case toggle(mode: Mode, target: Target, at: Date, attempt: AttemptID?)
    case captureReady(AttemptID)
    case captureDrained(AttemptID)
    case recognised(AttemptID, RecognitionResult)
    case injectionFinished(AttemptID, InjectionResult)
    /// A capture fault (§2): the audio's integrity is in doubt. Always discards, never injects.
    case fault(AttemptID, reason: String)
}

public struct StateMachine: Equatable, Sendable {
    public private(set) var phase: Phase = .idle
    /// Monotonic and never handed back, even to an attempt that faulted one millisecond in.
    private var nextID: AttemptID = 1

    public init() {}

    public var state: LifecycleState { phase.state }
    public var currentAttempt: Attempt? { phase.attempt }

    // MARK: - The one entry point

    public mutating func apply(_ event: Event) -> Transition {
        switch event {
        case let .start(target, now):
            return performStart(target: target, at: now)
        case let .stop(mode, attempt):
            if let spent = spentAttempt(attempt) { return spent }
            return performStop(mode: mode)
        case let .abort(attempt):
            if let spent = spentAttempt(attempt) { return spent }
            return performAbort()
        case let .toggle(mode, target, now, attempt):
            // D7: `status | grep idle && start || stop` is two round trips with a window between
            // them in which the duration cap can fire or a second chord can land, so one keypress
            // could both start and stop. Resolved here, the same state always resolves one way.
            if let spent = spentAttempt(attempt) { return spent }
            if case .idle = phase {
                return performStart(target: target, at: now)
            }
            return performStop(mode: mode)
        case let .captureReady(id):
            return performCaptureReady(id)
        case let .captureDrained(id):
            return performCaptureDrained(id)
        case let .recognised(id, result):
            return performRecognised(id, result)
        case let .injectionFinished(id, result):
            return performInjectionFinished(id, result)
        case let .fault(id, reason):
            return performFault(id, reason: reason)
        }
    }

    // MARK: - Thin wrappers, so a caller reads as a sentence

    public mutating func start(target: Target, at now: Date) -> Transition {
        apply(.start(target: target, at: now))
    }

    public mutating func stop(mode: Mode, attempt: AttemptID? = nil) -> Transition {
        apply(.stop(mode: mode, attempt: attempt))
    }

    public mutating func abort(attempt: AttemptID? = nil) -> Transition {
        apply(.abort(attempt: attempt))
    }

    public mutating func toggle(mode: Mode, target: Target, at now: Date,
                                attempt: AttemptID? = nil) -> Transition {
        apply(.toggle(mode: mode, target: target, at: now, attempt: attempt))
    }

    public mutating func captureReady(_ id: AttemptID) -> Transition {
        apply(.captureReady(id))
    }

    public mutating func captureDrained(_ id: AttemptID) -> Transition {
        apply(.captureDrained(id))
    }

    public mutating func recognised(_ id: AttemptID, _ result: RecognitionResult) -> Transition {
        apply(.recognised(id, result))
    }

    public mutating func injectionFinished(_ id: AttemptID,
                                           _ result: InjectionResult) -> Transition {
        apply(.injectionFinished(id, result))
    }

    public mutating func fault(_ id: AttemptID, reason: String) -> Transition {
        apply(.fault(id, reason: reason))
    }

    // MARK: - Commands

    private mutating func performStart(target: Target, at now: Date) -> Transition {
        switch phase {
        case .idle:
            let attempt = Attempt(id: nextID, target: target, startedAt: now)
            nextID += 1
            phase = .warming(attempt)
            // Nothing is announced here (D13, invariant 4): announcing at the keypress trains the
            // user to speak before audio flows and lose the first syllable every time.
            return accepted(attempt: attempt.id,
                            effects: [.beginCapture(attempt.id, attempt.target)])
        case .warming, .recording, .draining:
            // Including `draining`: the first attempt still owns the input device (§8.9), so a
            // second start is refused rather than queued behind it.
            return rejected("already recording")
        case .processing, .injecting:
            return rejected("still working")
        }
    }

    private mutating func performStop(mode: Mode) -> Transition {
        switch phase {
        case .idle:
            return rejected("nothing to stop")
        case let .warming(attempt):
            // No audio exists yet, so nothing can be delivered. Ending here rather than sending an
            // empty buffer down the pipeline, which would report as silence (invariant 7).
            return cancel(attempt, reason: "stopped before the microphone started",
                          discardingCapture: true)
        case let .recording(attempt):
            phase = .draining(attempt, mode)
            return accepted(attempt: attempt.id,
                            effects: [.drainCapture(attempt.id), .announce(.working)])
        case .draining, .processing, .injecting:
            // Quiet: pressing stop again because nothing visibly happened is normal behaviour, and
            // an alarming noise would punish it. Never a second delivery either (invariant 5).
            return noop("already stopping")
        }
    }

    private mutating func performAbort() -> Transition {
        switch phase {
        case .idle:
            return noop("nothing to abort")
        case let .warming(attempt), let .recording(attempt):
            return cancel(attempt, reason: "aborted", discardingCapture: true)
        case let .draining(attempt, _):
            return cancel(attempt, reason: "aborted", discardingCapture: true)
        case let .processing(attempt, _):
            // Capture is already over; there is only the text to drop, and nothing is injected.
            return cancel(attempt, reason: "aborted", discardingCapture: false)
        case let .injecting(attempt, _):
            // D20: keystrokes already in the terminal cannot be recalled, so a cancellation the
            // user then watches being contradicted on screen is worse than the refusal.
            return rejected("already injecting -- keystrokes cannot be recalled",
                            attempt: attempt.id)
        }
    }

    // MARK: - Progress reported by the runtime

    private mutating func performCaptureReady(_ id: AttemptID) -> Transition {
        guard case let .warming(attempt) = phase, attempt.id == id else {
            // A late confirmation from an attempt the user abandoned must not resurrect it, and
            // must not fire the "listening" sound at a user who is no longer speaking.
            return ignored(id)
        }
        phase = .recording(attempt)
        return accepted(attempt: id, effects: [.announce(.listening)])
    }

    private mutating func performCaptureDrained(_ id: AttemptID) -> Transition {
        guard case let .draining(attempt, mode) = phase, attempt.id == id else {
            return ignored(id)
        }
        phase = .processing(attempt, mode)
        return accepted(attempt: id, effects: [.transcribe(id, mode)])
    }

    private mutating func performRecognised(_ id: AttemptID,
                                            _ result: RecognitionResult) -> Transition {
        guard case let .processing(attempt, mode) = phase, attempt.id == id else {
            return ignored(id)
        }
        switch result {
        case .text:
            phase = .injecting(attempt, mode)
            return accepted(attempt: id, effects: [.inject(id, attempt.target)])
        case .empty:
            phase = .idle
            return accepted(attempt: id, message: "nothing was recognised",
                            effects: blocked("nothing was recognised"))
        case let .failed(reason):
            phase = .idle
            return accepted(attempt: id, message: reason, effects: blocked(reason))
        }
    }

    private mutating func performInjectionFinished(_ id: AttemptID,
                                                   _ result: InjectionResult) -> Transition {
        guard case let .injecting(attempt, _) = phase, attempt.id == id else {
            return ignored(id)
        }
        phase = .idle
        switch result {
        case .delivered:
            return accepted(attempt: id, effects: [.announce(.done)])
        case let .failed(reason), let .partial(reason):
            // Never a retry (§7): a retry after keystrokes have begun would double part of the
            // text. The text is already in the record, which is how it survives this.
            return accepted(attempt: id, message: reason, effects: blocked(reason))
        }
    }

    private mutating func performFault(_ id: AttemptID, reason: String) -> Transition {
        guard let attempt = currentAttempt, attempt.id == id else {
            return ignored(id)
        }
        switch phase {
        case .idle:
            return ignored(id)
        case .warming, .recording, .draining:
            return cancel(attempt, reason: reason, discardingCapture: true)
        case .processing:
            return cancel(attempt, reason: reason, discardingCapture: false)
        case .injecting:
            // The audio is long gone and the keystrokes are already going in; there is nothing to
            // discard and nothing truthful left to announce. D20 from the other direction.
            return ignored(id)
        }
    }

    // MARK: - Building a transition

    /// A command naming an attempt that is not the live one -- a spent id, or one never issued.
    /// Silent by §6: the chord was pressed for something that is already over, which is not an
    /// error. A command naming NO attempt (every chord) is not this case and falls through to the
    /// table. Returns `nil` when the command is about the live attempt.
    private func spentAttempt(_ id: AttemptID?) -> Transition? {
        guard let id, currentAttempt?.id != id else { return nil }
        return Transition(outcome: .noop, state: state, attempt: currentAttempt?.id,
                          message: "attempt #\(id) is not in progress")
    }

    /// A progress event for an attempt that has been abandoned or superseded.
    private func ignored(_ id: AttemptID) -> Transition {
        Transition(outcome: .noop, state: state, attempt: currentAttempt?.id,
                   message: "attempt #\(id) is no longer in progress")
    }

    private func accepted(attempt: AttemptID?, message: String? = nil,
                          effects: [Effect]) -> Transition {
        Transition(outcome: .accepted, state: state, attempt: attempt, message: message,
                   effects: effects)
    }

    private func rejected(_ reason: String, attempt: AttemptID? = nil) -> Transition {
        // Audible (§6): a refusal the user cannot hear is a keypress that appears to have worked.
        Transition(outcome: .rejected, state: state, attempt: attempt ?? currentAttempt?.id,
                   message: reason, effects: blocked(reason))
    }

    private func noop(_ reason: String) -> Transition {
        Transition(outcome: .noop, state: state, attempt: currentAttempt?.id, message: reason)
    }

    private mutating func cancel(_ attempt: Attempt, reason: String,
                                 discardingCapture: Bool) -> Transition {
        phase = .idle
        var effects: [Effect] = []
        if discardingCapture {
            effects.append(.discardCapture(attempt.id))
        }
        // Visible, even though the user asked for it: the indicator must not be left claiming a
        // recording that is not happening (§7), and property 2 says nothing disappears quietly.
        effects += blocked(reason)
        return accepted(attempt: attempt.id, message: reason, effects: effects)
    }

    /// §6's last feedback row: the indicator goes `blocked` and the reason is shown alongside it.
    /// Always both -- an indicator that goes red with nothing to read is the "lost silently"
    /// failure wearing a colour.
    private func blocked(_ reason: String) -> [Effect] {
        [.announce(.blocked), .notify(reason)]
    }
}
