import DictaCore
import Foundation

// The six seams, and nothing that implements them against the real world.
//
// Every one of them exists for the same reason: the lifecycle must be drivable with no microphone,
// no model and no terminal (D19), because the rules worth asserting -- D13's ordering, D16's
// "a fault never injects", invariant 10's "text reaches the record first" -- are all about WHICH
// thing happens WHEN, and none of them can be observed by speaking into a laptop.
//
// Two shapes are used deliberately, and the difference is not stylistic:
//
//   • `Capture` reports through a sink, because its events arrive when the hardware says so and not
//     when the daemon asks. A blocking `start()` that returned once the engine was running would
//     make D13 unfalsifiable: "announce only after capture confirms" is only a claim about ordering
//     if the confirmation can arrive late, or never.
//   • `Transcriber`, `Filter` and `Injector` are synchronous and throwing, because the daemon calls
//     them from a place where it already owns the attempt and an error is the answer.

/// The audio of one attempt, held in memory and nowhere else (D14): no segmentation, no disk
/// journal, no recovery pass. Losing an utterance costs one keypress.
///
/// Mono float samples, because that is what both AVAudioEngine's converter and Parakeet want; the
/// rate travels with them so a converter bug is an assertion rather than an assumption (Task 9).
public struct Audio: Sendable, Equatable {
    public var samples: [Float]
    public var sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var duration: TimeInterval {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }

    /// The only shape the pipeline accepts (D10, §12).
    public static let requiredSampleRate: Double = 16_000
}

// MARK: - capture

/// What the microphone half tells the daemon, in the vocabulary §2 draws.
///
/// Note what is absent: a "stopped, nothing to report" case. Every route out of capture is either
/// audio in hand or a fault, so there is no third value a caller could mistake for silence
/// (invariant 7).
public enum CaptureEvent: Sendable, Equatable {
    /// The engine is running and samples are flowing. This -- not the keypress -- is what lets the
    /// user be told to speak (D13, invariant 4).
    case ready(AttemptID)
    /// The drain completed and the audio is in hand. Only after this does the attempt leave
    /// `recording` (invariant 9), so the next chord cannot race a second start over one device.
    case drained(AttemptID, Audio)
    /// The audio's integrity is in doubt: interruption, route change, engine death, a denied
    /// microphone, the duration cap. Always discards and never injects (D16, invariant 6), and is
    /// always reported as a hardware fault rather than as an empty dictation (invariant 7).
    case fault(AttemptID, reason: String)
}

public typealias CaptureEventSink = @Sendable (CaptureEvent) -> Void

/// The microphone, behind one interface that a fake can satisfy completely.
///
/// `begin` does not throw. A device that refuses to open is a `fault` through the sink like any
/// other capture failure, so there is exactly one road out of capture and no second one for a
/// caller to handle differently -- which is how "reported as silence" gets in.
public protocol Capture: Sendable {
    /// Open the device for this attempt and report through `sink`. Announces nothing.
    func begin(attempt: AttemptID, sink: @escaping CaptureEventSink)
    /// Stop and hand the audio over; answers with `.drained` or with `.fault`.
    func drain(attempt: AttemptID)
    /// Stop and throw the audio away. Every path that ends an attempt before text exists comes
    /// through here, and it answers with nothing at all.
    func discard(attempt: AttemptID)
}

// MARK: - recognition

/// Audio to the **recognised** stage's text (§2), verbatim: no cleaning, no punctuation policy, no
/// trimming. What the user said is what reaches the record.
public protocol Transcriber: Sendable {
    func transcribe(_ audio: Audio) throws -> String
}

// MARK: - the filter seam

/// The **filtered** stage (§2). v1 ships it empty (D9c): `claude -p` costs 8.6-10.5 s of fixed
/// startup per invocation (F2) and cannot be an interactive filter, and the user wants to choose
/// the engine after seeing real recogniser output.
///
/// The seam exists now anyway, and not out of optimism: raw mode is *defined* as the mode skipping
/// this stage (D3, §2). Without a stage to skip, "raw" would have no meaning to test against.
public protocol Filter: Sendable {
    func filter(_ text: String) throws -> String
}

/// The pass-through v1 ships. Deliberately not "no filter configured" spelled as `nil`: an optional
/// would push a branch into every call site, and step 4 would then have to find them all.
public struct NoFilter: Filter, Sendable {
    public init() {}
    public func filter(_ text: String) throws -> String { text }
}

// MARK: - delivery

/// Why text did not arrive. The three cases are §7's three delivery rows, kept apart because the
/// user is told something different in each -- and because only one of them may say the input line
/// is untouched.
public enum DeliveryFailure: Error, Equatable, CustomStringConvertible {
    /// Re-validation failed: the session or the pane is gone. Never re-aimed at whatever has focus
    /// now (D4, invariant 3) -- somebody else's agent would get the user's prompt.
    case targetGone(Target, reason: String)
    /// `session type` never began: the process did not launch, or agterm refused the command. No
    /// keystroke can have been delivered.
    case notStarted(Target, reason: String)
    /// `session type` began and then failed. The terminal may already hold part of the text, and it
    /// is never retried (§7): a retry after keystrokes have begun would double part of the text.
    case mayBePartial(Target, reason: String)

