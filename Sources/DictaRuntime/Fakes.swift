import DictaCore
import Foundation

// The fakes behind every seam, shipped in the library rather than in the test runner.
//
// They live here for one reason: the `Dicta` executable must be able to bring the daemon up with
// fakes behind the microphone and the terminal (Task 6), so the whole lifecycle can be exercised on
// a machine with no TCC grant and no models. A fake that only the test runner can reach cannot do
// that, because SwiftPM will not let an executable target import the test runner.
//
// Every one of them is @unchecked Sendable over a lock rather than an actor. The daemon serialises
// its own work already (see `ControlServer`'s handler lock), and a fake that needed `await` would
// force the seams to be async, which would make the ordering assertions of D13 and invariant 10
// rest on scheduling instead of on the code under test.

/// A microphone the test drives by hand.
///
/// Nothing happens on its own: `begin` records the call and reports NOTHING until the test says
/// `reportReady`. That asymmetry is the point -- an attempt that is never confirmed is exactly the
/// case D13 and the watchdog exist for, and a fake that confirmed itself would hide it.
public final class FakeCapture: Capture, @unchecked Sendable {
    public enum Call: Equatable, Sendable {
        case begin(AttemptID)
        case drain(AttemptID)
        case discard(AttemptID)
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    /// Sinks are installed and never removed, so a LATE event still has somewhere to arrive: an
    /// abandoned attempt's fault must reach the daemon and be ignored there, on the id, rather than
    /// being swallowed here where no rule is being tested.
    private var sinks: [AttemptID: CaptureEventSink] = [:]
    private var open: Set<AttemptID> = []
    private var audio: Audio

    /// What `drain` hands back when the test does not say otherwise.
    public init(audio: Audio = Audio(samples: [0.0, 0.1, -0.1], sampleRate: 16_000)) {
        self.audio = audio
    }

    public var callLog: [Call] { lock.withLock { calls } }

    /// Attempts whose device is still open -- what §8.9's "capture has actually been drained" looks
    /// like from outside.
    public var isOpen: Bool { lock.withLock { !open.isEmpty } }

    // MARK: the seam

    public func begin(attempt: AttemptID, sink: @escaping CaptureEventSink) {
        lock.withLock {
            calls.append(.begin(attempt))
            sinks[attempt] = sink
            open.insert(attempt)
        }
    }

    /// Deliberately does NOT deliver by itself: `drain` records the request, and the test decides
    /// when -- or whether -- the audio arrives. A drain that never completes is §7's wedged daemon.
    public func drain(attempt: AttemptID) {
        lock.withLock { calls.append(.drain(attempt)) }
    }

    public func discard(attempt: AttemptID) {
        lock.withLock {
            calls.append(.discard(attempt))
            open.remove(attempt)
        }
    }

    // MARK: what the test drives

    public func reportReady(_ attempt: AttemptID) {
        sink(for: attempt)?(.ready(attempt))
    }

    public func reportDrained(_ attempt: AttemptID, audio: Audio? = nil) {
        let payload = audio ?? lock.withLock { self.audio }
        let sink = lock.withLock { () -> CaptureEventSink? in
            open.remove(attempt)
            return sinks[attempt]
        }
        sink?(.drained(attempt, payload))
    }

    /// A fault reaches the daemon whatever state the attempt is in -- including after a discard,
    /// which is the "a late event must not resurrect an abandoned attempt" case.
    public func reportFault(_ attempt: AttemptID, reason: String) {
        let sink = lock.withLock { () -> CaptureEventSink? in
            open.remove(attempt)
            return sinks[attempt]
        }
        sink?(.fault(attempt, reason: reason))
    }

    private func sink(for attempt: AttemptID) -> CaptureEventSink? {
        lock.withLock { sinks[attempt] }
    }
}

/// A recogniser whose output is deliberately hostile.
///
/// It contains a newline, a double space and a trailing space, and it is NOT to be tidied up. If
/// the sanitiser is ever bypassed, `agtermctl session type` turns that newline into a Return and
/// submits the half-written prompt (§8.1, D8) -- loudly, at the first end-to-end run, instead of
/// quietly in front of an agent six weeks from now.
public final class FakeTranscriber: Transcriber, @unchecked Sendable {
    /// The canned transcript. Leading space, an embedded newline, a double space, trailing space.
    public static let hostileText = " dicta hears you\nfrom the  fake transcriber "

    /// What the same text looks like after `Sanitizer.sanitize` -- one line, single spaces. Kept
    /// here so a test asserts against a value rather than against its own copy of the algorithm.
    public static let sanitizedHostileText = "dicta hears you from the fake transcriber"

    private let lock = NSLock()
    private var text: String
    private var error: (any Error)?
    private var seen: [Audio] = []

    public init(text: String = FakeTranscriber.hostileText) {
        self.text = text
    }

    /// Everything it was asked to transcribe -- the evidence for "no model load on the hot path"
    /// and for "a fault injected nothing".
    public var transcribed: [Audio] { lock.withLock { seen } }

    public func setText(_ text: String) { lock.withLock { self.text = text } }

