import DictaCore
import Testing

/// The pure half of what a UI draws (D27): readiness derived from three facts, and the mapping from
/// a snapshot to a glyph and a sentence.
///
/// These are values rather than views on purpose (D19). What a state should look like is a decision
/// and belongs where a test can reach it; turning `Tint.red` into a colour is the performance and
/// belongs in `DictaMenu`. The practical half of that argument: SwiftPM cannot import an executable
/// target, so a mapping written in the menu app would be unreachable from here.
@Suite("snapshot")
struct SnapshotTests {
    // MARK: - readiness is derived, never stored

    @Test("nothing known yet is starting, not broken")
    func unknownIsStarting() {
        // The state of every login for the first second or two. Reporting it as a fault would put
        // two red banners in front of the user every morning, which is how a red banner stops
        // meaning anything.
        #expect(Faculties().readiness == .starting)
        #expect(Faculties(microphone: true).readiness == .starting)
        #expect(Faculties(microphone: true, models: true).readiness == .starting)
    }

    @Test("all three established is ready")
    func allGoodIsReady() {
        #expect(Faculties(microphone: true, models: true, terminal: true).readiness == .ready)
    }

    @Test("the reason reported is the first one a dictation would hit")
    func precedenceFollowsThePipeline() {
        // Heard, then recognised, then delivered. A failure further down is real but not yet the
        // user's problem — fixing the microphone first is the only order that makes progress.
        let allBroken = Faculties(microphone: false, models: false, terminal: false)
        #expect(allBroken.readiness == .microphoneDenied)
        #expect(Faculties(microphone: true, models: false, terminal: false).readiness
            == .modelsMissing)
        #expect(Faculties(microphone: true, models: true, terminal: false).readiness
            == .terminalMissing)
    }

    @Test("a fault is reported even while something else is still unknown")
    func faultsOutrankStarting() {
        // The user can act on a denied microphone NOW; by the time they come back from System
        // Settings the models will have finished loading. Waiting for full knowledge before saying
        // anything would waste exactly the interval in which the fix is free.
        #expect(Faculties(microphone: false, models: nil, terminal: nil).readiness
            == .microphoneDenied)
    }

    @Test("only the blocking verdicts claim to block")
    func blockingIsExhaustive() {
        for readiness in Readiness.allCases {
            switch readiness {
            case .ready, .starting:
                #expect(!readiness.blocksDictation)
                #expect(readiness.message == nil)
            case .microphoneDenied, .modelsMissing, .terminalMissing:
                #expect(readiness.blocksDictation)
                // Every banner names the thing to do. One that only reports gets dismissed.
                #expect(readiness.message?.isEmpty == false)
            }
        }
    }

    // MARK: - the glyph and the sentence

    @Test("readiness outranks the lifecycle when the daemon is idle")
    func faultsOutrankIdle() {
        let broken = StatusSnapshot(state: .idle, readiness: .modelsMissing)
        let presentation = Presentation.of(broken)
        // Drawing this the same as a healthy idle daemon is the silence the whole UI exists to
        // break: the user presses a chord and nothing happens, with no clue why.
        #expect(presentation.tint == .red)
        #expect(presentation.glyph == "exclamationmark.triangle.fill")
        #expect(presentation.status == "Models not downloaded")
    }

    @Test("warming does not say Listening")
    func warmingIsNotListening() {
        let warming = Presentation.of(StatusSnapshot(state: .warming))
        // D13 and invariant 4. A user told "Listening" before capture confirms starts speaking into
        // a microphone that is not open yet and loses the first syllable, every single time.
        #expect(warming.status != "Listening")
        #expect(warming.glyph == "mic")
        #expect(warming.tint == .quiet)
    }

    @Test("recording is the only red that is not a fault")
    func recordingIsRed() {
        let recording = Presentation.of(StatusSnapshot(state: .recording))
        #expect(recording.glyph == "mic.fill")
        #expect(recording.tint == .red)
        #expect(recording.status == "Listening")
    }

    @Test("working states are amber, and idle is quiet")
    func workingIsAmber() {
        #expect(Presentation.of(StatusSnapshot(state: .processing)).tint == .amber)
        #expect(Presentation.of(StatusSnapshot(state: .injecting)).tint == .amber)
        #expect(Presentation.of(StatusSnapshot(state: .idle)).tint == .quiet)
    }

    @Test("a daemon that cannot be seen is not drawn as an idle one")
    func notRunningIsItsOwnState() {
        // acta has no equivalent, because acta's menu IS its daemon. Here they are two processes,
        // so "I cannot see it" is a state of its own — and `idle` means a chord would work, which
        // is exactly what is not true.
        let idle = Presentation.of(StatusSnapshot(state: .idle))
        #expect(Presentation.daemonNotRunning.glyph != idle.glyph)
        #expect(Presentation.daemonNotRunning.tint == .faint)
    }

    @Test("a live attempt still shows its state, not its readiness")
    func busyOutranksReadiness() {
        // Readiness only wins when idle. A dictation already under way is the truth on the screen —
        // and `starting` is common at login, when the first chord may already be recording.
        let recording = StatusSnapshot(state: .recording, readiness: .starting)
        #expect(Presentation.of(recording).status == "Listening")
    }

    // MARK: - the cap

    @Test("the snapshot carries the cap so the UI needs no copy of it")
    func capTravels() {
        let snapshot = StatusSnapshot(state: .recording, speakingSeconds: 570, capSeconds: 600)
        #expect(snapshot.secondsUntilCap == 30)
        // A UI with a hard-coded ten minutes would keep saying ten after the daemon's configuration
        // changed, and the first the user would know is a dictation vanishing early (D15).
        #expect(StatusSnapshot(state: .idle).secondsUntilCap == nil)
    }

    @Test("busy covers warming, because a second chord is refused there too")
    func warmingIsBusy() {
        #expect(StatusSnapshot(state: .warming).isBusy)
        #expect(!StatusSnapshot(state: .idle).isBusy)
    }

    // MARK: - outcomes

    @Test("every outcome has a colour and a word, and returned reads as landed")
    func outcomesAreExhaustive() {
        for outcome in AttemptOutcome.allCases {
            #expect(!outcome.label.isEmpty)
        }
        // The pair that is got backwards by reasoning from the outcome's NAME instead of from
        // `final`: a cancelled attempt produced no deliverable text, a returned one did.
        #expect(AttemptOutcome.returned.tint == .green)
        #expect(AttemptOutcome.injected.tint == .green)
        #expect(AttemptOutcome.aborted.tint == .faint)
        // ...and `returned` still does not borrow `injected`'s wording, because dicta cannot know
        // what the calling script did with the text it handed over.
        #expect(AttemptOutcome.returned.label != AttemptOutcome.injected.label)
        #expect(AttemptOutcome.returned.label.contains("caller"))
    }

    @Test("failures are red and silence is faint")
    func failuresAreRed() {
        for outcome in [AttemptOutcome.targetGone, .injectionFailed, .recognitionFailed,
                        .captureFault, .capped] {
            #expect(outcome.tint == .red, "\(outcome.rawValue) should read as not delivered")
        }
        // Not red: nothing was lost, there was simply nothing there.
        #expect(AttemptOutcome.empty.tint == .faint)
    }
}