    public var target: Target {
        switch self {
        case let .targetGone(target, _), let .notStarted(target, _), let .mayBePartial(target, _):
            target
        }
    }

    public var description: String {
        switch self {
        case let .targetGone(_, reason):
            "the target is gone: \(reason) -- the text is in the record"
        case let .notStarted(_, reason):
            "nothing was inserted: \(reason) -- the text is in the record"
        case let .mayBePartial(_, reason):
            "the insertion may be partial: \(reason) -- the text is in the record"
        }
    }

    /// The state machine's word for this, so the mapping lives in one place rather than in every
    /// catch block. `partial` is the case §7 refuses to let be reported as a clean failure.
    public var injectionResult: InjectionResult {
        switch self {
        case .targetGone, .notStarted: .failed(reason: description)
        case .mayBePartial: .partial(reason: description)
        }
    }

    /// §9's word for it. Three rows of §7, three outcomes: the record must be able to tell "nothing
    /// was typed" from "something may have been", because only one of them means the user should
    /// look at their input line before pasting from `dictactl last`.
    public var recordOutcome: AttemptOutcome {
        switch self {
        case .targetGone: .targetGone
        case .notStarted: .injectionFailed
        case .mayBePartial: .injectionPartial
        }
    }
}

/// Keystrokes into a terminal. Whatever is handed here is **final** (§2): already replaced, already
/// filtered or deliberately not, and already sanitised (invariant 1). Its job is delivery and
/// re-validation, never repair.
public protocol Injector: Sendable {
    func inject(_ text: String, into target: Target) throws
}

// MARK: - feedback

/// §6's feedback table and §7's notifications. Nothing here throws: a notification that fails must
/// not take an attempt down with it, and there is no user-visible action left to offer anyway.
public protocol Notifier: Sendable {
    /// The indicator and the sound for a state the attempt has actually reached.
    func announce(_ feedback: Feedback, for target: Target)
    /// The reason, in the words the user sees. `nil` target when the attempt never had one.
    func notify(_ message: String, for target: Target?)
    /// Put the indicator back to idle. §7's "daemon crashed leaving a stale indicator" row: a light
    /// claiming a recording that is not happening is worse than no light.
    func clearIndicator(for target: Target)
}

// MARK: - time

/// Cancellable scheduled work: the watchdog and the duration cap, and nothing else.
public protocol ScheduledWork: Sendable {
    func cancel()
}

/// Time, injected so the watchdog (§7) and the ten-minute cap (D15) have tests that do not sleep.
/// A test that waits ten minutes is a test that gets deleted.
public protocol Clock: Sendable {
    var now: Date { get }
    @discardableResult
    func schedule(after seconds: TimeInterval,
                  _ body: @escaping @Sendable () -> Void) -> any ScheduledWork
}

/// The real one.
public struct SystemClock: Clock, Sendable {
    public init() {}

    public var now: Date { Date() }

    /// One thread per scheduled item, waiting on a semaphore so `cancel` wakes it immediately.
    ///
    /// A real `Thread` rather than `DispatchQueue.global().asyncAfter`, for the reason CLAUDE.md
    /// records about the control socket: on Darwin, Swift concurrency's executor runs on the same
    /// non-overcommit pool that `DispatchQueue.global()` draws from, and that pool does not grow
    /// when its threads block. A watchdog whose firing waits behind a blocked cooperative thread is
    /// a watchdog that fires after the thing it watched (§7). There is at most one of these per
    /// attempt, so the thread costs nothing worth counting.
    @discardableResult
    public func schedule(after seconds: TimeInterval,
                         _ body: @escaping @Sendable () -> Void) -> any ScheduledWork {
        let work = TimedWork(body: body)
        let thread = Thread { work.run(after: seconds) }
        thread.name = "dev.personal.dicta.clock"
        thread.stackSize = 128 * 1024
        thread.start()
        return work
    }
}

final class TimedWork: ScheduledWork, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var body: (@Sendable () -> Void)?

    init(body: @escaping @Sendable () -> Void) {
        self.body = body
    }

    func cancel() {
        lock.withLock { body = nil }
        gate.signal()
    }

    func run(after seconds: TimeInterval) {
        // `.success` means somebody signalled, which only `cancel` does.
        guard gate.wait(timeout: .now() + seconds) == .timedOut else { return }
        let pending = lock.withLock { () -> (@Sendable () -> Void)? in
            let body = self.body
            self.body = nil
            return body
        }
        pending?()
    }
}
