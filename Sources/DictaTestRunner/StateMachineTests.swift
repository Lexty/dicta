import DictaCore
import Foundation
import Testing

/// The executable form of SPEC.md §6's table and of the rules that fall out of it.
///
/// One test per cell, named after the cell, so that a missing cell is visible in the test list
/// rather than only in a careful reading of the source. The cells the table makes non-obvious --
/// stop during `warming`, abort during `injecting`, the quiet no-ops -- are the ones that would
/// otherwise surface by mashing a chord at the wrong moment with a live microphone.
@Suite("state machine")
struct StateMachineTests {
    static let target = Target(sessionID: "session:abc123", pane: .left)
    static let otherTarget = Target(sessionID: "session:def456", pane: .right)
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// A machine parked in each lifecycle state, driven there the only way the daemon can drive it.
    /// `draining` is not a `LifecycleState` -- it reports as `recording` (§8.9) -- so it has its
    /// own builder below.
    ///
    /// `spendingAnAttemptFirst` runs one attempt to completion before parking, so that a spent id
    /// and a live attempt exist in the same machine.
    static func machine(in state: LifecycleState, mode: Mode = .clean,
                        spendingAnAttemptFirst: Bool = false) -> StateMachine {
        var machine = StateMachine()
        if spendingAnAttemptFirst {
            _ = machine.start(target: target, at: t0)
            _ = machine.abort()
        }
        guard state != .idle else { return machine }
        _ = machine.start(target: target, at: t0)
        guard state != .warming else { return machine }
        let id = machine.currentAttempt!.id
        _ = machine.captureReady(id)
        guard state != .recording else { return machine }
        _ = machine.stop(mode: mode)
        _ = machine.captureDrained(id)
        guard state != .processing else { return machine }
        _ = machine.recognised(id, .text)
        return machine
    }

    /// `recording` with a stop already requested and capture not yet drained. It reports as
    /// `recording` because §8.9 says the state is released only once capture has been drained.
    static func draining(mode: Mode = .clean) -> StateMachine {
        var machine = machine(in: .recording)
        _ = machine.stop(mode: mode)
        return machine
    }

    // MARK: - idle

    @Test("idle + start: begins the attempt")
    func idleStart() {
        var machine = StateMachine()
        let result = machine.start(target: Self.target, at: Self.t0)

        #expect(result.outcome == .accepted)
        #expect(result.state == .warming)
        #expect(machine.state == .warming)
        #expect(result.effects == [.beginCapture(1, Self.target)])
        // D13, invariant 4: the attempt exists, but the user has not been told anything yet.
        #expect(result.isSilent)
    }

    @Test("idle + stop: rejected, nothing to stop")
    func idleStop() {
        var machine = StateMachine()
        let result = machine.stop(mode: .clean)

        #expect(result.outcome == .rejected)
        #expect(result.state == .idle)
        #expect(result.message == "nothing to stop")
        #expect(!result.isSilent)
    }

    @Test("idle + abort: quiet no-op")
    func idleAbort() {
        var machine = StateMachine()
        let result = machine.abort()

        #expect(result.outcome == .noop)
        #expect(result.state == .idle)
        // Silent, deliberately: pressing abort when nothing is running must not scold the user.
        #expect(result.effects.isEmpty)
    }

    // MARK: - warming

    @Test("warming + start: rejected, already recording")
    func warmingStart() {
        var machine = Self.machine(in: .warming)
        let result = machine.start(target: Self.otherTarget, at: Self.t0)

        #expect(result.outcome == .rejected)
        #expect(result.message == "already recording")
        #expect(machine.state == .warming)
        // The rejection must not begin a second capture, nor re-aim the attempt (D4).
        #expect(!result.effects.contains { if case .beginCapture = $0 { true } else { false } })
        #expect(machine.currentAttempt?.target == Self.target)
    }