    /// §7's "recogniser throws, or the model is unavailable" row.
    public func setError(_ error: (any Error)?) { lock.withLock { self.error = error } }

    public func transcribe(_ audio: Audio) throws -> String {
        let (text, error) = lock.withLock { () -> (String, (any Error)?) in
            seen.append(audio)
            return (self.text, self.error)
        }
        if let error { throw error }
        return text
    }
}

/// An injector that records exactly what it was handed, byte for byte.
///
/// "Exactly" is the whole value of it: invariant 2 is asserted by comparing the delivered string
/// with the sanitised one, and a fake that trimmed, normalised or logged a prettier version would
/// make that comparison meaningless.
public final class FakeInjector: Injector, @unchecked Sendable {
    public struct Delivery: Equatable, Sendable {
        public let text: String
        public let target: Target

        public init(text: String, target: Target) {
            self.text = text
            self.target = target
        }
    }

    private let lock = NSLock()
    private var deliveries: [Delivery] = []
    private var failure: DeliveryFailure?

    public init() {}

    public var delivered: [Delivery] { lock.withLock { deliveries } }
    public var lastText: String? { lock.withLock { deliveries.last?.text } }

    /// Arms one of §7's delivery rows. The attempt still records the delivery, because the daemon
    /// must be able to tell "nothing was typed" from "something may have been".
    public func setFailure(_ failure: DeliveryFailure?) { lock.withLock { self.failure = failure } }

    public func inject(_ text: String, into target: Target) throws {
        let failure = lock.withLock { () -> DeliveryFailure? in
            deliveries.append(Delivery(text: text, target: target))
            return self.failure
        }
        if let failure { throw failure }
    }
}

/// Everything the user would have seen or heard, in order.
///
/// Order is the assertion: D13 says nothing is announced before capture confirms it is running, and
/// that is a statement about where `.announce(.listening)` sits in this list, not about whether
/// it is in it.
public final class FakeNotifier: Notifier, @unchecked Sendable {
    public enum Signal: Equatable, Sendable {
        case announce(Feedback, Target)
        case notify(String, Target?)
        case clear(Target)
    }

    private let lock = NSLock()
    private var log: [Signal] = []

    public init() {}

    public var signals: [Signal] { lock.withLock { log } }

    public var announcements: [Feedback] {
        signals.compactMap { if case let .announce(feedback, _) = $0 { feedback } else { nil } }
    }

    public var messages: [String] {
        signals.compactMap { if case let .notify(message, _) = $0 { message } else { nil } }
    }

    public func announce(_ feedback: Feedback, for target: Target) {
        lock.withLock { log.append(.announce(feedback, target)) }
    }

    public func notify(_ message: String, for target: Target?) {
        lock.withLock { log.append(.notify(message, target)) }
    }

    public func clearIndicator(for target: Target) {
        lock.withLock { log.append(.clear(target)) }
    }
}

/// Time the test moves by hand.
public final class FakeClock: Clock, @unchecked Sendable {
    private final class Pending: ScheduledWork, @unchecked Sendable {
        let due: Date
        let sequence: Int
        private let lock = NSLock()
        private var body: (@Sendable () -> Void)?

        init(due: Date, sequence: Int, body: @escaping @Sendable () -> Void) {
            self.due = due
            self.sequence = sequence
            self.body = body
        }

        func cancel() { lock.withLock { body = nil } }

        func take() -> (@Sendable () -> Void)? {
            lock.withLock {
                let body = self.body
                self.body = nil
                return body
            }
        }
    }

    private let lock = NSLock()
    private var current: Date
    private var pending: [Pending] = []
    private var sequence = 0

    public init(now: Date = Date(timeIntervalSince1970: 1_766_000_000)) {
        current = now
    }

    public var now: Date { lock.withLock { current } }

    /// Work scheduled and not yet fired or cancelled -- the evidence that a watchdog was armed, and
    /// that finishing an attempt disarms it.
    public var scheduledCount: Int { lock.withLock { pending.count } }

    @discardableResult
    public func schedule(after seconds: TimeInterval,
                         _ body: @escaping @Sendable () -> Void) -> any ScheduledWork {
        lock.withLock {
            sequence += 1
            let work = Pending(due: current.addingTimeInterval(seconds), sequence: sequence,
                               body: body)
            pending.append(work)
            return work
        }
    }

    /// Moves time forward and fires everything that came due, oldest deadline first. Bodies run
    /// outside the lock, so one that schedules more work does not deadlock -- which is exactly what
    /// a watchdog rearming itself would do.
    public func advance(by seconds: TimeInterval) {
        let target = lock.withLock { () -> Date in
            current = current.addingTimeInterval(seconds)
            return current
        }
        while true {
            let next = lock.withLock { () -> Pending? in
                guard let index = pending.indices
                    .filter({ pending[$0].due <= target })
                    .min(by: { (pending[$0].due, pending[$0].sequence)
                            < (pending[$1].due, pending[$1].sequence) })
                else { return nil }
                return pending.remove(at: index)
            }
            guard let next else { return }
            next.take()?()
        }
    }
}
