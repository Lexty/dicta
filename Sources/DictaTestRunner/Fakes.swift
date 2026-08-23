import DictaCore
import DictaRuntime
import Foundation

// The fakes behind every seam.
//
// They used to live in DictaRuntime, on the grounds that the `Dicta` executable had to be able to
// bring the daemon up with fakes behind the microphone and the terminal (Task 6). That reason
// expired: `Sources/Dicta/main.swift` now wires `AudioCapture`, `ParakeetTranscriber`, `Agterm` and
// `FileHistory`, and references no fake at all. What was left was four hundred lines of test
// doubles inside the shipped library -- `FakeTranscriber` among them, whose entire design point is
// emitting a newline that would submit a half-written prompt if the sanitiser were ever bypassed.
// Nothing constructs it in the daemon, but a hostile canned transcript should not be reachable from
// the binary that types into a terminal at all.
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
    ///
    /// `hardware` by default because that is what most of §7's rows are; the kind is spelled out at
    /// the call sites where it is the point -- a denied microphone, and D15's cap.
    public func reportFault(_ attempt: AttemptID, kind: FaultKind = .hardware, reason: String) {
        let sink = lock.withLock { () -> CaptureEventSink? in
            open.remove(attempt)
            return sinks[attempt]
        }
        sink?(.fault(attempt, kind: kind, reason: reason))
    }

    private func sink(for attempt: AttemptID) -> CaptureEventSink? {
        lock.withLock { sinks[attempt] }
    }
}

/// A microphone that confirms and hands over at once, holding no audio.
///
/// This is the one fake the EXECUTABLE needs rather than the tests. Step 1's acceptance criterion
/// is a human pressing a chord and watching the canned transcript arrive in the input line, and a
/// capture that waits to be driven cannot satisfy it. The tests keep using `FakeCapture`, whose
/// whole value is the opposite -- that it does not confirm by itself.
///
/// It reports synchronously, from inside `begin` and `drain`. That is deliberate: it makes the
/// daemon's re-entrancy real on the development path, so a lock held across an effect shows up here
/// rather than on the first day the microphone is wired in.
public final class ImmediateCapture: Capture, @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [AttemptID: CaptureEventSink] = [:]

    public init() {}

    public func begin(attempt: AttemptID, sink: @escaping CaptureEventSink) {
        lock.withLock { sinks[attempt] = sink }
        sink(.ready(attempt))
    }

    public func drain(attempt: AttemptID) {
        let sink = lock.withLock { sinks.removeValue(forKey: attempt) }
        sink?(.drained(attempt, Audio(samples: [], sampleRate: Audio.requiredSampleRate)))
    }

    public func discard(attempt: AttemptID) {
        _ = lock.withLock { sinks.removeValue(forKey: attempt) }
    }
}

/// Target resolution the test decides (§5, D6): a fixed pane, or a refusal.
///
/// The refusals are the interesting half. "The tree names no active pane", "it names two" and
/// "`agtermctl` is not installed" all have to end the attempt BEFORE capture opens, and none can
/// be produced from a live terminal on demand.
public final class FakeTargetResolver: TargetResolver, @unchecked Sendable {
    private let lock = NSLock()
    private var pane: Pane
    private var error: (any Error)?
    private var seen: [String] = []

    public init(pane: Pane = .left) {
        self.pane = pane
    }

    /// Every session id resolution was asked about -- the evidence that a stop chord did NOT cost a
    /// second `agtermctl tree --json`, and that a refused attempt asked once and gave up.
    public var requested: [String] { lock.withLock { seen } }

    public func setPane(_ pane: Pane) { lock.withLock { self.pane = pane } }

    public func setError(_ error: (any Error)?) { lock.withLock { self.error = error } }

    public func resolveTarget(sessionID: String) throws -> Target {
        let (pane, error) = lock.withLock { () -> (Pane, (any Error)?) in
            seen.append(sessionID)
            return (self.pane, self.error)
        }
        if let error { throw error }
        return Target(sessionID: sessionID, pane: pane)
    }

    /// What live focus answers. `focused` rather than a session id in `requested`, so a test can
    /// tell "the daemon resolved from focus" from "the daemon was handed a session" -- which is the
    /// difference between the hold trigger's path and a chord's.
    public var focusedSession = "focused-session"

    /// What the last focus resolution was told about D24's exception (D29).
    public private(set) var lastAllowedPicker: Bool?

