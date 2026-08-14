import DictaCore
import DictaRuntime
import Foundation
import Testing

/// The seams and their fakes.
///
/// A test suite for test doubles looks like ceremony until one of them lies. Every assertion in the
/// tasks after this one is made THROUGH these fakes: if `FakeInjector` tidied the text it was
/// handed, invariant 2 would be asserted against a repair rather than the sanitiser, and the
/// suite would go green on a build that submits half-written prompts.
@Suite("seams")
struct SeamsTests {
    static let target = Target(sessionID: "S1", pane: .left)

    // MARK: - the canned transcript is hostile, and must stay that way

    @Test("the canned transcript carries every hazard the sanitiser exists to remove")
    func cannedTranscriptIsHostile() {
        let text = FakeTranscriber.hostileText

        #expect(text.contains("\n"), "no newline: a bypassed sanitiser would go unnoticed")
        #expect(text.contains("  "), "no double space")
        #expect(text.hasSuffix(" "), "no trailing space")
        #expect(text.hasPrefix(" "), "no leading space")
        // The newline is the dangerous one: `agtermctl session type` has no bracketed paste, so it
        // is a Return that SUBMITS whatever is in the input line (D8).
        #expect(!Sanitizer.isInjectable(text))
    }

    @Test("sanitising the canned transcript yields exactly one line of single spaces")
    func cannedTranscriptSanitizes() throws {
        let sanitized = Sanitizer.sanitize(FakeTranscriber.hostileText)

        #expect(sanitized == .line(FakeTranscriber.sanitizedHostileText))
        let line = try #require(sanitized.injectable)
        #expect(Sanitizer.isInjectable(line))
        #expect(!line.contains("  "))
    }

    @Test("the transcriber hands back what it was given, and records what it was asked")
    func transcriberRecordsAudio() throws {
        let transcriber = FakeTranscriber()
        let audio = Audio(samples: [0.5, -0.5], sampleRate: 16_000)

        #expect(try transcriber.transcribe(audio) == FakeTranscriber.hostileText)
        #expect(transcriber.transcribed == [audio])

        transcriber.setText("quiet")
        #expect(try transcriber.transcribe(audio) == "quiet")
    }

