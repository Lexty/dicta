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
        let daemon: Daemon

        /// `injecting` and `processing` each last exactly as long as one synchronous seam call, so
        /// a test about either substitutes that seam with one that runs its own code from inside.
        init(pane: Pane = .left,
             warmupTimeout: TimeInterval = 5,
             drainTimeout: TimeInterval = 10,
             transcriber: (any Transcriber)? = nil,
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
            daemon = Daemon(
                configuration: Daemon.Configuration(
                    socketPath: directory.appendingPathComponent("c.sock").path,
                    activeTargetFile: directory.appendingPathComponent("active-target.json"),
                    warmupTimeout: warmupTimeout,
                    drainTimeout: drainTimeout
                ),
                capture: capture,
                transcriber: transcriber ?? self.transcriber,
                filter: filter,
                history: history ?? self.history,
                clock: clock,
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

    @Test("recording is not watched, so a long dictation is not faulted")
    func recordingIsNotWatchdogged() {
        // The duration cap is the bound on `recording` (D15), and it arrives with real capture in
        // Task 9. A watchdog here would end a legitimate two-minute dictation.
        let harness = Harness()
        harness.startRecording()

        harness.clock.advance(by: 600)

        #expect(harness.daemon.state == .recording)
        #expect(harness.notifier.announcements == [.listening])
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