    @Test("warming + stop: cancels -- no audio exists yet, so nothing is delivered")
    func warmingStop() {
        var machine = Self.machine(in: .warming)
        let id = machine.currentAttempt!.id
        let result = machine.stop(mode: .clean)

        #expect(result.outcome == .accepted)
        #expect(result.state == .idle)
        #expect(result.attempt == id)
        #expect(result.effects.contains(.discardCapture(id)))
        // Nothing is transcribed and nothing is injected: there is no audio to have produced text.
        #expect(!result.injects)
        #expect(!result.effects.contains { if case .transcribe = $0 { true } else { false } })
        #expect(!result.isSilent, "a cancel that delivers nothing must be visible")
    }

    @Test("warming + abort: cancels")
    func warmingAbort() {
        var machine = Self.machine(in: .warming)
        let id = machine.currentAttempt!.id
        let result = machine.abort()

        #expect(result.outcome == .accepted)
        #expect(result.state == .idle)
        #expect(result.effects.contains(.discardCapture(id)))
        #expect(!result.injects)
    }

    // MARK: - recording

    @Test("recording + start: rejected, already recording")
    func recordingStart() {
        var machine = Self.machine(in: .recording)
        let result = machine.start(target: Self.otherTarget, at: Self.t0)

        #expect(result.outcome == .rejected)
        #expect(result.message == "already recording")
        #expect(machine.state == .recording)
        #expect(machine.currentAttempt?.target == Self.target)
    }

    @Test("recording + stop: stops and delivers in the chord's mode")
    func recordingStop() {
        for mode in Mode.allCases {
            var machine = Self.machine(in: .recording)
            let id = machine.currentAttempt!.id
            let result = machine.stop(mode: mode)

            #expect(result.outcome == .accepted)
            #expect(result.effects.contains(.drainCapture(id)))
            // §8.9: the audio is not in hand yet, so `recording` is not released here.
            #expect(result.state == .recording)

            let drained = machine.captureDrained(id)
            #expect(drained.state == .processing)
            #expect(drained.effects == [.transcribe(id, mode)], "the stopping chord picks the mode")
        }
    }

    @Test("recording + abort: cancels")
    func recordingAbort() {
        var machine = Self.machine(in: .recording)
        let id = machine.currentAttempt!.id
        let result = machine.abort()

        #expect(result.outcome == .accepted)
        #expect(result.state == .idle)
        #expect(result.effects.contains(.discardCapture(id)))
        #expect(!result.injects)
    }

    // MARK: - recording, stop requested, capture not yet drained (§8.9)

    @Test("draining + start: rejected, not queued behind the attempt that is still stopping")
    func drainingStart() {
        var machine = Self.draining()
        let result = machine.start(target: Self.otherTarget, at: Self.t0)

        // With a real audio engine this is two starts racing over one input device.
        #expect(result.outcome == .rejected)
        #expect(result.message == "already recording")
        #expect(machine.currentAttempt?.target == Self.target)
        #expect(!result.effects.contains { if case .beginCapture = $0 { true } else { false } })
    }

    @Test("draining + stop: quiet no-op, never a second delivery")
    func drainingStop() {
        var machine = Self.draining()
        let result = machine.stop(mode: .raw)

        #expect(result.outcome == .noop)
        #expect(result.effects.isEmpty)
        // Invariant 5, and the mode of the first stop stands.
        let id = machine.currentAttempt!.id
        #expect(machine.captureDrained(id).effects == [.transcribe(id, .clean)])
    }

    @Test("draining + abort: cancels")
    func drainingAbort() {
        var machine = Self.draining()
        let id = machine.currentAttempt!.id
        let result = machine.abort()

        #expect(result.outcome == .accepted)
        #expect(result.state == .idle)
        #expect(result.effects.contains(.discardCapture(id)))
        #expect(!result.injects)
    }

    // MARK: - processing