    @Test("the transcriber can fail on demand, for §7's recogniser row")
    func transcriberCanThrow() {
        let transcriber = FakeTranscriber()
        transcriber.setError(AgtermError.executableMissing("model"))

        #expect(throws: AgtermError.executableMissing("model")) {
            try transcriber.transcribe(Audio(samples: [], sampleRate: 16_000))
        }
    }

    // MARK: - the filter seam

    @Test("NoFilter is a pass-through, hazards and all")
    func noFilterPassesEverythingThrough() throws {
        // Not a tidier: v1 ships the seam EMPTY (D9c). If it trimmed anything, the sanitiser's
        // being last would stop being observable and step 4 would inherit a hidden second cleaner.
        let filter = NoFilter()
        for text in [FakeTranscriber.hostileText, "", "   ", "a\nb"] {
            #expect(try filter.filter(text) == text)
        }
    }

    // MARK: - capture

    @Test("capture reports readiness only when the test says so")
    func captureConfirmsOnDemand() {
        // The asymmetry D13 rests on: `begin` returns having announced nothing, and an attempt that
        // is never confirmed stays unannounced. A self-confirming fake would hide that.
        let capture = FakeCapture()
        let events = EventLog()
        capture.begin(attempt: 1) { events.append($0) }

        #expect(events.all.isEmpty)
        #expect(capture.callLog == [.begin(1)])
        #expect(capture.isOpen)

        capture.reportReady(1)
        #expect(events.all == [.ready(1)])
    }

    @Test("draining hands over the audio and closes the device")
    func captureDrains() {
        let audio = Audio(samples: [0.25], sampleRate: 16_000)
        let capture = FakeCapture(audio: audio)
        let events = EventLog()
        capture.begin(attempt: 1) { events.append($0) }
        capture.drain(attempt: 1)

        // §8.9: the drain is REQUESTED and not yet complete. An attempt that left `recording` here
        // would let the next chord race a second start over one input device.
        #expect(events.all.isEmpty)
        #expect(capture.isOpen)

        capture.reportDrained(1)
        #expect(events.all == [.drained(1, audio)])
        #expect(!capture.isOpen)
    }

    @Test("discarding closes the device and delivers nothing")
    func captureDiscards() {
        let capture = FakeCapture()
        let events = EventLog()
        capture.begin(attempt: 1) { events.append($0) }
        capture.discard(attempt: 1)

        #expect(capture.callLog == [.begin(1), .discard(1)])
        #expect(events.all.isEmpty)
        #expect(!capture.isOpen)
    }

    @Test("a fault still reaches the daemon after the attempt was discarded")
    func lateFaultIsStillDelivered() {
        // Deliberately delivered rather than swallowed here. "A late event must not resurrect an
        // abandoned attempt" is a rule about the state machine, and a fake that dropped the event
        // would test it against nothing.
        let capture = FakeCapture()
        let events = EventLog()
        capture.begin(attempt: 1) { events.append($0) }
        capture.discard(attempt: 1)
        capture.reportFault(1, reason: "the input device went away")

        #expect(events.all == [.fault(1, kind: .hardware, reason: "the input device went away")])
    }

    @Test("the fault kind travels with the fault, so the record can tell a cap from a device")
    func faultKindTravels() {
        // D15's cap and a dead device are the same event to the state machine and different rows in
        // §9. The kind is how the daemon tells them apart, so it has to survive the seam.
        let capture = FakeCapture()
        let events = EventLog()
        capture.begin(attempt: 7) { events.append($0) }
        capture.reportFault(7, kind: .durationCap, reason: FaultReason.durationCap)

        #expect(events.all
            == [.fault(7, kind: .durationCap, reason: FaultReason.durationCap)])
    }

    // MARK: - delivery

    @Test("the injector records exactly the string it was handed")
    func injectorRecordsVerbatim() throws {
        let injector = FakeInjector()
        try injector.inject("  two  spaces  ", into: Self.target)

        #expect(injector.delivered
            == [FakeInjector.Delivery(text: "  two  spaces  ", target: Self.target)])
        #expect(injector.lastText == "  two  spaces  ")
    }

    @Test("an armed failure still records what was handed over")
    func injectorRecordsEvenWhenItFails() {
        // "Nothing was typed" and "something may have been" are different rows of §7, and the
        // daemon can only tell them apart if the attempt is recorded either way.
        let injector = FakeInjector()
        injector.setFailure(.mayBePartial(Self.target, reason: "killed"))

        #expect(throws: DeliveryFailure.mayBePartial(Self.target, reason: "killed")) {
            try injector.inject("hello", into: Self.target)
        }
        #expect(injector.lastText == "hello")
    }

    @Test("only a half-finished injection maps to `partial`")
    func deliveryFailureMapping() {
        let gone = DeliveryFailure.targetGone(Self.target, reason: "gone")
        let notStarted = DeliveryFailure.notStarted(Self.target, reason: "refused")
        let partial = DeliveryFailure.mayBePartial(Self.target, reason: "killed")

        #expect(gone.injectionResult == .failed(reason: gone.description))
        #expect(notStarted.injectionResult == .failed(reason: notStarted.description))
        #expect(partial.injectionResult == .partial(reason: partial.description))
        #expect(partial.description.contains("may be partial"))
        #expect(gone.target == Self.target)
    }

    // MARK: - feedback

    @Test("the notifier keeps the order the user would have experienced")
    func notifierKeepsOrder() {
        let notifier = FakeNotifier()
        notifier.announce(.listening, for: Self.target)
        notifier.notify("the target is gone", for: Self.target)
        notifier.announce(.blocked, for: Self.target)
        notifier.clearIndicator(for: Self.target)

        #expect(notifier.signals == [
            .announce(.listening, Self.target),
            .notify("the target is gone", Self.target),
            .announce(.blocked, Self.target),
            .clear(Self.target),
        ])
        #expect(notifier.announcements == [.listening, .blocked])
        #expect(notifier.messages == ["the target is gone"])
    }

    // MARK: - time

    @Test("scheduled work fires when the clock passes its deadline, and not before")
    func clockFiresOnTime() {
        let clock = FakeClock()
        let fired = Counter()
        clock.schedule(after: 600) { fired.increment() }

        clock.advance(by: 599)
        #expect(fired.value == 0)
        #expect(clock.scheduledCount == 1)

        clock.advance(by: 1)
        #expect(fired.value == 1)
        #expect(clock.scheduledCount == 0)

        // Once, not once per tick: the duration cap must not fire ten times while the daemon is
        // finishing the attempt it already ended (D15).
        clock.advance(by: 3_600)
        #expect(fired.value == 1)
    }

    @Test("cancelled work never fires")
    func clockCancellation() {
        // What disarming a watchdog looks like: an attempt that finished must not be faulted by the
        // timer that was watching it.
        let clock = FakeClock()
        let fired = Counter()
        let work = clock.schedule(after: 5) { fired.increment() }
        work.cancel()

        clock.advance(by: 60)
        #expect(fired.value == 0)
    }

    @Test("work due at the same instant fires in the order it was scheduled")
    func clockOrdering() {
        let clock = FakeClock()
        let order = Recorder()
        clock.schedule(after: 10) { order.append("watchdog") }
        clock.schedule(after: 5) { order.append("cap") }
        clock.schedule(after: 5) { order.append("second cap") }

        clock.advance(by: 10)
        #expect(order.all == ["cap", "second cap", "watchdog"])
    }

    @Test("the clock's now moves with it")
    func clockNowMoves() {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 100))
        clock.advance(by: 30)
        #expect(clock.now == Date(timeIntervalSince1970: 130))
    }

    @Test("the real clock fires, and a cancelled one does not")
    func systemClockFires() {
        // Short deadlines, because this is the one test that genuinely waits: the property is that
        // `SystemClock` is not a no-op, which no fake can establish.
        let clock = SystemClock()
        let fired = DispatchSemaphore(value: 0)
        clock.schedule(after: 0.05) { fired.signal() }
        #expect(fired.wait(timeout: .now() + 2) == .success)

        let cancelledFired = Counter()
        let work = clock.schedule(after: 0.05) { cancelledFired.increment() }
        work.cancel()
        Thread.sleep(forTimeInterval: 0.2)
        #expect(cancelledFired.value == 0)
    }

    // MARK: - small thread-safe collectors

    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [CaptureEvent] = []

        func append(_ event: CaptureEvent) { lock.withLock { events.append(event) } }
        var all: [CaptureEvent] { lock.withLock { events } }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []

        func append(_ item: String) { lock.withLock { items.append(item) } }
        var all: [String] { lock.withLock { items } }
    }
}
