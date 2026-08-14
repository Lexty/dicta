import DictaCore
import DictaIPC
import DictaRuntime
import Foundation
import Testing

/// The daemon, driven through the seams -- step 1 end to end with no microphone, no model and no
/// terminal.
///
/// Two things separate these tests from `StateMachineTests`, which already covers every cell of
/// §6's table. First, ORDER: the machine's transitions are checked one at a time, and D13's rule is
/// where `.announce(.listening)` sits relative to capture confirming, which only a whole attempt
/// shows. Second, the TEXT: the machine carries no strings at all, so "what was injected is exactly
/// the sanitised text, with no line break" (§8.1, §8.2) can only be asserted here, against the
/// deliberately hostile canned transcript.
@Suite("daemon")
struct DaemonTests {
    // MARK: - harness

    /// A filter that can be armed to fail, and that counts. The count is the assertion for raw
    /// mode: "raw skips the filtered stage and nothing else" (§2, D3) is a claim about a call that
    /// must NOT happen, and `NoFilter` being a pass-through would hide it.
    final class CountingFilter: Filter, @unchecked Sendable {
        struct Failure: Error, CustomStringConvertible {
            var description: String { "the filter fell over" }
        }

        private let lock = NSLock()
        private var seen: [String] = []
        private var error: (any Error)?

        var calls: [String] { lock.withLock { seen } }

        func setError(_ error: (any Error)?) { lock.withLock { self.error = error } }

        func filter(_ text: String) throws -> String {
            let error = lock.withLock { () -> (any Error)? in
                seen.append(text)
                return self.error
            }
            if let error { throw error }
            return text
        }
    }

    /// A pass-through filter that runs the test's own code from inside `processing`.
    ///
    /// The only way to observe a rule about a state that lasts one synchronous call: the duration
    /// cap coming due while the recogniser's text exists and the attempt has not ended (D15).
    final class HookedFilter: Filter, @unchecked Sendable {
        private let lock = NSLock()
        private var hook: (@Sendable () -> Void)?

        func setHook(_ hook: @escaping @Sendable () -> Void) { lock.withLock { self.hook = hook } }

        func filter(_ text: String) throws -> String {
            lock.withLock { hook }?()
            return text
        }
    }

    /// The Tier 0 dictionary the daemon will read, behind a counter.
    ///
    /// A box rather than a value because the daemon reads it PER ATTEMPT (D9a's workflow: edit a
    /// rule, dictate once, read the record). Both halves of that are assertions -- that the read
    /// happens again, and that the second read is what fires -- and neither is observable through a
    /// dictionary handed over once at construction.
    final class DictionaryBox: @unchecked Sendable {
        private let lock = NSLock()
        private var book = ReplacementDictionary.none
        private var reads = 0

        var readCount: Int { lock.withLock { reads } }

        func set(_ book: ReplacementDictionary) { lock.withLock { self.book = book } }

        func set(_ source: String, version: String? = "test") {
            set(Replacements.parse(source, version: version))
        }

        func read() -> ReplacementDictionary {
            lock.withLock {
                reads += 1
                return book
            }
        }
    }

    /// Everything a daemon needs, in a temporary directory, with every seam faked.
    final class Harness {
        let directory: URL
        let capture = FakeCapture()
        let transcriber = FakeTranscriber()
        let filter = CountingFilter()
        let injector = FakeInjector()
        let notifier = FakeNotifier()
        let resolver = FakeTargetResolver()
        let clock = FakeClock()
        /// In memory, never the user's real record: a test that appended to `Paths.current.record`
        /// would corrupt the file holding every word they have dictated.
        let history = FakeHistory()
        /// Empty unless a test fills it, so every other test's text is the transcriber's own.
        let dictionary: DictionaryBox
        let daemon: Daemon

        /// `injecting` and `processing` each last exactly as long as one synchronous seam call, so
        /// a test about either substitutes that seam with one that runs its own code from inside.
        init(pane: Pane = .left,
             warmupTimeout: TimeInterval = 5,
             drainTimeout: TimeInterval = 10,
             durationCap: TimeInterval = 600,
             transcriber: (any Transcriber)? = nil,
             filter: (any Filter)? = nil,
             injector: (any Injector)? = nil,
             history: (any History)? = nil) {
            // `/tmp` rather than the per-user temp directory, for the reason `ControlSocketTests`
            // gives: `sun_path` is 104 bytes and $TMPDIR plus a UUID is most of that budget.
            directory = URL(fileURLWithPath: "/tmp")
                .appendingPathComponent("dicta-daemon-\(UUID().uuidString.prefix(8))",
                                        isDirectory: true)
            try? FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
            resolver.setPane(pane)
            // A local binding, captured by the provider: `self` is not available to a closure here
            // until every stored property is initialised, and `daemon` is one of them.
            let book = DictionaryBox()
            dictionary = book
            daemon = Daemon(
                configuration: Daemon.Configuration(
                    socketPath: directory.appendingPathComponent("c.sock").path,
                    activeTargetFile: directory.appendingPathComponent("active-target.json"),
                    warmupTimeout: warmupTimeout,
                    drainTimeout: drainTimeout,
                    durationCap: durationCap
                ),
                capture: capture,
                transcriber: transcriber ?? self.transcriber,
                filter: filter ?? self.filter,
                history: history ?? self.history,
                clock: clock,
                dictionary: { book.read() },
                resolver: resolver,
                injector: injector ?? self.injector,
                notifier: notifier
            )
        }

        deinit {
            daemon.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        var activeTargetFile: URL { daemon.configuration.activeTargetFile }

        @discardableResult
        func send(_ request: Request) -> Response {
            daemon.handle(.request(request))
        }

        /// A chord: the toggle verb and nothing else (D5, D7).
        @discardableResult
        func chord(_ mode: Mode = .clean, session: String = "S1") -> Response {
            send(Request(cmd: .toggle, sessionID: session, mode: mode))
        }

        /// Drives an attempt to `recording`, the way a chord plus a working microphone would.
        @discardableResult
        func startRecording(_ mode: Mode = .clean) -> AttemptID {
            let response = chord(mode)
            let id = response.attempt ?? 0
            capture.reportReady(id)
            return id
        }

        /// The whole clean path: chord, ready, chord, drained.
        @discardableResult
        func dictate(_ mode: Mode = .clean) -> AttemptID {
            let id = startRecording(mode)
            chord(mode)
            capture.reportDrained(id)
            return id
        }
    }

    static let target = Target(sessionID: "S1", pane: .left)

    // MARK: - step 1, end to end