    public func resolveFocusedTarget(allowingPicker: Bool) throws -> Target {
        lock.withLock { lastAllowedPicker = allowingPicker }
        let (session, pane, error) = lock.withLock { () -> (String, Pane, (any Error)?) in
            seen.append("<focus>")
            return (focusedSession, self.pane, self.error)
        }
        if let error { throw error }
        return Target(sessionID: session, pane: pane)
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

/// The record, in memory, with the same superseding rule the file has.
///
/// It keeps EVERY line it was handed, not one per attempt: "written before injection is attempted"
/// (invariant 10) is a claim about a line existing at a moment, and a fake that collapsed
/// on write would make it unobservable. `entries()` collapses, exactly as `FileHistory` does.
public final class FakeHistory: History, @unchecked Sendable {
    /// §7's "history append fails" row, which no real filesystem produces on request.
    public struct Unavailable: Error, CustomStringConvertible {
        public init() {}
        public var description: String { "the record is unavailable" }
    }

    private let lock = NSLock()
    private var log: [RecordEntry] = []
    private var error: (any Error)?

    public init() {}

    /// Every append, in order, superseded lines included.
    public var appended: [RecordEntry] { lock.withLock { log } }

    public func setError(_ error: (any Error)?) { lock.withLock { self.error = error } }

    public func append(_ entry: RecordEntry) throws {
        let error = lock.withLock { () -> (any Error)? in
            guard let error = self.error else {
                log.append(entry)
                return nil
            }
            return error
        }
        if let error { throw error }
    }

    public func entries() throws -> [RecordEntry] {
        if let error = lock.withLock({ self.error }) { throw error }
        return Record.collapse(appended)
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
    private var onNextRead: (@Sendable () -> Void)?

    public init(now: Date = Date(timeIntervalSince1970: 1_766_000_000)) {
        current = now
    }

    /// Runs `body` on the next reading of `now`, once, and then forgets it.
    ///
    /// A deterministic stand-in for a second thread arriving mid-`apply`. The daemon reads the
    /// clock while it is building a record entry and holding no lock, which is precisely the window
    /// a chord can land in -- and `advance` cannot express that, because the work it fires runs
    /// between applications rather than inside one.
    public func onceOnNextRead(_ body: @escaping @Sendable () -> Void) {
        lock.withLock { onNextRead = body }
    }

    public var now: Date {
        // Taken and cleared under the lock, then run OUTSIDE it: the body re-enters the daemon,
        // which schedules timers, which takes this same non-recursive lock.
        let hook = lock.withLock { () -> (@Sendable () -> Void)? in
            let hook = onNextRead
            onNextRead = nil
            return hook
        }
        hook?()
        return lock.withLock { current }
    }

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

// MARK: - push-to-talk (D5)

/// The modifier word, set by hand. The whole point of the `ModifierSource` seam: a gesture is a
/// physical act, and every rule about one would otherwise be scoreable only by a person with a
/// keyboard.
public final class FakeModifiers: ModifierSource, @unchecked Sendable {
    private let lock = NSLock()
    private var word: UInt64 = 0

    public init(flags: UInt64 = 0) { word = flags }

    public func flags() -> UInt64 { lock.withLock { word } }

    public func set(_ flags: UInt64) { lock.withLock { word = flags } }

    /// Holds one key down, leaving every other bit alone -- so a test can press `⌃C` with the left
    /// hand while the right Control key is up, which is the case F6 exists to make safe.
    public func press(_ key: HoldKey) { lock.withLock { word |= key.bit } }

    public func release(_ key: HoldKey) { lock.withLock { word &= ~key.bit } }
}

/// Which application the user is looking at (D22).
public final class FakeFrontmost: FrontmostApplication, @unchecked Sendable {
    private let lock = NSLock()
    private var identifier: String?

    public init(bundleIdentifier: String? = HoldTrigger.agtermBundleIdentifier) {
        identifier = bundleIdentifier
    }

    public var bundleIdentifier: String? { lock.withLock { identifier } }

    public func set(_ bundleIdentifier: String?) { lock.withLock { identifier = bundleIdentifier } }
}

/// The daemon, as far as the hold trigger can tell: every request it sent, and the answers it was
/// given. Answers are a queue rather than one canned value, because the interesting sequences are
/// exactly the ones where `start` and the command that ends it disagree.
public final class FakeDaemonDoor: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [Request] = []
    private var answers: [Response] = []
    private var error: (any Error)?
    private var nextAttempt: AttemptID = 1

    public init() {}

    public var requests: [Request] { lock.withLock { sent } }

    public var verbs: [Command] { requests.map(\.cmd) }

    public func setError(_ error: (any Error)?) { lock.withLock { self.error = error } }

    /// The next answer, ahead of the default. Consumed once.
    public func queue(_ response: Response) { lock.withLock { answers.append(response) } }

    public func send(_ request: Request) throws -> Response {
        try lock.withLock {
            sent.append(request)
            if let error { throw error }
            if !answers.isEmpty { return answers.removeFirst() }
            switch request.cmd {
            case .start:
                let id = nextAttempt
                nextAttempt += 1
                return Response(kind: .accepted, state: .warming, attempt: id)
            default:
                return Response(kind: .accepted, state: .idle, attempt: request.attempt)
            }
        }
    }
}
