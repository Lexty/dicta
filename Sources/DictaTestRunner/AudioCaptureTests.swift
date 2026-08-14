import AVFoundation
import DictaCore
import DictaRuntime
import Foundation
import Testing

/// The real microphone, tested at the two boundaries a test can actually reach.
///
/// What cannot be asserted here is deliberately absent rather than faked: no test opens an input
/// device, because a machine with no microphone, no TCC grant or a headset already in use would
/// produce three different failures that say nothing about this code. What IS asserted is
/// everything that decides an attempt's fate before or after the device is involved:
///
///   • the conversion, over a buffer synthesised in memory: rate, channels and sample values;
///   • `drainOutcome`, which is where invariant 7 either holds or does not;
///   • the denied path, which must fault BEFORE the engine is touched;
///   • the words the user reads, which invariant 7 constrains as much as the behaviour does.
///
/// The rest -- that `.ready` follows `engine.start()`, that a route change ends a live attempt --
/// is in `docs/manual-checklist.md`, where a human unplugs something.
@Suite("audio capture")
struct AudioCaptureTests {
    // MARK: - conversion (D10, §12: 16 kHz mono float, and nothing else)

    /// A buffer of constant amplitude at the given rate, in the shape a real input tap hands over:
    /// non-interleaved float, one or two channels.
    static func buffer(value: Float, frames: AVAudioFrameCount, rate: Double,
                       channels: AVAudioChannelCount) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: rate,
                                                channels: channels,
                                                interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try #require(buffer.floatChannelData)
        for channel in 0 ..< Int(channels) {
            for frame in 0 ..< Int(frames) { data[channel][frame] = value }
        }
        return buffer
    }

    static func converter(from rate: Double, channels: AVAudioChannelCount)
        throws -> (AVAudioConverter, AVAudioFormat) {
        let input = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                               channels: channels, interleaved: false))
        let output = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: Audio.requiredSampleRate,
                                                channels: 1, interleaved: false))
        return (try #require(AVAudioConverter(from: input, to: output)), output)
    }

    @Test("48 kHz stereo becomes 16 kHz mono, at a third of the frames and the same amplitude")
    func convertsToSixteenKilohertzMono() throws {
        let (converter, output) = try Self.converter(from: 48_000, channels: 2)
        let input = try Self.buffer(value: 0.5, frames: 4_800, rate: 48_000, channels: 2)

        let samples = try #require(AudioCapture.convert(input, with: converter, to: output))

        #expect(output.sampleRate == Audio.requiredSampleRate)
        #expect(output.channelCount == 1)
        // A third of 4800, minus the resampler's priming -- measured at 240 frames here, and
        // asserted as a range rather than an equality because that priming is CoreAudio's business
        // and pinning it would make this test a report on the OS version. It is also why the tap's
        // converter is created once per attempt and never reset: paying it per buffer would drop a
        // fifteenth of a second of speech at every seam.
        #expect((1_320 ... 1_610).contains(samples.count))
        // The signal survives: a converter that returned silence would still satisfy every
        // structural assertion above, and would lose every dictation.
        let settled = samples.dropFirst(200)
        #expect(!settled.isEmpty)
        for sample in settled {
            #expect(abs(sample - 0.5) < 0.05)
        }

        // What the seam then carries. `Audio` states its own rate so a converter bug is an
        // assertion rather than an assumption.
        let audio = Audio(samples: samples, sampleRate: Audio.requiredSampleRate)
        #expect(audio.sampleRate == 16_000)
        #expect(abs(audio.duration - 0.1) < 0.02)
    }

    @Test("a buffer already at 16 kHz mono passes through frame for frame")
    func convertsIdentity() throws {
        let (converter, output) = try Self.converter(from: 16_000, channels: 1)
        let input = try Self.buffer(value: -0.25, frames: 1_600, rate: 16_000, channels: 1)

        let samples = try #require(AudioCapture.convert(input, with: converter, to: output))

        #expect(samples.count == 1_600)
        #expect(samples.allSatisfy { abs($0 + 0.25) < 0.001 })
    }

    @Test("consecutive tap buffers keep converting, so a long dictation is not one buffer long")
    func convertsSuccessiveBuffers() throws {
        // The converter is created once per attempt and reused, so its resampler state carries
        // across tap callbacks. A converter reset between buffers would click at every seam.
        let (converter, output) = try Self.converter(from: 44_100, channels: 1)
        var total = 0
        for _ in 0 ..< 10 {
            let input = try Self.buffer(value: 0.1, frames: 4_410, rate: 44_100, channels: 1)
            total += try #require(AudioCapture.convert(input, with: converter, to: output)).count
        }

        // Ten tenths of a second at 16 kHz, minus at most the priming of the first buffer.
        #expect((15_500 ... 16_100).contains(total))
    }

    // MARK: - what a drain decides (invariant 7)

    @Test("a fault while stopping wins over the samples already in hand")
    func drainReportsTheFaultNotSilence() {
        // §7's row, and the one most likely to be mistaken for an empty dictation: the device died
        // holding half a sentence, and handing that half over would inject a truncated prompt --
        // while handing over nothing would announce "nothing was recognised" at a user who spoke.
        let outcome = AudioCapture.drainOutcome(
            fault: (kind: .hardware, reason: FaultReason.deviceChanged),
            samples: [0.1, 0.2, 0.3],
            engineRunning: true
        )

        #expect(outcome == .fault(kind: .hardware, reason: FaultReason.deviceChanged))
    }

    @Test("an engine that stopped by itself is a fault, even with a full buffer")
    func drainReportsADeadEngine() {
        let outcome = AudioCapture.drainOutcome(fault: nil, samples: Array(repeating: 0.2,
                                                                          count: 16_000),
                                                engineRunning: false)

        #expect(outcome == .fault(kind: .hardware, reason: FaultReason.engineStopped))
    }

    @Test("a healthy engine hands over its samples at 16 kHz")
    func drainHandsOverAudio() {
        let outcome = AudioCapture.drainOutcome(fault: nil, samples: [0.1, -0.1],
                                                engineRunning: true)

        #expect(outcome == .audio(Audio(samples: [0.1, -0.1], sampleRate: 16_000)))
    }

    @Test("a healthy engine with no samples is a real, empty dictation and not a fault")
    func drainOfSilenceIsNotAFault() {
        // The other half of invariant 7: it forbids reporting a FAILURE as silence, not reporting
        // silence as silence. A chord pressed twice in a second is an empty dictation, and §7 has
        // a row for it -- no injection, notify "empty".
        let outcome = AudioCapture.drainOutcome(fault: nil, samples: [], engineRunning: true)

        #expect(outcome == .audio(Audio(samples: [], sampleRate: 16_000)))
    }

    // MARK: - the microphone grant (§6: "coming up" vs "ready" vs "denied")

    @Test("TCC's answers map onto ours, with restricted folded into denied")
    func accessMapping() {
        #expect(MicrophoneAccess(.authorized) == .granted)
        #expect(MicrophoneAccess(.denied) == .denied)
        #expect(MicrophoneAccess(.restricted) == .denied)
        #expect(MicrophoneAccess(.notDetermined) == .undetermined)
    }

    @Test("a denied microphone faults immediately and never announces readiness")
    func deniedFaultsWithoutOpeningTheDevice() throws {
        // Before the engine is touched: opening a denied device yields a running engine feeding
        // silence, and the attempt would be announced as listening and then reported as empty --
        // invariant 4 and invariant 7 broken by one missing check.
        let capture = AudioCapture(access: { .denied })
        let events = Events()

        capture.begin(attempt: 1) { events.append($0) }

        let event = try #require(events.all.first)
        #expect(events.all.count == 1)
        guard case let .fault(id, kind, reason) = event else {
            Issue.record("a denied microphone must fault, not report readiness: \(event)")
            return
        }
        #expect(id == 1)
        #expect(kind == .denied)
        #expect(reason == FaultReason.denied)
        #expect(reason.contains("System Settings"))
    }

    @Test("an ungranted microphone faults with the grant as its reason, not the hardware")
    func undeterminedFaultsWithItsOwnWords() throws {
        let capture = AudioCapture(access: { .undetermined })
        let events = Events()

        capture.begin(attempt: 2) { events.append($0) }

        guard case let .fault(_, kind, reason) = try #require(events.all.first) else {
            Issue.record("an ungranted microphone must fault")
            return
        }
        #expect(kind == .denied)
        #expect(reason == FaultReason.undetermined)
        // Not "the microphone did not start", which would send the user looking at their hardware.
        #expect(!reason.contains("did not start"))
    }

    @Test("draining or discarding an attempt that never began does nothing at all")
    func unknownAttemptsAreIgnored() {
        // The daemon discards on every cancelling path, including ones where capture never opened
        // (a fault during `warming`). A capture that crashed on those would turn one lost dictation
        // into a dead daemon.
        //
        // "Nothing at all" is asserted, not merely survived: this used to be three statements and
        // no `#expect`, so it passed unless the process crashed -- and with `.denied` no recording
        // is ever created, so it exercised only the nil-guard. A real attempt is opened first,
        // and the point is that the unrelated ids neither touch it nor produce an event of their
        // own.
        let events = Events()
        let capture = AudioCapture(access: { .denied })
        capture.begin(attempt: 1) { events.append($0) }
        #expect(events.all.count == 1, "the denied attempt reports its own fault, once")

        capture.drain(attempt: 99)
        capture.discard(attempt: 99)

        #expect(events.all.count == 1, "an id capture never opened must produce no event")
        // And the live-attempt bookkeeping is untouched: attempt 1's own drain still finds nothing
        // left to report, because its fault already consumed the one-shot sink.
        capture.drain(attempt: 1)
        #expect(events.all.count == 1)
    }

    // MARK: - the words (invariant 7, §7)

    @Test("no capture fault can be read as silence")
    func faultReasonsNeverSoundLikeSilence() {
        // The failure this forbids is a real one: a fault worded "nothing was recognised" is
        // indistinguishable from a quiet room, and the user retypes their sentence instead of
        // plugging their headset back in.
        for reason in FaultReason.all {
            #expect(!reason.isEmpty)
            let lower = reason.lowercased()
            #expect(!lower.contains("nothing was recognised"))
            #expect(!lower.contains("silence"))
            #expect(!lower.contains("empty"))
            // Every one of them says what became of the recording, so the user is never left
            // wondering whether the text is somewhere.
            #expect(lower.contains("discarded") || lower.contains("nothing was recorded")
                || lower.contains("microphone"))
        }
    }

    @Test("the cap's words name the limit, so the user can attribute it")
    func capReasonNamesTheLimit() {
        #expect(FaultReason.durationCap.contains("ten-minute"))
        #expect(FaultReason.durationCap.contains("nothing was typed"))
    }

    @Test("every fault kind is one of the three §2 draws")
    func faultKindsAreClosed() {
        // A fourth kind would have to decide its own §9 outcome, and the daemon's mapping is
        // `durationCap → capped`, everything else → `capture-fault`. This is the reminder.
        #expect(Set(FaultKind.allCases) == [.hardware, .denied, .durationCap])
        #expect(FaultKind.durationCap.rawValue == "duration-cap")
    }

    // MARK: - the measurement script (§10 step 2a)

    static var measureScript: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Sources/DictaTestRunner
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // the repository root
            .appendingPathComponent("Scripts/measure.sh")
    }

    static func measureLines() throws -> [[String]] {
        let text = try String(contentsOf: measureScript, encoding: .utf8)
        // Lines that INVOKE the client, rather than lines that merely mention the variable: a
        // `[ -x "$DICTACTL" ]` guard is not an invocation and has no verb to check.
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("\"$DICTACTL\" ") }
            .map { line in
                line.split(separator: " ").map(String.init)
                    .dropFirst()
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            }
    }

    @Test("every verb and flag measure.sh invokes is one this build has")
    func measureScriptDoesNotDrift() throws {
        // The same anti-drift argument as the keymap snippet: a renamed flag turns the measurement
        // into a row of usage errors, and step 2's criterion (a) would be scored from a script that
        // never started a dictation.
        let invocations = try Self.measureLines()
        #expect(!invocations.isEmpty, "measure.sh invokes no client at all")
        for invocation in invocations {
            let verb = try #require(invocation.first)
            #expect(ClientCommand.verbs.contains(verb), "measure.sh calls unknown verb \(verb)")
            for flag in invocation.filter({ $0.hasPrefix("--") }) {
                #expect(ClientCommand.usage.contains(flag), "measure.sh passes unknown \(flag)")
            }
        }
    }

    @Test("measure.sh ends every criterion-(a) attempt with abort, typing nothing into a pane")
    func measureScriptNeverDelivers() throws {
        // Delivering per attempt would leave ten lines of transcript in the user's input line, and
        // step 2a would have cost step 1's invariant to score.
        let verbs = try Self.measureLines().compactMap(\.first)
        #expect(verbs.contains("abort"))
        // Criterion (c) has a `stop` of its own -- it cannot be measured without delivering, since
        // the interval ends at the last keystroke. What is asserted here is that it is not what a
        // bare `measure.sh` does.
        #expect(verbs.contains("stop"))
        let text = try String(contentsOf: Self.measureScript, encoding: .utf8)
        #expect(text.contains("STOP_LATENCY=0"), "criterion (c) must be off by default")
        #expect(text.contains("--stop)"), "criterion (c) must be reachable, and only on request")
    }

    // MARK: - a collector the audio thread could safely use

    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [CaptureEvent] = []

        func append(_ event: CaptureEvent) { lock.withLock { events.append(event) } }
        var all: [CaptureEvent] { lock.withLock { events } }
    }
}