    @Test("the clean path delivers exactly the sanitised canned transcript")
    func cleanPathEndToEnd() throws {
        let harness = Harness()

        let id = harness.dictate()

        #expect(harness.daemon.state == .idle)
        // §8.1 and §8.2, against the transcript that carries a newline, a double space and a
        // trailing space. If the sanitiser were bypassed, `session type` would have submitted this.
        #expect(harness.injector.delivered == [
            FakeInjector.Delivery(text: FakeTranscriber.sanitizedHostileText, target: Self.target),
        ])
        #expect(Sanitizer.isInjectable(try #require(harness.injector.lastText)))
        #expect(harness.notifier.announcements == [.listening, .working, .done])
        #expect(harness.notifier.messages.isEmpty)
        #expect(id == 1)
    }

    @Test("raw mode skips the filter and nothing else")
    func rawPathSkipsOnlyTheFilter() throws {
        let harness = Harness()

        harness.dictate(.raw)

        // Not "unsanitised" and not "unreplaced" -- both of those readings are wrong (§2, D3).
        #expect(harness.injector.lastText == FakeTranscriber.sanitizedHostileText)
        #expect(harness.filter.calls.isEmpty)
        #expect(harness.notifier.announcements == [.listening, .working, .done])
    }

    @Test("clean mode runs the filter, on the replaced text")
    func cleanPathRunsTheFilter() {
        let harness = Harness()

        harness.dictate(.clean)

        // Before the sanitiser (§2): what the filter sees still carries the hazards, which is why
        // the sanitiser cannot move earlier.
        #expect(harness.filter.calls == [FakeTranscriber.hostileText])
    }

    // MARK: - D13: nothing is announced before capture confirms

    @Test("the start chord announces nothing at all until capture confirms")
    func nothingIsAnnouncedBeforeCaptureConfirms() {
        let harness = Harness()

        let response = harness.chord()

        // The ordering IS the rule (D13, invariant 4). Announcing here would train the user to
        // speak before audio flows and lose the first syllable of every dictation.
        #expect(response.kind == .accepted)
        #expect(response.state == .warming)
        #expect(harness.notifier.signals.isEmpty)
        #expect(harness.capture.callLog == [.begin(1)])

        harness.capture.reportReady(1)
        #expect(harness.notifier.signals == [.announce(.listening, Self.target)])
    }

    @Test("a warming attempt that is never confirmed announces nothing, ever")
    func warmingNeverConfirmedAnnouncesNothing() {
        let harness = Harness()
        harness.chord()

        harness.send(Request(cmd: .status))

        #expect(harness.daemon.state == .warming)
        #expect(harness.notifier.signals.isEmpty)
    }

    // MARK: - §6's table, at the daemon level

    @Test("a second start chord while recording is refused, and opens no second device")
    func duplicateStartIsRefused() {
        let harness = Harness()
        let id = harness.startRecording()

        // `start`, not `toggle` -- a toggle here would legitimately mean "stop" (D7).
        let response = harness.send(Request(cmd: .start, sessionID: "S1"))

        #expect(response.kind == .rejected)
        #expect(response.message == "already recording")
        #expect(harness.capture.callLog == [.begin(id)])
        // Audible (§6): a refused chord the user cannot hear is a keypress that appears to have
        // worked.
        #expect(harness.notifier.announcements == [.listening, .blocked])
        #expect(harness.notifier.messages == ["already recording"])
    }

    @Test("a start chord while the first attempt is still draining is refused, not queued")
    func startWhileDrainingIsRefused() {
        // §8.9: the first attempt still owns the input device. With a real engine, queueing here is
        // two starts racing over one microphone.
        let harness = Harness()
        let id = harness.startRecording()
        harness.chord()

        let response = harness.send(Request(cmd: .start, sessionID: "S1"))

        #expect(response.kind == .rejected)
        #expect(response.state == .recording)
        #expect(harness.capture.callLog == [.begin(id), .drain(id)])
    }

    @Test("a duplicated stop is silent and never delivers twice")
    func duplicateStopDeliversOnce() {
        let harness = Harness()
        let id = harness.startRecording()
        harness.chord()

        let second = harness.chord()

        // Quiet, deliberately (§6): pressing stop again because nothing visibly happened is normal
        // behaviour, and an alarming noise would punish it.
        #expect(second.kind == .noop)
        #expect(harness.notifier.messages.isEmpty)
        #expect(harness.capture.callLog == [.begin(id), .drain(id)])

        harness.capture.reportDrained(id)
        // Invariant 5.
        #expect(harness.injector.delivered.count == 1)
    }

    @Test("a stop naming a spent attempt is a silent no-op")
    func spentAttemptIsANoop() {
        let harness = Harness()
        harness.dictate()

        let response = harness.send(Request(cmd: .stop, mode: .clean, attempt: 1))

        #expect(response.kind == .noop)
        #expect(harness.injector.delivered.count == 1)
    }

    // MARK: - abort, in every state

    @Test("abort while warming cancels with nothing delivered")
    func abortWhileWarming() {
        let harness = Harness()
        harness.chord()

        let response = harness.send(Request(cmd: .abort))

        #expect(response.kind == .accepted)
        #expect(response.state == .idle)
        #expect(harness.capture.callLog == [.begin(1), .discard(1)])
        #expect(!harness.capture.isOpen)
        #expect(harness.injector.delivered.isEmpty)
        #expect(harness.notifier.announcements == [.blocked])
        #expect(harness.notifier.messages == ["aborted"])
    }

    @Test("abort while recording discards the audio and injects nothing")
    func abortWhileRecording() {
        let harness = Harness()
        let id = harness.startRecording()

        harness.send(Request(cmd: .abort))

        #expect(harness.capture.callLog == [.begin(id), .discard(id)])
        #expect(harness.transcriber.transcribed.isEmpty)
        #expect(harness.injector.delivered.isEmpty)
    }

    @Test("abort while draining discards the audio and injects nothing")
    func abortWhileDraining() {
        let harness = Harness()
        let id = harness.startRecording()
        harness.chord()

        harness.send(Request(cmd: .abort))

        #expect(harness.daemon.state == .idle)
        #expect(harness.capture.callLog == [.begin(id), .drain(id), .discard(id)])
        #expect(harness.injector.delivered.isEmpty)
    }

    @Test("abort while processing cancels and injects nothing")
    func abortWhileProcessing() throws {
        // `processing` lasts exactly as long as the recogniser runs, so the abort arrives from
        // inside the transcriber -- which is also how it would arrive in life, on another thread
        // while a real Parakeet inference is in flight.
        let seen = Locked<Response?>(nil)
        let harness = Locked<Harness?>(nil)
        let transcriber = ReentrantTranscriber {
            seen.set(harness.value?.send(Request(cmd: .abort)))
        }
        let fixture = Harness(transcriber: transcriber)
        harness.set(fixture)
        // The box holds the harness, the harness holds the seam, the seam's closure holds the box:
        // a retain cycle, so `Harness.deinit` never runs and the temp directory is never removed.
        // Measured before this line existed: `/tmp/dicta-daemon-*` grew by one per run, forever.
        defer { harness.set(nil) }

        let id = fixture.dictate()

        let response = try #require(seen.value)
        #expect(response.kind == .accepted)
        #expect(response.state == .idle)
        #expect(response.message == "aborted")
        // Capture is already over, so there is only the text to drop -- and nothing is injected.
        #expect(fixture.injector.delivered.isEmpty)
        #expect(fixture.capture.callLog == [.begin(id), .drain(id)])
        #expect(fixture.notifier.announcements == [.listening, .working, .blocked])
    }

    @Test("abort during injection is refused, because keystrokes cannot be recalled")
    func abortWhileInjectingIsRefused() throws {
        // D20. `injecting` lasts exactly as long as `Injector.inject`, so the abort arrives from
        // inside it -- the only moment at which the refusal is the answer.
        let seen = Locked<Response?>(nil)
        let harness = Locked<Harness?>(nil)
        let injector = ReentrantInjector { seen.set(harness.value?.send(Request(cmd: .abort))) }
        let fixture = Harness(injector: injector)
        harness.set(fixture)
        defer { harness.set(nil) } // breaks the box → harness → seam → box cycle; see above

        fixture.dictate()

        let response = try #require(seen.value)
        #expect(response.kind == .rejected)
        #expect(response.state == .injecting)
        #expect(response.message?.contains("keystrokes cannot be recalled") == true)
        // Refused, and the keystrokes went in anyway: that is the whole point of refusing.
        #expect(injector.delivered == [FakeTranscriber.sanitizedHostileText])
    }

    // MARK: - delivery failures (§7)

    @Test("a target gone at injection time is reported and never re-aimed", arguments: [
        DeliveryFailure.targetGone(Target(sessionID: "S1", pane: .left), reason: "the pane went"),
        DeliveryFailure.notStarted(Target(sessionID: "S1", pane: .left), reason: "agterm refused"),
        DeliveryFailure.mayBePartial(Target(sessionID: "S1", pane: .left), reason: "killed"),
    ])
    func deliveryFailuresAreReportedOnce(failure: DeliveryFailure) throws {
        let harness = Harness()
        harness.injector.setFailure(failure)

        harness.dictate()

        // Never retried (§7): a retry after keystrokes have begun would double part of the text.
        #expect(harness.injector.delivered.count == 1)
        // Whatever the failure, what was handed over was **final** -- one line, single spaces.
        #expect(harness.injector.lastText == FakeTranscriber.sanitizedHostileText)
        #expect(harness.notifier.announcements == [.listening, .working, .blocked])
        let message = try #require(harness.notifier.messages.first)
        #expect(message == failure.description)
        #expect(message.contains("the text is in the record"))
        #expect(harness.daemon.state == .idle)
    }

    @Test("a failure after keystrokes have begun says the insertion may be partial")
    func partialInjectionIsWordedAsPartial() throws {
        let harness = Harness()
        harness.injector.setFailure(.mayBePartial(Self.target, reason: "agtermctl was killed"))

        harness.dictate()

        let message = try #require(harness.notifier.messages.first)
        #expect(message.contains("may be partial"))
        // The one thing it must NOT claim: that the input line is untouched.
        #expect(!message.contains("nothing was inserted"))
    }

    @Test("a failure before the first keystroke says nothing was inserted")
    func failureBeforeKeystrokesIsWordedAsNothing() throws {
        let harness = Harness()
        harness.injector.setFailure(.notStarted(Self.target, reason: "agterm refused the command"))

        harness.dictate()

        let message = try #require(harness.notifier.messages.first)
        #expect(message.contains("nothing was inserted"))
        #expect(!message.contains("may be partial"))
    }

    // MARK: - processing failures (§7)

    @Test("nothing recognised means no injection and a visible reason")
    func emptyRecognitionDoesNotInject() {
        let harness = Harness()
        harness.transcriber.setText("   \n  ")

        harness.dictate()

        // An empty insertion is worse than none (§7).
        #expect(harness.injector.delivered.isEmpty)
        #expect(harness.notifier.announcements == [.listening, .working, .blocked])
        #expect(harness.notifier.messages == ["nothing was recognised"])
    }

    @Test("a recogniser that throws injects nothing and says so")
    func recogniserFailureDoesNotInject() throws {
        let harness = Harness()
        harness.transcriber.setError(AgtermError.executableMissing("the model"))

        harness.dictate()

        #expect(harness.injector.delivered.isEmpty)
        #expect(harness.notifier.announcements == [.listening, .working, .blocked])
        let message = try #require(harness.notifier.messages.first)
        #expect(message.contains("the recogniser failed"))
        // §7 wants the attempt recorded with its error and no text. The entry is the only reason to
        // care: an attempt that produced nothing and left nothing behind is indistinguishable from
        // one that never happened, which is property 2 failing quietly.
        let entry = try #require(harness.history.appended.last)
        #expect(entry.outcome == .recognitionFailed)
        #expect(entry.recognised.isEmpty)
        #expect(entry.final.isEmpty)
        #expect(entry.error?.contains("the recogniser failed") == true)
    }

    @Test("recognised text over the frame limit is refused, and the record keeps the byte length")
    func oversizedRecognitionDoesNotInject() throws {
        let harness = Harness()
        // Two bytes per character, so this is twice the frame limit in bytes and well under it
        // in characters -- the shape a `count`-based check would wave through.
        let huge = String(repeating: "\u{044F}", count: Wire.maxFrameBytes)
        harness.transcriber.setText(huge)

        harness.dictate()

        // §7's third recogniser row. Injecting would be 128 KB of keystrokes into an input line;
        // and the text could not be read back out through the socket either, so storing it would
        // put a promise in the record that `dictactl last` cannot keep.
        #expect(harness.injector.delivered.isEmpty)
        #expect(harness.notifier.announcements == [.listening, .working, .blocked])
        let entry = try #require(harness.history.appended.last)
        #expect(entry.outcome == .recognitionFailed)
        #expect(entry.recognised.isEmpty)
        // The byte length is what §7 asks to be recorded, and it is the number that separates a
        // runaway decode from a broken model.
        #expect(entry.error?.contains("\(huge.utf8.count) bytes") == true)
    }

    @Test("an attempt that recognised nothing but whitespace is recorded as empty, with no text")
    func emptyRecognitionIsRecordedAsEmpty() throws {
        let harness = Harness()
        harness.transcriber.setText("   \n \t ")

        harness.dictate()

        let entry = try #require(harness.history.appended.last)
        // `empty` rather than `recognition-failed`: the recogniser worked and the room was quiet,
        // and a record that confused the two would send the user to look at their model.
        #expect(entry.outcome == .empty)
        #expect(entry.final.isEmpty)
        // `recognised` still holds what came back, whitespace and all. It is the only evidence that
        // distinguishes "nothing was said" from "the model emitted junk that sanitised to nothing".
        #expect(entry.recognised == "   \n \t ")
    }

    @Test("the daemon drives a real ParakeetTranscriber without loading a model per attempt")
    func theAttemptPathNeverLoadsAModel() throws {
        // The composition, rather than the transcriber in isolation (which `TranscriberTests`
        // covers): this is the wiring `Sources/Dicta/main.swift` performs, with only FluidAudio
        // replaced.
        let engine = TranscriberTests.CountingEngine(text: "spoken  text\n")
        let transcriber = ParakeetTranscriber(engine: engine)
        try transcriber.prepare()
        let harness = Harness(transcriber: transcriber)

        harness.dictate()
        harness.dictate()

        // Two dictations, one load -- D10's normative half, asserted through the daemon.
        #expect(engine.loadCount == 1)
        // And the sanitiser still runs on the real transcriber's path (invariant 1): the seam being
        // swapped is not a seam that gets to skip it.
        #expect(harness.injector.delivered.map(\.text) == ["spoken text", "spoken text"])
    }

    @Test("a failing filter falls back to replaced rather than costing the user their words")
    func filterFailureFallsBackToReplaced() throws {
        let harness = Harness()
        harness.filter.setError(CountingFilter.Failure())

        harness.dictate(.clean)

        // §7: inject **replaced** instead, and notify that the filter did not run. The sanitiser
        // still runs on it -- the fallback path is inside invariant 1, not around it.
        #expect(harness.injector.lastText == FakeTranscriber.sanitizedHostileText)
        #expect(harness.notifier.announcements == [.listening, .working, .done])
        let message = try #require(harness.notifier.messages.first)
        #expect(message.contains("the filter did not run"))
    }

    // MARK: - the Tier 0 dictionary (D9a, §2, §7)

    /// The transcript with one word rewritten, as the **replaced** stage would leave it: still
    /// carrying the newline, the double space and the trailing space, because the sanitiser has not
    /// run yet. Kept beside the rule so a test asserts against a value rather than against its own
    /// copy of the algorithm.
    static let replacedHostileText = " dicta hears you\nfrom the  real transcriber "
    static let sanitizedReplacedText = "dicta hears you from the real transcriber"
    /// One rule, over a word the canned transcript actually contains.
    static let oneRule = "honesty | fake | real"

    @Test("the dictionary runs before the filter and before the sanitiser")
    func replacementRunsBeforeTheFilterAndTheSanitiser() {
        let harness = Harness()
        harness.dictionary.set(Self.oneRule)

        harness.dictate(.clean)

        // What the filter was handed is the proof of the ordering (§2): it is the replaced text,
        // and it still carries every hazard, which is why the sanitiser cannot move earlier.
        #expect(harness.filter.calls == [Self.replacedHostileText])
        #expect(harness.injector.lastText == Self.sanitizedReplacedText)
    }

    @Test("the dictionary applies in raw mode too, which skips only the filter")
    func replacementAppliesInRawMode() {
        // §2's table: **replaced** is applied in raw mode; only **filtered** is not (D3). Reading
        // raw as "unreplaced" is one of the two wrong readings the spec names.
        let harness = Harness()
        harness.dictionary.set(Self.oneRule)

        harness.dictate(.raw)

        #expect(harness.injector.lastText == Self.sanitizedReplacedText)
        #expect(harness.filter.calls.isEmpty)
    }

    @Test("the record names the rules that fired and the dictionary they came from")
    func recordCarriesTheRules() throws {
        let harness = Harness()
        harness.dictionary.set("""
        honesty | fake | real
        unused | nothing here | x
        """, version: "2026-08-14T10:00:00Z")

        harness.dictate()

        let entry = try #require(harness.history.appended.last)
        #expect(entry.outcome == .injected)
        #expect(entry.rules == RulesApplied(fired: ["honesty"], version: "2026-08-14T10:00:00Z"))
        // §9's whole point: `recognised` is verbatim and `final` is what was typed, so the pair
        // plus `rules` names a misfiring rule without re-running anything.
        #expect(entry.recognised == FakeTranscriber.hostileText)
        #expect(entry.final == Self.sanitizedReplacedText)
    }

    @Test("the dictionary is read once per attempt, so an edited rule fires on the next one")
    func dictionaryIsReadPerAttempt() {
        // The workflow step 3 is scored on. A dictionary read once at start-up would answer a
        // second dictation with the file as it was at login.
        let harness = Harness()

        harness.dictate()
        #expect(harness.injector.lastText == FakeTranscriber.sanitizedHostileText)

        harness.dictionary.set(Self.oneRule)
        harness.dictate()

        #expect(harness.dictionary.readCount == 2)
        #expect(harness.injector.lastText == Self.sanitizedReplacedText)
    }

    @Test("a malformed rule is skipped, the rest apply, and the text still arrives")
    func degradedDictionaryStillDelivers() throws {
        let harness = Harness()
        harness.dictionary.set("""
        honesty | fake | real
        this line is nonsense
        """)

        harness.dictate()

        // §7: never block an injection over a config file. The surviving rule fired.
        #expect(harness.injector.lastText == Self.sanitizedReplacedText)
        let entry = try #require(harness.history.appended.last)
        #expect(entry.outcome == .dictionaryDegraded)
        #expect(entry.rules.fired == ["honesty"])
        #expect(entry.error?.contains("line 2") == true)
        // Told, and told once, however many rules are broken -- and never as a blocked attempt,
        // because the attempt was not blocked.
        #expect(harness.notifier.messages.count == 1)
        #expect(harness.notifier.announcements == [.listening, .working, .done])
    }

    @Test("a dictionary with several broken rules is still reported exactly once")
    func degradationIsReportedOnce() {
        let harness = Harness()
        harness.dictionary.set("""
        nonsense one
        nonsense two
        nonsense three
        """)

        harness.dictate()

        #expect(harness.notifier.messages.count == 1)
        #expect(harness.injector.lastText == FakeTranscriber.sanitizedHostileText)
    }

    @Test("a filter fallback supersedes a dictionary degradation, and both reasons survive")
    func filterFallbackSupersedesDegradation() throws {
        let harness = Harness()
        harness.dictionary.set("nonsense")
        harness.filter.setError(CountingFilter.Failure())

        harness.dictate()

        let entry = try #require(harness.history.appended.last)
        // §9's `outcome` is one field: a whole stage not running is the larger fact. Nothing is
        // lost, because `error` joins every reason the user was shown.
        #expect(entry.outcome == .filterFellBack)
        #expect(entry.error?.contains("dictionary") == true)
        #expect(entry.error?.contains("filter") == true)
        #expect(harness.injector.lastText == FakeTranscriber.sanitizedHostileText)
    }

    @Test("a rule that empties the text injects nothing and says the dictionary did it")
    func replacementEmptyingTheTextIsNotSilent() throws {
        let harness = Harness()
        harness.transcriber.setText("erm")
        harness.dictionary.set("filler | erm |")

        harness.dictate()

        // §7: treat as empty -- and the dictionary must not silently delete a dictation. "Nothing
        // was recognised" would be a lie that sends the user to their microphone.
        #expect(harness.injector.delivered.isEmpty)
        #expect(harness.notifier.announcements == [.listening, .working, .blocked])
        let message = try #require(harness.notifier.messages.last)
        #expect(message.contains("replacement dictionary"))
        #expect(message.contains("filler"), "the message must name the rule that fired: \(message)")
        let entry = try #require(harness.history.appended.last)
        #expect(entry.outcome == .empty)
        #expect(entry.recognised == "erm")
        #expect(entry.final.isEmpty)
        #expect(entry.rules.fired == ["filler"])
    }

    @Test("an injector that fails in its own way is still recorded as a delivery that failed")
    func anUnexpectedInjectorErrorIsRecordedAsAFailedDelivery() throws {
        // The generic `catch` in `deliver`. `Injector` permits any `Error`, so this branch is the
        // one a future injector lands in, and getting its outcome wrong would mis-record which side
        // of "nothing was typed" versus "something may have been" the attempt fell on -- the
        // distinction §9's outcome exists to preserve.
        let harness = Harness(injector: ExplodingInjector())

        harness.dictate()

        let entry = try #require(harness.history.appended.last)
        #expect(entry.outcome == .injectionFailed)
        #expect(entry.error?.contains("came apart") == true,
                "the reason must reach the record: \(entry.error ?? "nothing")")
        // Invariant 10: the text is on disk regardless, which is the only route by which it
        // survives a delivery that failed.
        #expect(entry.final == FakeTranscriber.sanitizedHostileText)
        #expect(harness.daemon.state == .idle)
        // And the user is told, rather than left to discover an empty input line.
        #expect(harness.notifier.messages.contains { $0.contains("came apart") })
    }

    @Test("a chord names the agterm it fired in, and the daemon re-aims at that instance")
    func theAgtermSocketReachesTheTerminalProvider() throws {
        // D4 at instance granularity. `$AGT_SOCKET` travels on the frame (F3) precisely so a second
        // agterm's panes are resolved against -- and typed into -- that agterm. Every other daemon
        // test uses the fixed-terminal convenience init, so this hop was the one part of the wiring
        // nothing exercised: dropping `adoptTerminal` would have left the suite entirely green.
        let asked = Locked<[String?]>([])
        let resolver = FakeTargetResolver()
        resolver.setPane(.left)
        let injector = FakeInjector()
        let daemon = Daemon(
            configuration: Daemon.Configuration(
                socketPath: "/tmp/unused-\(UUID().uuidString).sock"),
            capture: FakeCapture(),
            transcriber: FakeTranscriber(),
            history: FakeHistory(),
            clock: FakeClock(),
            terminal: { socket in
                asked.set(asked.value + [socket])
                return Daemon.Terminal(resolver: resolver, injector: injector,
                                       notifier: FakeNotifier())
            }
        )

        // Construction asks once, for the default instance.
        #expect(asked.value == [nil])

        _ = daemon.handle(.request(Request(cmd: .toggle, sessionID: "S1",
                                           agtermSocket: "/tmp/a2.sock")))
        #expect(asked.value == [nil, "/tmp/a2.sock"])

        // A later chord naming a different instance re-adopts rather than keeping the first.
        _ = daemon.handle(.request(Request(cmd: .abort)))
        _ = daemon.handle(.request(Request(cmd: .toggle, sessionID: "S1",
                                           agtermSocket: "/tmp/a3.sock")))
        #expect(asked.value == [nil, "/tmp/a2.sock", "/tmp/a3.sock"])
    }

    @Test("a degraded dictionary is reported even when the attempt ends with no text")
    func degradedDictionaryIsReportedOnTheEmptyBranchToo() throws {
        // §7 wants the degradation notified once per attempt. It used to be told only on the branch
        // where text survived, so a user who had just broken `replacements.conf` and then dictated
        // into silence heard nothing about the file -- at the exact moment the sentence is most
        // useful, because the broken file is the thing they just touched.
        let harness = Harness()
        harness.transcriber.setText("   ")
        harness.dictionary.set("this line is not a rule at all")

        harness.dictate()

        let entry = try #require(harness.history.appended.last)
        #expect(entry.outcome == .empty)
        // Both sentences reach the user: what happened to the dictation, and what is wrong with the
        // file. The dictation's own report comes first -- a complaint about a config file arriving
        // ahead of it would read as the reason nothing was typed.
        #expect(harness.notifier.messages.count == 2)
        #expect(harness.notifier.messages.first == "nothing was recognised")
        let degraded = try #require(harness.notifier.messages.last)
        #expect(degraded.contains("line 1"), "the reason must name the line: \(degraded)")
    }

    @Test("silence is still reported as silence, not blamed on the dictionary")
    func silenceIsStillSilence() throws {
        let harness = Harness()
        harness.transcriber.setText("   ")
        harness.dictionary.set(Self.oneRule)

        harness.dictate()

        #expect(harness.notifier.messages == ["nothing was recognised"])
        let entry = try #require(harness.history.appended.last)
        #expect(entry.outcome == .empty)
    }

    @Test("an aborted attempt is not told about its dictionary")
    func cancelledAttemptSaysNothingAboutTheDictionary() {
        // The report follows the delivery, not the recognition: an attempt the user has already
        // cancelled does not need a lecture about a config file.
        let hooked = HookedFilter()
        let harness = Harness(filter: hooked)
        harness.dictionary.set("nonsense")
        let id = harness.startRecording()
        harness.chord()
        // The daemon, not the harness: `Daemon` is `Sendable` and the harness deliberately is not.
        let daemon = harness.daemon
        hooked.setHook {
            _ = daemon.handle(.request(Request(cmd: .abort)))
        }

        harness.capture.reportDrained(id)

        #expect(harness.injector.delivered.isEmpty)
        #expect(!harness.notifier.messages.contains { $0.contains("dictionary") })
    }

    // MARK: - target resolution (D6, §5)

    @Test("an unresolvable pane does not start the attempt", arguments: [
        AgtermError.noActivePane(session: "S1"),
        AgtermError.ambiguousPane(session: "S1", panes: ["left", "right"]),
        AgtermError.executableMissing("/opt/homebrew/bin/agtermctl"),
        AgtermError.sessionNotFound("S1"),
    ])
    func unresolvableTargetDoesNotStart(error: AgtermError) throws {
        let harness = Harness()
        harness.resolver.setError(error)

        let response = harness.chord()

        // Fail closed (D6): the alternative is somebody else's agent receiving the prompt.
        #expect(response.kind == .rejected)
        #expect(response.state == .idle)
        #expect(harness.capture.callLog.isEmpty)
        #expect(harness.notifier.announcements.isEmpty)
        #expect(harness.notifier.messages == [error.description])
        #expect(try #require(harness.notifier.signals.first) == .notify(error.description, nil))
    }

    @Test("a stop chord costs no second tree lookup")
    func stopDoesNotResolveAgain() {
        let harness = Harness()
        let id = harness.startRecording()

        harness.chord()
        harness.capture.reportDrained(id)

        // 38 ms of the 150 ms budget (F4), and the target is already captured (D4): resolving again
        // could only produce a different answer, which is the one thing invariant 3 forbids.
        #expect(harness.resolver.requested == ["S1"])
    }

    @Test("a start with no session id is refused rather than guessed at")
    func startWithoutSessionIsRefused() {
        // `dictactl` will not send this, but a hand-typed frame can, and inventing a session would
        // be the same substitution D4 forbids.
        let harness = Harness()

        let response = harness.send(Request(cmd: .start))

        #expect(response.kind == .rejected)
        #expect(response.message?.contains("needs the session") == true)
        #expect(harness.capture.callLog.isEmpty)
    }

    @Test("the attempt's target is the one resolved at the start, in every pane",
          arguments: Pane.allCases)
    func targetTravelsWithTheAttempt(pane: Pane) throws {
        let harness = Harness(pane: pane)

        harness.dictate()

        #expect(harness.injector.delivered.first?.target == Target(sessionID: "S1", pane: pane))
    }

    // MARK: - capture faults (D16, §7)

    @Test("a fault while recording discards, injects nothing, and is worded as hardware")
    func faultWhileRecording() throws {
        let harness = Harness()
        let id = harness.startRecording()

        harness.capture.reportFault(id, reason: "the input device went away")

        #expect(harness.daemon.state == .idle)
        #expect(harness.injector.delivered.isEmpty)
        #expect(harness.transcriber.transcribed.isEmpty)
        #expect(harness.notifier.announcements == [.listening, .blocked])
        let message = try #require(harness.notifier.messages.first)
        // Invariant 7: never "nothing was recognised", which is what silence looks like.
        #expect(message == "the input device went away")
        #expect(message != "nothing was recognised")
    }

    @Test("a fault while stopping is a fault, not silence")
    func faultWhileStopping() throws {
        // The row §7 singles out, and the one most likely to be mistaken for an empty dictation.
        let harness = Harness()
        let id = harness.startRecording()
        harness.chord()

        harness.capture.reportFault(id, reason: "the audio session was interrupted")

        #expect(harness.daemon.state == .idle)
        #expect(harness.injector.delivered.isEmpty)
        let message = try #require(harness.notifier.messages.first)
        #expect(message == "the audio session was interrupted")
    }

    @Test("a fault arriving after an abort does not resurrect the attempt")
    func lateFaultDoesNotResurrect() {
        let harness = Harness()
        let id = harness.startRecording()
        harness.send(Request(cmd: .abort))
        let before = harness.notifier.signals.count

        harness.capture.reportFault(id, reason: "the engine died")

        #expect(harness.daemon.state == .idle)
        #expect(harness.notifier.signals.count == before)
        #expect(harness.injector.delivered.isEmpty)
    }

    @Test("capture confirming after an abort never announces listening")
    func lateReadyDoesNotAnnounce() {
        let harness = Harness()
        harness.chord()
        harness.send(Request(cmd: .abort))

        harness.capture.reportReady(1)

        #expect(harness.daemon.state == .idle)
        #expect(harness.notifier.announcements == [.blocked])
    }

    @Test("audio arriving after an abort is never transcribed")
    func lateDrainIsNotTranscribed() {
        let harness = Harness()
        let id = harness.startRecording()
        harness.send(Request(cmd: .abort))

        harness.capture.reportDrained(id)

        #expect(harness.transcriber.transcribed.isEmpty)
        #expect(harness.injector.delivered.isEmpty)
    }

    // MARK: - the watchdog (§7)

    @Test("a warming attempt that never confirms becomes a capture fault")
    func watchdogFaultsAWedgedWarmup() throws {
        let harness = Harness(warmupTimeout: 5)
        harness.chord()

        harness.clock.advance(by: 4.9)
        #expect(harness.daemon.state == .warming)

        harness.clock.advance(by: 0.2)

        #expect(harness.daemon.state == .idle)
        #expect(harness.capture.callLog == [.begin(1), .discard(1)])
        #expect(harness.injector.delivered.isEmpty)
        let message = try #require(harness.notifier.messages.first)
        #expect(message == "the microphone did not start")
        #expect(harness.notifier.announcements == [.blocked])
    }

    @Test("a drain that never completes becomes a capture fault")
    func watchdogFaultsAWedgedDrain() throws {
        let harness = Harness(drainTimeout: 10)
        let id = harness.startRecording()
        harness.chord()

        harness.clock.advance(by: 11)

        #expect(harness.daemon.state == .idle)
        #expect(harness.capture.callLog == [.begin(id), .drain(id), .discard(id)])
        #expect(harness.injector.delivered.isEmpty)
        let message = try #require(harness.notifier.messages.last)
        #expect(message == "the microphone did not stop")
    }

    @Test("a completed attempt is never faulted by the timer that was watching it")
    func watchdogDoesNotFaultACompletedAttempt() {
        let harness = Harness()

        harness.dictate()
        // Asserted behaviourally rather than by counting `FakeClock.scheduledCount`, which keeps
        // cancelled work in its list until its deadline passes. What matters is that the deadline
        // arriving changes nothing: no `blocked`, no notification, no second delivery.
        harness.clock.advance(by: 3_600)

        #expect(harness.notifier.announcements == [.listening, .working, .done])
        #expect(harness.notifier.messages.isEmpty)
        #expect(harness.injector.delivered.count == 1)
        #expect(harness.daemon.state == .idle)
    }

    @Test("recording is watched only by the cap, so a nine-minute dictation is not faulted")
    func recordingIsNotWatchdogged() {
        // The duration cap is the only bound on `recording` (D15). A watchdog here would end a
        // legitimate two-minute dictation, which is why `recording` has none.
        let harness = Harness()
        harness.startRecording()

        harness.clock.advance(by: 599)

        #expect(harness.daemon.state == .recording)
        #expect(harness.notifier.announcements == [.listening])
    }

    // MARK: - the duration cap (D15)

    @Test("ten minutes of recording ends the attempt, injects nothing, and says why")
    func capEndsALongRecording() throws {
        let harness = Harness()
        let id = harness.startRecording()

        harness.clock.advance(by: 600)

        #expect(harness.daemon.state == .idle)
        // Invariant 6 through D15: the cap is a capture fault, and a capture fault never injects.
        #expect(harness.injector.delivered.isEmpty)
        #expect(harness.transcriber.transcribed.isEmpty)
        #expect(harness.capture.callLog == [.begin(id), .discard(id)])
        #expect(harness.notifier.announcements == [.listening, .blocked])
        let message = try #require(harness.notifier.messages.first)
        #expect(message == FaultReason.durationCap)
        // §9 gives the cap its own outcome, so a human reading the record with `tail` can tell "you
        // spoke for ten minutes" from "the device went away".
        let entry = try #require(harness.history.appended.last)
        #expect(entry.id == id)
        #expect(entry.outcome == .capped)
        #expect(entry.error?.contains("ten-minute") == true)
    }

    @Test("a cap firing while the text is being processed still records the text it produced")
    func capDuringProcessingKeepsTheText() throws {
        // D15's second half: the audio is discarded and nothing is injected, but whatever text was
        // produced is still logged. `processing` lasts exactly as long as the seam calls inside it,
        // so the cap is fired from inside the filter -- the point at which the recogniser's output
        // exists and the attempt has not ended.
        let filter = HookedFilter()
        let harness = Harness(filter: filter)
        // The clock rather than the harness: `FakeClock` is the only part of it the hook needs, and
        // it is the only part that is `Sendable`.
        let clock = harness.clock
        filter.setHook { clock.advance(by: 600) }

        let id = harness.startRecording()
        harness.chord()
        harness.capture.reportDrained(id)

        #expect(harness.daemon.state == .idle)
        #expect(harness.injector.delivered.isEmpty)
        let entry = try #require(harness.history.appended.last)
        #expect(entry.id == id)
        #expect(entry.outcome == .capped)
        // The text the attempt DID produce, in the record and nowhere else -- which is the only
        // route by which the user can still recover it with `dictactl last --recognised`.
        #expect(entry.recognised == FakeTranscriber.hostileText)
    }

    @Test("the cap is not disarmed by the stop chord, because a wedged drain is still ten minutes")
    func capSurvivesTheStopChord() throws {
        let harness = Harness(drainTimeout: 3_600)
        let id = harness.startRecording()
        harness.clock.advance(by: 590)
        harness.chord() // the stop chord: the attempt is now draining

        harness.clock.advance(by: 10)

        #expect(harness.daemon.state == .idle)
        #expect(harness.injector.delivered.isEmpty)
        let entry = try #require(harness.history.appended.last)
        #expect(entry.id == id)
        #expect(entry.outcome == .capped)
    }

    @Test("a delivered dictation is never capped by the timer that was counting it")
    func capDoesNotFaultACompletedAttempt() {
        let harness = Harness()

        harness.dictate()
        harness.clock.advance(by: 3_600)

        #expect(harness.notifier.announcements == [.listening, .working, .done])
        #expect(harness.injector.delivered.count == 1)
        #expect(harness.history.appended.allSatisfy { $0.outcome != .capped })
    }

    @Test("the cap counts each attempt separately rather than the daemon's uptime")
    func capIsPerAttempt() {
        let harness = Harness()

        harness.dictate()
        harness.clock.advance(by: 599)
        let second = harness.startRecording()
        harness.clock.advance(by: 599)

        // The second attempt is 599 seconds old, not 1198: a cap that counted from the daemon's
        // start would kill every dictation after the first ten minutes of uptime.
        #expect(harness.daemon.state == .recording)
        #expect(harness.daemon.currentAttempt?.id == second)
    }

    @Test("a fault that is not the cap is recorded as a capture fault, not as capped")
    func hardwareFaultIsNotCapped() throws {
        let harness = Harness()
        let id = harness.startRecording()

        harness.capture.reportFault(id, kind: .hardware, reason: FaultReason.deviceChanged)

        let entry = try #require(harness.history.appended.last)
        #expect(entry.outcome == .captureFault)
        #expect(entry.error?.contains("discarded") == true)
    }

    @Test("a denied microphone ends the attempt with the grant as its reason")
    func deniedMicrophoneEndsTheAttempt() throws {
        // §6 wants "coming up", "ready" and "denied" tellable apart. From the daemon's side that is
        // a fault whose words send the user to System Settings rather than to their hardware.
        let harness = Harness()
        harness.chord()

        harness.capture.reportFault(1, kind: .denied, reason: FaultReason.denied)

        #expect(harness.daemon.state == .idle)
        #expect(harness.notifier.announcements == [.blocked])
        #expect(harness.notifier.messages == [FaultReason.denied])
        let entry = try #require(harness.history.appended.last)
        #expect(entry.outcome == .captureFault)
        #expect(entry.recognised.isEmpty)
    }

    @Test("a cap arriving after an abort does not resurrect the attempt")
    func lateCapDoesNotResurrect() {
        let harness = Harness()
        let id = harness.startRecording()
        harness.send(Request(cmd: .abort))
        let entries = harness.history.appended.count

        harness.capture.reportFault(id, kind: .durationCap, reason: FaultReason.durationCap)

        #expect(harness.daemon.state == .idle)
        #expect(harness.injector.delivered.isEmpty)
        // No second entry, and in particular no `capped` entry superseding the abort: the attempt
        // was over before the cap came due.
        #expect(harness.history.appended.count == entries)
    }

    // MARK: - the front door

    @Test("a request over a real socket reaches the daemon and comes back with the state")
    func roundTripOverTheSocket() throws {
        let harness = Harness()
        try harness.daemon.start()
        defer { harness.daemon.stop() }

        let response = try ControlClient.send(Request(cmd: .status),
                                              to: harness.daemon.configuration.socketPath)

        #expect(response.kind == .accepted)
        #expect(response.state == .idle)
    }

    @Test("chords arriving together over the socket still start exactly one attempt")
    func simultaneousChordsStartOneAttempt() throws {
        // D7's other half, and the half nothing exercised. `StateMachineTests.toggleIsNotARace`
        // proves the DECISION is atomic, but it proves it against a pure value, which cannot race
        // by construction. What makes the shipping daemon safe is the server serialising handlers
        // and the state lock behind them -- and this component has a recorded history of exactly
        // this kind of bug (CLAUDE.md's non-overcommit pool starvation).
        let harness = Harness()
        try harness.daemon.start()
        defer { harness.daemon.stop() }
        let path = harness.daemon.configuration.socketPath

        // Real threads, not a cooperative pool: `ControlClient.send` blocks, and blocking Darwin's
        // non-overcommit workers is what starved this suite's round trips into their timeout once.
        let ready = DispatchSemaphore(value: 0)
        let go = DispatchSemaphore(value: 0)
        let answers = Locked<[Response]>([])
        let threads = (0 ..< 8).map { _ in
            Thread {
                ready.signal()
                go.wait()
                if let response = try? ControlClient.send(
                    Request(cmd: .toggle, sessionID: "S1", mode: .clean), to: path) {
                    answers.set(answers.value + [response])
                }
            }
        }
        for thread in threads { thread.start() }
        for _ in threads { ready.wait() }
        for _ in threads { go.signal() }

        // Every chord is answered -- none is dropped or left to time out.
        let deadline = Date().addingTimeInterval(10)
        while answers.value.count < threads.count, Date() < deadline { usleep(2_000) }
        #expect(answers.value.count == threads.count)

        // Eight toggles are four start/stop pairs, not eight competing starts -- D7 resolves each
        // chord against the state the one before it left. What must hold under contention is that
        // the microphone is never opened twice over: every `begin` is closed out before the next
        // one, and no id is ever begun twice.
        var live: AttemptID?
        var begun: [AttemptID] = []
        for call in harness.capture.callLog {
            switch call {
            case let .begin(id):
                #expect(live == nil,
                        "attempt \(id) opened the microphone while \(live ?? 0) still held it")
                live = id
                begun.append(id)
            case let .drain(id), let .discard(id):
                #expect(live == id, "\(id) was ended without being the live attempt")
                live = nil
            }
        }
        #expect(begun.count == Set(begun).count, "an id was begun twice: \(begun)")
        #expect(!begun.isEmpty, "the chords must have done something: \(harness.capture.callLog)")
        // Every answer names an attempt that was actually issued -- no chord is told about one that
        // never existed, which is what a lost update to the id counter would look like.
        for answered in answers.value.compactMap(\.attempt) {
            #expect(begun.contains(answered), "answered about attempt \(answered), never begun")
        }
    }

    @Test("a second daemon on a live socket refuses to start")
    func secondInstanceIsRefused() throws {
        // §7: one daemon, one microphone. A live socket means a live daemon.
        let harness = Harness()
        try harness.daemon.start()
        defer { harness.daemon.stop() }

        let second = Daemon(
            configuration: Daemon.Configuration(
                socketPath: harness.daemon.configuration.socketPath,
                activeTargetFile: harness.activeTargetFile
            ),
            capture: FakeCapture(),
            transcriber: FakeTranscriber(),
            history: FakeHistory(),
            clock: FakeClock(),
            resolver: FakeTargetResolver(),
            injector: FakeInjector(),
            notifier: FakeNotifier()
        )

        #expect(throws: ControlServer.ServerError.alreadyRunning(
            path: harness.daemon.configuration.socketPath
        )) {
            try second.start()
        }
    }

    @Test("an unreadable frame is refused loudly rather than answered with a guess")
    func undecodableFrameIsRefused() throws {
        let harness = Harness()

        let response = harness.daemon.handle(.undecodable("not a command this build knows"))

        #expect(response.kind == .rejected)
        // The state is the daemon's real one: inventing `idle` for a frame it could not read would
        // be a lie the client cannot tell from the truth.
        #expect(response.state == .idle)
        let message = try #require(harness.notifier.messages.first)
        #expect(message.contains("not a command this build knows"))
    }

    // MARK: - the stale indicator (§7)

    @Test("a live attempt parks its target, and finishing removes it")
    func targetIsParkedForTheDurationOfTheAttempt() {
        let harness = Harness()

        let id = harness.startRecording()
        #expect(FileManager.default.fileExists(atPath: harness.activeTargetFile.path))

        harness.chord()
        harness.capture.reportDrained(id)
        // A light claiming a recording that is not happening is worse than no light (§7), so the
        // parked target exists only while there is something to claim.
        #expect(!FileManager.default.fileExists(atPath: harness.activeTargetFile.path))
    }

    @Test("a daemon starting after a crash puts the abandoned indicator out")
    func startupClearsAStaleIndicator() throws {
        let harness = Harness()
        try JSONEncoder().encode(Self.target).write(to: harness.activeTargetFile)

        try harness.daemon.start()
        defer { harness.daemon.stop() }

        #expect(harness.notifier.signals == [.clear(Self.target)])
        #expect(!FileManager.default.fileExists(atPath: harness.activeTargetFile.path))
    }

    @Test("a daemon starting with no parked target touches no indicator")
    func startupWithoutAStaleIndicatorIsSilent() throws {
        let harness = Harness()

        try harness.daemon.start()
        defer { harness.daemon.stop() }

        #expect(harness.notifier.signals.isEmpty)
    }

    // MARK: - small helpers

    final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value

        init(_ value: Value) { stored = value }

        var value: Value { lock.withLock { stored } }
        func set(_ value: Value) { lock.withLock { stored = value } }
    }

    /// A recogniser that runs the test's code from INSIDE recognition, which is the only moment the
    /// daemon is in `processing`.
    final class ReentrantTranscriber: Transcriber, @unchecked Sendable {
        private let body: @Sendable () -> Void

        init(_ body: @escaping @Sendable () -> Void) { self.body = body }

        func transcribe(_ audio: Audio) throws -> String {
            body()
            return FakeTranscriber.hostileText
        }
    }

    /// An injector that runs the test's code from INSIDE the injection, which is the only moment
    /// the daemon is in `injecting` -- the state D20's refusal is about.
    /// An injector that fails with something that is NOT a `DeliveryFailure`. The seam permits any
    /// `Error` (`Seams.swift`), and only `Agterm` happens to narrow it -- so the daemon's generic
    /// `catch` is reachable by any future injector, and it is the branch that decides which side of
    /// "nothing was typed" versus "something may have been" the attempt is recorded on.
    final class ExplodingInjector: Injector, @unchecked Sendable {
        struct Boom: Error, CustomStringConvertible {
            var description: String { "the injector came apart" }
        }

        func inject(_ text: String, into target: Target) throws { throw Boom() }
    }

    final class ReentrantInjector: Injector, @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String] = []
        private let body: @Sendable () -> Void

        init(_ body: @escaping @Sendable () -> Void) { self.body = body }

        var delivered: [String] { lock.withLock { texts } }

        func inject(_ text: String, into target: Target) throws {
            lock.withLock { texts.append(text) }
            body()
        }
    }
}
