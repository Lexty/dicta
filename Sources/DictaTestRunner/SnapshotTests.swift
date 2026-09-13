import DictaCore
import Foundation
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

    @Test("a missing agterm is a fault only under agterm-only")
    func missingAgtermIsAFaultOnlyUnderAgtermOnly() {
        // D31: under `other-apps` every other application's focused field still takes the words,
        // and under `undecided` nobody has chosen yet, so the same fact that is a fault under
        // `agterm-only` is a notice or a step there.
        let agtermOnly = Faculties(microphone: true, models: true, terminal: false)
        let otherApps = Faculties(microphone: true, models: true, terminal: false,
                                  scope: .otherApps, accessibility: true)
        let undecided = Faculties(microphone: true, models: true, terminal: false,
                                  scope: .undecided)
        #expect(agtermOnly.readiness == .terminalMissing)
        #expect(agtermOnly.readiness.blocksDictation)
        #expect(agtermOnly.readiness.isFault)
        #expect(otherApps.readiness == .fieldsOnly)
        #expect(!otherApps.readiness.blocksDictation)
        #expect(undecided.readiness == .setupNeeded)
        #expect(undecided.readiness.blocksDictation)
        #expect(!undecided.readiness.isFault)
        // agterm found with the grant is ready under every scope, and the scope changes nothing
        // about the faults ahead of it in the pipeline or about start-up.
        for scope in SetupScope.allCases {
            let grant: Bool? = scope == .otherApps ? true : nil
            #expect(Faculties(microphone: true, models: true, terminal: true, scope: scope,
                              accessibility: grant).readiness == .ready)
            #expect(Faculties(microphone: false, models: true, terminal: false, scope: scope,
                              accessibility: grant).readiness == .microphoneDenied)
            #expect(Faculties(microphone: nil, models: true, terminal: nil, scope: scope,
                              accessibility: grant).readiness == .starting)
        }
    }

    @Test("readiness follows every row of the table, in order")
    func readinessTable() {
        typealias Row = (Faculties, Readiness)
        let rows: [Row] = [
            // The faults, whatever the scope.
            (Faculties(microphone: false, models: false, terminal: false, scope: .undecided),
             .microphoneDenied),
            (Faculties(microphone: true, models: false, terminal: false, scope: .otherApps,
                       accessibility: false), .modelsMissing),
            (Faculties(microphone: true, models: true, terminal: false, scope: .agtermOnly),
             .terminalMissing),
            // An unreadable `setup.json` without agterm is `terminalMissing` too: the daemon
            // applies `agterm-only` over one (D31), and that is the scope the facts carry.
            (Faculties(microphone: true, models: true, terminal: false, scope: .agtermOnly),
             .terminalMissing),
            // `terminalMissing` comes before `starting`, as the faults all do.
            (Faculties(microphone: nil, models: nil, terminal: false, scope: .agtermOnly),
             .terminalMissing),
            // `starting` before every notice and pending step.
            (Faculties(microphone: nil, models: true, terminal: false, scope: .undecided),
             .starting),
            (Faculties(microphone: true, models: nil, terminal: false, scope: .otherApps,
                       accessibility: false), .starting),
            (Faculties(microphone: true, models: true, terminal: nil, scope: .otherApps,
                       accessibility: false), .starting),
            // The grant is unknown only under `other-apps`; elsewhere nobody may look.
            (Faculties(microphone: true, models: true, terminal: false, scope: .otherApps),
             .starting),
            (Faculties(microphone: true, models: true, terminal: true, scope: .otherApps),
             .starting),
            (Faculties(microphone: true, models: true, terminal: true, scope: .agtermOnly),
             .ready),
            (Faculties(microphone: true, models: true, terminal: true, scope: .undecided),
             .ready),
            // The pending steps and the notice.
            (Faculties(microphone: true, models: true, terminal: false, scope: .undecided),
             .setupNeeded),
            (Faculties(microphone: true, models: true, terminal: false, scope: .otherApps,
                       accessibility: false), .accessibilityNeeded),
            (Faculties(microphone: true, models: true, terminal: true, scope: .otherApps,
                       accessibility: false), .accessibilityForFields),
            (Faculties(microphone: true, models: true, terminal: false, scope: .otherApps,
                       accessibility: true), .fieldsOnly),
            (Faculties(microphone: true, models: true, terminal: true, scope: .otherApps,
                       accessibility: true), .ready),
        ]
        for (facts, verdict) in rows {
            #expect(facts.readiness == verdict, "\(facts)")
        }
    }

    @Test("a missing grant blocks only without agterm, and is never a fault")
    func missingGrantIsAPendingStep() {
        let withoutAgterm = Faculties(microphone: true, models: true, terminal: false,
                                      scope: .otherApps, accessibility: false)
        let withAgterm = Faculties(microphone: true, models: true, terminal: true,
                                   scope: .otherApps, accessibility: false)
        #expect(withoutAgterm.readiness == .accessibilityNeeded)
        #expect(withoutAgterm.readiness.blocksDictation)
        #expect(!withoutAgterm.readiness.isFault)
        #expect(withAgterm.readiness == .accessibilityForFields)
        #expect(!withAgterm.readiness.blocksDictation)
        #expect(!withAgterm.readiness.isFault)
    }

    @Test("a missing agterm with focused fields on is drawn as a working daemon, not a fault")
    func fieldsOnlyIsNotAFault() {
        let presentation = Presentation.of(StatusSnapshot(state: .idle, readiness: .fieldsOnly))
        #expect(presentation.glyph == "mic")
        #expect(presentation.tint == .quiet)
        #expect(presentation.status == "Ready, without agterm")
        // The red triangle stays the option-off verdict's.
        #expect(Presentation.of(StatusSnapshot(state: .idle, readiness: .terminalMissing)).tint
            == .red)
    }

    @Test("a fault is reported even while something else is still unknown")
    func faultsOutrankStarting() {
        // The user can act on a denied microphone NOW; by the time they come back from System
        // Settings the models will have finished loading. Waiting for full knowledge before saying
        // anything would waste exactly the interval in which the fix is free.
        #expect(Faculties(microphone: false, models: nil, terminal: nil).readiness
            == .microphoneDenied)
    }

    @Test("only the blocking verdicts claim to block, and only the broken ones are faults")
    func blockingIsExhaustive() {
        for readiness in Readiness.allCases {
            switch readiness {
            case .ready, .starting:
                #expect(!readiness.blocksDictation)
                #expect(!readiness.isFault)
                #expect(readiness.message == nil)
            case .fieldsOnly:
                // A notice: it does not block, and it still says where the words cannot go.
                #expect(!readiness.blocksDictation)
                #expect(!readiness.isFault)
                #expect(readiness.message?.contains("agtermctl") == true)
            case .accessibilityForFields:
                #expect(!readiness.blocksDictation)
                #expect(!readiness.isFault)
                #expect(readiness.message?.contains("Accessibility") == true)
            case .setupNeeded, .accessibilityNeeded:
                // Pending steps: they block, and nothing is broken.
                #expect(readiness.blocksDictation)
                #expect(!readiness.isFault)
                #expect(readiness.message?.isEmpty == false)
            case .microphoneDenied, .modelsMissing, .terminalMissing:
                #expect(readiness.blocksDictation)
                #expect(readiness.isFault)
                // Every banner names the thing to do. One that only reports gets dismissed.
                #expect(readiness.message?.isEmpty == false)
            }
            let setupSteps: [Readiness] = [.setupNeeded, .accessibilityNeeded,
                                           .accessibilityForFields]
            #expect(readiness.isSetupStep == setupSteps.contains(readiness))
        }
    }

    @Test("only a fault draws the red triangle")
    func onlyAFaultIsRed() {
        for readiness in Readiness.allCases {
            let presentation = Presentation.of(StatusSnapshot(state: .idle, readiness: readiness))
            if readiness.isFault {
                #expect(presentation.tint == .red, "\(readiness)")
                #expect(presentation.glyph == "exclamationmark.triangle.fill")
            } else {
                // A pending step blocks and still draws the quiet glyph: nothing is broken.
                #expect(presentation.tint == .quiet, "\(readiness)")
                #expect(presentation.glyph == "mic")
            }
            #expect(!presentation.status.isEmpty)
        }
    }

    // MARK: - the facts on the wire

    @Test("a snapshot from an older daemon, without setup, faculties or hold, still decodes")
    func olderSnapshotDecodes() throws {
        let json = #"{"state":"idle","readiness":"ready","capSeconds":600}"#
        let snapshot = try JSONDecoder().decode(StatusSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.state == .idle)
        #expect(snapshot.setup == nil)
        #expect(snapshot.faculties == nil)
        // `nil`, never `.disabled`: an older daemon's user must not be told no key is armed.
        #expect(snapshot.hold == nil)
    }

    @Test("setup, faculties and both hold cases round trip")
    func newFactsRoundTrip() throws {
        let snapshots = [
            StatusSnapshot(
                state: .idle, readiness: .accessibilityForFields,
                setup: SetupSnapshot(scope: .otherApps, offerSeen: true),
                faculties: Faculties(microphone: true, models: true, terminal: true,
                                     scope: .otherApps, accessibility: false),
                hold: .armed(keys: ["Right Control", "F13"])),
            StatusSnapshot(
                state: .idle, readiness: .terminalMissing,
                setup: SetupSnapshot(scope: .agtermOnly, offerSeen: false,
                                     loadProblem: .unreadable(reason: "invalid JSON"),
                                     saveError: "the disk is full"),
                faculties: Faculties(microphone: nil, models: false, terminal: false),
                hold: .disabled),
            StatusSnapshot(
                state: .idle, readiness: .setupNeeded,
                setup: SetupSnapshot(scope: .undecided, offerSeen: false,
                                     loadProblem: .newerSchema(found: 2)),
                faculties: Faculties(scope: .undecided)),
        ]
        for snapshot in snapshots {
            let data = try JSONEncoder().encode(snapshot)
            #expect(try JSONDecoder().decode(StatusSnapshot.self, from: data) == snapshot)
        }
        // The new verdicts travel under their hyphenated raw values, like every other one.
        #expect(Readiness.setupNeeded.rawValue == "setup-needed")
        #expect(Readiness.accessibilityNeeded.rawValue == "accessibility-needed")
        #expect(Readiness.accessibilityForFields.rawValue == "accessibility-for-fields")
    }

    @Test("the hold snapshot names the default keys, custom keys, or none under --no-hold")
    func holdSnapshotOf() {
        #expect(HoldSnapshot.of(armHoldTrigger: true, keys: [])
            == .armed(keys: ["the right Control key", "the right Command key"]))
        #expect(HoldSnapshot.of(armHoldTrigger: true, keys: [])
            == .armed(keys: HoldKey.defaultPair.map(\.describedName)))
        #expect(HoldSnapshot.of(armHoldTrigger: true, keys: [.rightOption])
            == .armed(keys: ["the right Option key"]))
        #expect(HoldSnapshot.of(armHoldTrigger: true, keys: [.rightCommand, .rightControl])
            == .armed(keys: ["the right Command key", "the right Control key"]))
        #expect(HoldSnapshot.of(armHoldTrigger: false, keys: []) == .disabled)
        #expect(HoldSnapshot.of(armHoldTrigger: false, keys: [.rightOption]) == .disabled)
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