    @Test("processing + start: rejected, still working")
    func processingStart() {
        var machine = Self.machine(in: .processing)
        let result = machine.start(target: Self.otherTarget, at: Self.t0)

        #expect(result.outcome == .rejected)
        #expect(result.message == "still working")
        #expect(machine.state == .processing)
    }

    @Test("processing + stop: quiet no-op")
    func processingStop() {
        var machine = Self.machine(in: .processing)
        let result = machine.stop(mode: .raw)

        #expect(result.outcome == .noop)
        #expect(result.state == .processing)
        #expect(result.effects.isEmpty, "a duplicated stop is silent, not an error")
    }

    @Test("processing + abort: cancels, and nothing is injected")
    func processingAbort() {
        var machine = Self.machine(in: .processing)
        let id = machine.currentAttempt!.id
        let result = machine.abort()

        #expect(result.outcome == .accepted)
        #expect(result.state == .idle)
        #expect(result.attempt == id)
        #expect(!result.injects)
        // Recognition may still return; it must not resurrect the attempt.
        #expect(machine.recognised(id, .text).outcome == .noop)
        #expect(!machine.recognised(id, .text).injects)
    }

    // MARK: - injecting

    @Test("injecting + start: rejected, still working")
    func injectingStart() {
        var machine = Self.machine(in: .injecting)
        let result = machine.start(target: Self.otherTarget, at: Self.t0)

        #expect(result.outcome == .rejected)
        #expect(result.message == "still working")
        #expect(machine.state == .injecting)
    }

    @Test("injecting + stop: quiet no-op")
    func injectingStop() {
        var machine = Self.machine(in: .injecting)
        let result = machine.stop(mode: .clean)

        #expect(result.outcome == .noop)
        #expect(result.state == .injecting)
        #expect(result.effects.isEmpty)
    }

    @Test("injecting + abort: refused (D20)")
    func injectingAbort() {
        var machine = Self.machine(in: .injecting)
        let result = machine.abort()

        // Keystrokes already in the terminal cannot be recalled, so a cancellation reported here
        // would be contradicted on screen -- which breaks property 2 harder than the failure it
        // was describing.
        #expect(result.outcome == .rejected)
        #expect(result.state == .injecting)
        #expect(machine.state == .injecting)
        #expect(result.outcome != .noop, "refused is audible; a no-op would be silent")
        #expect(!result.isSilent)
    }

    // MARK: - a rejection is audible, a no-op is silent (§6)

    @Test("every rejection is audible and every no-op is silent")
    func rejectionsAndNoopsDiffer() {
        // Both are "the command changed nothing", and the difference is a sound the user hears.
        // They are separate values in the result rather than one value read two ways.
        #expect(CommandOutcome.rejected.isAudible)
        #expect(!CommandOutcome.noop.isAudible)

        for state in LifecycleState.allCases {
            for probe in Probe.all {
                var machine = Self.machine(in: state)
                let result = probe.apply(&machine)
                switch result.outcome {
                case .rejected:
                    #expect(!result.isSilent, "\(state) + \(probe.name): rejected but silent")
                    #expect(result.message != nil, "\(state) + \(probe.name): no reason given")
                case .noop:
                    #expect(result.isSilent, "\(state) + \(probe.name): a no-op made a noise")
                case .accepted:
                    break
                }
            }
        }
    }

    @Test("blocked is never announced without a reason to show alongside it")
    func blockedAlwaysCarriesAReason() {
        // §6's feedback table pairs `blocked` with a notification carrying the reason; an indicator
        // that goes red with nothing to read is the "lost silently" failure wearing a colour.
        for state in LifecycleState.allCases {
            for probe in Probe.all {
                var machine = Self.machine(in: state)
                let result = probe.apply(&machine)
                if result.announcements.contains(.blocked) {
                    #expect(!result.notifications.isEmpty,
                            "\(state) + \(probe.name): blocked with no notification")
                }
            }
        }
    }

    // MARK: - attempt ids

    @Test("attempt ids are monotonic and never reused")
    func idsAreMonotonic() {
        var machine = StateMachine()
        var seen: [AttemptID] = []

        for round in 0 ..< 4 {
            _ = machine.start(target: Self.target, at: Self.t0)
            let id = machine.currentAttempt!.id
            seen.append(id)
            // End each attempt a different way; none of them may hand the id back.
            switch round {
            case 0:
                _ = machine.abort()
            case 1:
                _ = machine.captureReady(id)
                _ = machine.stop(mode: .clean)
                _ = machine.captureDrained(id)
                _ = machine.recognised(id, .empty)
            case 2:
                _ = machine.fault(id, reason: "input device changed")
            default:
                _ = machine.captureReady(id)
                _ = machine.stop(mode: .raw)
                _ = machine.captureDrained(id)
                _ = machine.recognised(id, .text)
                _ = machine.injectionFinished(id, .delivered)
            }
            #expect(machine.state == .idle, "round \(round) did not end the attempt")
        }

        #expect(seen == [1, 2, 3, 4])
        #expect(Set(seen).count == seen.count)
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test("a command naming a spent attempt is a no-op in every state")
    func spentIdIsANoop() {
        // Attempt #1 is over before any of this; #2 is whatever the state under test is running.
        let spent: AttemptID = 1

        for state in LifecycleState.allCases {
            var machine = Self.machine(in: state, spendingAnAttemptFirst: true)
            #expect(machine.currentAttempt?.id != spent)

            let before = machine.state
            let stopped = machine.stop(mode: .clean, attempt: spent)
            #expect(stopped.outcome == .noop, "\(state): stop on a spent id was not a no-op")
            #expect(stopped.effects.isEmpty)
            #expect(machine.state == before)

            let aborted = machine.abort(attempt: spent)
            #expect(aborted.outcome == .noop, "\(state): abort on a spent id was not a no-op")
            #expect(aborted.effects.isEmpty)
            #expect(machine.state == before)
        }
    }

    @Test("a progress event naming a spent attempt is ignored")
    func spentProgressIsIgnored() {
        var machine = Self.machine(in: .warming)
        let first = machine.currentAttempt!.id
        _ = machine.abort()
        _ = machine.start(target: Self.target, at: Self.t0)
        let second = machine.currentAttempt!.id

        #expect(second > first)
        #expect(machine.captureReady(first).outcome == .noop)
        #expect(machine.state == .warming, "a spent attempt's callback moved the live one")
        #expect(machine.captureReady(second).outcome == .accepted)
        #expect(machine.state == .recording)
    }

    // MARK: - late callbacks never resurrect an abandoned attempt (§6)

    @Test("capture confirming readiness after an abort does not resurrect the attempt")
    func lateCaptureReady() {
        var machine = Self.machine(in: .warming)
        let id = machine.currentAttempt!.id
        _ = machine.abort()

        let late = machine.captureReady(id)
        #expect(late.outcome == .noop)
        #expect(machine.state == .idle)
        // Invariant 4 in its nastiest form: the "listening" sound must not fire after an abort.
        #expect(late.effects.isEmpty)
    }

    @Test("recognition returning after a cancel injects nothing")
    func lateRecognition() {
        var machine = Self.machine(in: .processing)
        let id = machine.currentAttempt!.id
        _ = machine.abort()

        let late = machine.recognised(id, .text)
        #expect(late.outcome == .noop)
        #expect(!late.injects)
        #expect(machine.state == .idle)
        #expect(late.effects.isEmpty)
    }

    @Test("injection completing after a fault does not report success")
    func lateInjectionCompletion() {
        var machine = Self.machine(in: .processing)
        let id = machine.currentAttempt!.id
        _ = machine.fault(id, reason: "the daemon wedged")

        let late = machine.injectionFinished(id, .delivered)
        #expect(late.outcome == .noop)
        #expect(machine.state == .idle)
        #expect(!late.announcements.contains(.done), "a dead attempt reported as delivered")
        #expect(late.effects.isEmpty)
    }

    // MARK: - the toggle resolves inside the machine (D7)

    @Test("the toggle resolves to start or to stop inside the machine")
    func toggleResolves() {
        var machine = StateMachine()
        let started = machine.toggle(mode: .clean, target: Self.target, at: Self.t0)
        #expect(started.effects == [.beginCapture(1, Self.target)])
        #expect(machine.state == .warming)

        _ = machine.captureReady(1)
        let stopped = machine.toggle(mode: .raw, target: Self.target, at: Self.t0)
        #expect(stopped.effects.contains(.drainCapture(1)))
        #expect(machine.captureDrained(1).effects == [.transcribe(1, .raw)],
                "the toggle that stops carries the mode of the chord that sent it")
    }

    @Test("resolving the toggle twice from the same state cannot yield both verbs")
    func toggleIsNotARace() {
        // The reason D7 exists: `status | grep idle && start || stop` is two round trips, and one
        // keypress can land on either side of the window between them. Resolved inside the machine,
        // the same state always resolves the same way -- and two toggles in a row can never both
        // start, because the first one has already left `idle`.
        for state in LifecycleState.allCases {
            var first = Self.machine(in: state)
            var second = Self.machine(in: state)
            let a = first.toggle(mode: .clean, target: Self.target, at: Self.t0)
            let b = second.toggle(mode: .clean, target: Self.target, at: Self.t0)
            #expect(a.effects == b.effects, "\(state): the same state resolved two ways")
            #expect(a.outcome == b.outcome)
        }

        var machine = StateMachine()
        let one = machine.toggle(mode: .clean, target: Self.target, at: Self.t0)
        let two = machine.toggle(mode: .clean, target: Self.target, at: Self.t0)
        #expect(one.effects.contains { if case .beginCapture = $0 { true } else { false } })
        #expect(!two.effects.contains { if case .beginCapture = $0 { true } else { false } })
    }

    // MARK: - capture faults (D16, invariants 6 and 7)

    @Test("a capture fault discards and never injects, in every state it can reach")
    func faultNeverInjects() {
        for state in LifecycleState.allCases where state != .idle {
            var machine = Self.machine(in: state)
            let id = machine.currentAttempt!.id
            let result = machine.fault(id, reason: "the input device changed")

            #expect(!result.injects, "\(state): a capture fault injected")
            if state == .injecting {
                // Keystrokes are already going in; there is nothing left to discard and nothing
                // truthful to announce (D20's reasoning, arriving from the other direction).
                #expect(result.outcome == .noop)
            } else {
                #expect(result.outcome == .accepted)
                #expect(machine.state == .idle)
                #expect(result.notifications == ["the input device changed"],
                        "\(state): the fault was not reported as itself")
            }
        }
    }

    @Test("a fault is never reported as silence")
    func faultIsNotSilence() {
        // Invariant 7. A fault while STOPPING is the row most likely to be mistaken for an empty
        // dictation, so it is the one asserted here: the reason reaches the user verbatim, and the
        // machine never substitutes its own "nothing was recognised".
        var machine = Self.draining()
        let id = machine.currentAttempt!.id
        let result = machine.fault(id, reason: "capture failed while stopping")

        #expect(result.notifications == ["capture failed while stopping"])
        #expect(result.effects.contains(.discardCapture(id)))
        #expect(!result.injects)

        var empty = Self.machine(in: .processing)
        let emptyID = empty.currentAttempt!.id
        let silence = empty.recognised(emptyID, .empty)
        #expect(silence.notifications != result.notifications,
                "silence and a hardware fault must not read the same")
    }

    @Test("a fault in idle is a silent no-op")
    func faultInIdle() {
        var machine = StateMachine()
        let result = machine.fault(1, reason: "nothing is running")

        #expect(result.outcome == .noop)
        #expect(result.effects.isEmpty)
    }

    // MARK: - the happy path, and what it announces when

    @Test("nothing is announced before capture confirms it is running")
    func nothingAnnouncedBeforeCaptureConfirms() {
        var machine = StateMachine()
        let started = machine.start(target: Self.target, at: Self.t0)
        // D13: announcing at keypress trains the user to speak before audio flows and lose the
        // first syllable every time.
        #expect(started.isSilent)

        let ready = machine.captureReady(1)
        #expect(ready.announcements == [.listening])
        #expect(machine.state == .recording)
    }

    @Test("a whole clean attempt runs idle to idle, announcing in order")
    func cleanPath() {
        var machine = StateMachine()
        var announced: [Feedback] = []

        announced += machine.start(target: Self.target, at: Self.t0).announcements
        announced += machine.captureReady(1).announcements
        announced += machine.stop(mode: .clean).announcements
        announced += machine.captureDrained(1).announcements
        let recognised = machine.recognised(1, .text)
        announced += recognised.announcements
        #expect(recognised.effects == [.inject(1, Self.target)])
        announced += machine.injectionFinished(1, .delivered).announcements

        #expect(announced == [.listening, .working, .done])
        #expect(machine.state == .idle)
    }

    @Test("recognition failing or coming back empty ends the attempt without injecting")
    func recognitionOutcomes() {
        for result in [RecognitionResult.empty, .failed(reason: "the model is unavailable")] {
            var machine = Self.machine(in: .processing)
            let id = machine.currentAttempt!.id
            let transition = machine.recognised(id, result)

            #expect(transition.outcome == .accepted)
            #expect(machine.state == .idle)
            #expect(!transition.injects)
            #expect(transition.announcements == [.blocked])
            #expect(transition.notifications.count == 1)
        }
    }

    @Test("a delivery failure is announced as blocked, and never retried by the machine")
    func deliveryFailure() {
        for result in [InjectionResult.failed(reason: "the target is gone"),
                       .partial(reason: "the insertion may be partial")] {
            var machine = Self.machine(in: .injecting)
            let id = machine.currentAttempt!.id
            let transition = machine.injectionFinished(id, result)

            #expect(machine.state == .idle)
            #expect(transition.announcements == [.blocked])
            #expect(!transition.injects, "the machine must never re-emit an injection")
        }
    }

    @Test("the target captured at start is the one carried to injection")
    func targetIsNeverSubstituted() {
        // D4: wandering to another session mid-sentence must not redirect the text. The machine
        // holds one target from `start` and hands back exactly that one at injection time.
        var machine = StateMachine()
        _ = machine.start(target: Self.target, at: Self.t0)
        _ = machine.captureReady(1)
        _ = machine.start(target: Self.otherTarget, at: Self.t0)
        _ = machine.stop(mode: .clean)
        _ = machine.captureDrained(1)

        #expect(machine.recognised(1, .text).effects == [.inject(1, Self.target)])
    }
}

/// One command applied to a machine, so the sweeps above can run all three over all five states.
struct Probe: Sendable {
    let name: String
    let apply: @Sendable (inout StateMachine) -> Transition

    static let all: [Probe] = [
        Probe(name: "start") { $0.start(target: StateMachineTests.otherTarget,
                                        at: StateMachineTests.t0) },
        Probe(name: "stop") { $0.stop(mode: .clean) },
        Probe(name: "abort") { $0.abort() },
    ]
}

extension Transition {
    var announcements: [Feedback] {
        effects.compactMap { if case let .announce(feedback) = $0 { feedback } else { nil } }
    }

    var notifications: [String] {
        effects.compactMap { if case let .notify(message) = $0 { message } else { nil } }
    }

    var injects: Bool { effects.contains { $0.isInjection } }

    /// Nothing the user can see or hear came out of this transition.
    var isSilent: Bool { announcements.isEmpty && notifications.isEmpty }
}
