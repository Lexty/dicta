import AVFoundation
import AppKit
import DictaCore
import Foundation

// The microphone, behind the `Capture` seam.
//
// Everything here is in service of two rules that are easy to state and easy to break:
//
//   • **Nothing is announced before the engine is actually running** (D13, invariant 4). `.ready`
//     is emitted after `engine.start()` has returned AND `engine.isRunning` is true -- not when the
//     chord arrived, and not when the tap was installed. Announcing earlier trains the user to
//     speak into an engine that is not yet listening and lose the first syllable every time.
//   • **A capture failure is never reported as silence** (invariant 7, §7). The dangerous shape is
//     a drain that hands back the zero samples it happens to hold after the device went away: that
//     reaches the recogniser, comes back empty, and is announced as "nothing was recognised" -- a
//     hardware fault wearing the costume of a quiet room. `drainOutcome` is where that is refused,
//     and it is a static function precisely so it can be tested without a device.
//
// Audio lives in RAM and nowhere else (D14): no segmentation, no disk journal, no recovery pass.
// Ten minutes at 16 kHz mono float is ~38 MB, and losing an utterance costs one keypress.

/// Whether TCC has granted the microphone (§6's third answer, next to "coming up" and "ready").
public enum MicrophoneAccess: String, Sendable, Equatable, CaseIterable {
    /// dicta may open the device.
    case granted
    /// Denied or restricted. The remedy is System Settings, and the user has to be told that rather
    /// than being handed a generic hardware fault.
    case denied
    /// Nobody has been asked yet. The prompt belongs to the daemon's signed bundle (D11), and it is
    /// asked for at startup rather than in the middle of a chord.
    case undetermined

    /// AVFoundation's word for it, in ours. `restricted` folds into `denied`: the user cannot grant
    /// it either way, and a fourth value would only make the caller repeat this decision.
    public init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .granted
        case .denied, .restricted: self = .denied
        case .notDetermined: self = .undetermined
        @unknown default: self = .undetermined
        }
    }

    /// What TCC says right now. Cheap, and asked freshly every time: a grant can be revoked in
    /// System Settings while the daemon is resident.
    public static var current: MicrophoneAccess {
        MicrophoneAccess(AVCaptureDevice.authorizationStatus(for: .audio))
    }
}

/// The words the user reads when capture fails, in one place.
///
/// Collected here rather than written at each call site so that invariant 7 is checkable as a
/// property of a list -- `AudioCaptureTests` asserts that not one of them can be read as silence.
/// Every one of them says what happened to the recording, because a fault that does not mention the
/// lost audio invites the user to look for text that no longer exists.
public enum FaultReason {
    public static let deviceChanged =
        "the audio device or route changed -- the recording was discarded"
    public static let wentToSleep =
        "the machine went to sleep -- the recording was discarded"
    public static let engineStopped =
        "the capture engine stopped -- the recording was discarded"
    public static let conversionFailed =
        "the audio could not be converted to 16 kHz mono -- the recording was discarded"
    public static let noUsableFormat =
        "the input device offers no usable audio format -- nothing was recorded"
    public static let denied =
        "the microphone is denied to dicta -- grant it in System Settings > Privacy & Security"
    public static let undetermined =
        "the microphone has not been granted to dicta yet -- allow it, then press the chord again"
    /// D15. The limit is named in the text: a fault the user cannot attribute is one they will
    /// blame on the recogniser.
    public static let durationCap =
        "the recording reached dicta's ten-minute limit -- it was discarded and nothing was typed"

    public static func didNotStart(_ detail: String) -> String {
        "the microphone did not start: \(detail) -- nothing was recorded"
    }

    /// Everything a test can enumerate. `didNotStart` is covered by a sample, since its shape
    /// rather than its detail is what invariant 7 constrains.
    public static var all: [String] {
        [deviceChanged, wentToSleep, engineStopped, conversionFailed, noUsableFormat, denied,
         undetermined, durationCap, didNotStart("the device is in use")]
    }
}

/// AVAudioEngine's input tap, converted to the one shape the pipeline accepts.
public final class AudioCapture: Capture, @unchecked Sendable {
    /// How TCC is consulted. Injected so the denied path -- which must fault BEFORE the engine is
    /// touched -- is drivable in a test on a machine that has granted the microphone.
    public typealias AccessProbe = @Sendable () -> MicrophoneAccess

    /// What a drain found. `audio` with no samples is legitimate: a chord pressed twice in quick
    /// succession is a real, empty dictation, and the pipeline calls that "empty" (§7). What is
    /// not legitimate is reaching that case with a fault in hand.
    public enum DrainOutcome: Sendable, Equatable {
        case audio(Audio)
        case fault(kind: FaultKind, reason: String)
    }

    /// One attempt's engine, tap and buffer. A class because the tap block runs on the audio thread
    /// and appends to it from there.
    private final class Recording: @unchecked Sendable {
        let attempt: AttemptID
        let sink: CaptureEventSink
        let engine: AVAudioEngine
        let converter: AVAudioConverter
        let output: AVAudioFormat

        private let lock = NSLock()
        /// Grown from a reservation rather than from nothing, because `absorb` runs **on the audio
        /// thread**: every reallocation there is a malloc and a copy of everything recorded so far,
        /// on a thread where a stall is an audible glitch. A minute of 16 kHz mono float is under
        /// 4 MB and covers the overwhelming majority of dictations in one allocation; a longer one
        /// still grows, but a handful of times rather than dozens. Reserving D15's whole ten-minute
        /// cap would mean 38 MB up front for every two-sentence prompt, which is the worse trade.
        private var samples: [Float] = {
            var reserved = [Float]()
            reserved.reserveCapacity(Int(Audio.requiredSampleRate) * 60)
            return reserved
        }()
        private var fault: (kind: FaultKind, reason: String)?
        /// Whether a terminal event has already left through the sink. One attempt reports exactly
        /// once: a route change that arrives while the drain is running must not turn into a second
        /// event for an attempt the daemon has already finished with.
        private var reported = false
        var observers: [any NSObjectProtocol] = []

        init(attempt: AttemptID, sink: @escaping CaptureEventSink, engine: AVAudioEngine,
             converter: AVAudioConverter, output: AVAudioFormat) {
            self.attempt = attempt
            self.sink = sink
            self.engine = engine
            self.converter = converter
            self.output = output
        }

        /// Called from the audio thread. Keeps the converter's resampler state across buffers, so
        /// the seams between tap callbacks do not click.
        /// `false` when the buffer could not be converted, which the caller escalates: the fault is
        /// no longer merely parked for the drain to find. A converter that starts failing mid-
        /// utterance leaves the user speaking into a recording that is already dead, and the rule
        /// this file states -- the audio dies immediately, so they hear about it while still
        /// speaking -- held only for the notification-driven half of the faults.
        @discardableResult
        func absorb(_ buffer: AVAudioPCMBuffer) -> Bool {
            guard let converted = AudioCapture.convert(buffer, with: converter, to: output) else {
                return false
            }
            lock.withLock { samples.append(contentsOf: converted) }
            return true
        }

        /// First fault wins: the interesting one is what went wrong first, and a route change that
        /// also stops the engine would otherwise overwrite its own cause. The answer says whether
        /// THIS call is the one that won, so the escalation happens exactly once however many
        /// buffers or notifications report the same broken device.
        @discardableResult
        func recordFault(_ kind: FaultKind, _ reason: String) -> Bool {
            lock.withLock {
                guard fault == nil else { return false }
                fault = (kind, reason)
                return true
            }
        }

        var pendingFault: (kind: FaultKind, reason: String)? { lock.withLock { fault } }

        var collected: [Float] { lock.withLock { samples } }

        /// Hands out the sink exactly once, so every route out of an attempt is a single event.
        func claimSink() -> CaptureEventSink? {
            lock.withLock {
                guard !reported else { return nil }
                reported = true
                return sink
            }
        }

        /// `.ready` is not a terminal event, so it must NOT consume the one-shot sink -- but it
        /// still must not fire for an attempt that has already faulted its way out of existence.
        func sinkForReady() -> CaptureEventSink? {
            lock.withLock { fault == nil && !reported ? sink : nil }
        }
    }

    private let lock = NSLock()
    private let probe: AccessProbe
    /// At most one, because there is one microphone: the state machine refuses a second start while
    /// the first attempt still owns the device (§8.9), and this is that rule's other half.
    private var live: Recording?
    /// The last attempt a `discard` asked for and did not find live.
    ///
    /// `begin` does several AVFoundation calls before it can register anything -- `inputNode` alone
    /// can block on a wedged CoreAudio HAL -- and the discard that ends an attempt is reached from
    /// threads that do not wait for it. Two of them are ordinary: `abort` is the one verb the
    /// control socket serves concurrently (`Command.isServedConcurrently`), and the warm-up
    /// watchdog is armed by `sync` BEFORE `.beginCapture` is performed, so the discard it fires
    /// outruns the begin it belongs to -- which is precisely the wedged-device case the watchdog
    /// exists for. A discard that found nothing used to return silently and leave `begin` free to
    /// start the engine afterwards: the microphone held open for the life of the daemon, with the
    /// orange indicator lit, for an attempt that was already over.
    private var cancelled: AttemptID?

    public init(access probe: @escaping AccessProbe = { MicrophoneAccess.current }) {
        self.probe = probe
    }

    /// The TCC answer as of now -- what `Dicta`'s startup logs so a denied microphone is visible
    /// before the first chord rather than during it.
    public var access: MicrophoneAccess { probe() }

    /// Asks for the microphone, so the prompt appears at daemon start rather than mid-dictation.
    /// Answers nothing: the grant is observed through `access`, and the daemon must not wait on a
    /// dialog the user may take a minute to read.
    public func requestAccessIfNeeded(_ answered: (@Sendable (MicrophoneAccess) -> Void)? = nil) {
        guard probe() == .undetermined else {
            answered?(probe())
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            answered?(granted ? .granted : .denied)
        }
    }

    // MARK: - the seam

    public func begin(attempt: AttemptID, sink: @escaping CaptureEventSink) {
        switch probe() {
        case .denied:
            // Before the engine is touched, deliberately: opening a denied device yields a running
            // engine feeding silence, which is invariant 7's failure exactly.
            sink(.fault(attempt, kind: .denied, reason: FaultReason.denied))
            return
        case .undetermined:
            // The prompt is asked for, and this attempt still ends. Waiting would hold `warming`
            // until the user reads a dialog, and the watchdog would fault it anyway -- with a
            // reason that named the hardware rather than the grant.
            requestAccessIfNeeded()
            sink(.fault(attempt, kind: .denied, reason: FaultReason.undetermined))
            return
        case .granted:
            break
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            sink(.fault(attempt, kind: .hardware, reason: FaultReason.noUsableFormat))
            return
        }
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Audio.requiredSampleRate,
                                         channels: 1,
                                         interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: output)
        else {
            sink(.fault(attempt, kind: .hardware, reason: FaultReason.conversionFailed))
            return
        }

        let recording = Recording(attempt: attempt, sink: sink, engine: engine,
                                  converter: converter, output: output)
        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) {
            [weak self, weak recording] buffer, _ in
            guard let recording, !recording.absorb(buffer) else { return }
            self?.escalate(recording, kind: .hardware, reason: FaultReason.conversionFailed)
        }
        observe(recording)
        lock.withLock { live = recording }

        do {
            try engine.start()
        } catch {
            fault(recording, kind: .hardware, reason: FaultReason.didNotStart("\(error)"))
            return
        }
        guard engine.isRunning else {
            fault(recording, kind: .hardware, reason: FaultReason.engineStopped)
            return
        }
        // The device is confirmed ours only HERE, and not at the registration above: a discard can
        // arrive at any point inside this function, and the two windows fail differently. Before
        // the registration it finds nothing and returns silently; after it, it takes the recording
        // and tears down an engine that has not started yet. Either way the engine below would go
        // on running with nobody holding it -- so ownership is re-asserted once the engine is up,
        // which is the only point at which both windows are behind us.
        guard claimStarted(recording) else {
            tearDown(recording)
            // The sink is consumed rather than used: the attempt is over, and `.ready` for an
            // attempt the daemon has already ended is an event whose only correct handling is to
            // be ignored.
            _ = recording.claimSink()
            return
        }
        // Only now (D13, invariant 4): the engine is running and the tap is delivering.
        recording.sinkForReady()?(.ready(attempt))
    }

    /// Whether the recording whose engine has just started still owns the microphone.
    ///
    /// Clears `live` when it does not, so a recording that lost the race leaves nothing behind it.
    private func claimStarted(_ recording: Recording) -> Bool {
        lock.withLock {
            guard Self.retainsDevice(isRegistered: live === recording,
                                     wasCancelled: cancelled == recording.attempt)
            else {
                if live === recording { live = nil }
                return false
            }
            return true
        }
    }

    /// The rule `claimStarted` applies, as a value.
    ///
    /// Pure, and separated from the engine for the reason `drainOutcome` is: producing this race
    /// needs a granted microphone and a second thread inside `AVAudioEngine.start()`, and a rule
    /// that can only be exercised by winning a race is a rule with no test. `isRegistered` is false
    /// for a discard that took the recording back out; `wasCancelled` is true for one that arrived
    /// before there was anything to take.
    public static func retainsDevice(isRegistered: Bool, wasCancelled: Bool) -> Bool {
        isRegistered && !wasCancelled
    }

    public func drain(attempt: AttemptID) {
        guard let recording = take(attempt) else { return }
        // `isRunning` is read BEFORE stopping, because `engine.stop()` would make every drain look
        // like a dead engine. The samples are read AFTER, and that is the other half of the same
        // rule: `collected` copies the whole buffer under the lock, and the tap goes on appending
        // to the array that has already been copied for as long as the engine runs. Snapshotting
        // first therefore dropped up to one tap buffer of the END of the utterance -- ~85 ms, and
        // more often the longer the dictation, since the copy grows with it. `stop()` returns once
        // the render thread has quiesced, so nothing arrives after it. The fault moves with the
        // samples: a fault raised during the tail belongs to the audio that carried it (D16).
        let wasRunning = recording.engine.isRunning
        tearDown(recording)
        let fault = recording.pendingFault
        let samples = recording.collected

        switch Self.drainOutcome(fault: fault, samples: samples, engineRunning: wasRunning) {
        case let .audio(audio):
            recording.claimSink()?(.drained(attempt, audio))
        case let .fault(kind, reason):
            recording.claimSink()?(.fault(attempt, kind: kind, reason: reason))
        }
    }

    public func discard(attempt: AttemptID) {
        guard let recording = take(attempt) else {
            // Parked rather than dropped (see `cancelled`): this discard may have outrun the
            // `begin` it belongs to, and the begin still on its way up has to be able to find out
            // that the attempt it is opening the microphone for is already over. An id capture
            // never opened parks harmlessly -- ids are issued once and never reused.
            lock.withLock { cancelled = attempt }
            return
        }
        tearDown(recording)
        // Silently, and with the audio dropped on the floor: a discard is the daemon having already
        // decided the attempt is over, so an event here would only be something to ignore.
        _ = recording.claimSink()
    }

    // MARK: - the decision a drain makes

    /// Whether a drain hands over audio or a fault. Pure, and separated from the engine for one
    /// reason: this is where invariant 7 either holds or does not, and a rule that can only be
    /// exercised by unplugging a microphone mid-sentence is a rule with no test.
    public static func drainOutcome(fault: (kind: FaultKind, reason: String)?,
                                    samples: [Float],
                                    engineRunning: Bool) -> DrainOutcome {
        if let fault {
            // Even with samples in hand. §7's "capture fails while stopping" row is the one most
            // likely to be mistaken for an empty dictation, and the audio's boundary is in doubt
            // whatever arrived before the fault (D16).
            return .fault(kind: fault.kind, reason: fault.reason)
        }
        guard engineRunning else {
            return .fault(kind: .hardware, reason: FaultReason.engineStopped)
        }
        // Zero samples from a healthy engine is a real, empty dictation -- the one case where
        // "nothing was recognised" is the truth (§7).
        return .audio(Audio(samples: samples, sampleRate: Audio.requiredSampleRate))
    }

    // MARK: - conversion

    /// One tap buffer at the input device's rate to mono 16 kHz float samples.
    ///
    /// The block form is not optional: a converter that changes the sample rate cannot be driven by
    /// `convert(to:from:)`, and asking it to would fail at runtime rather than at compile time.
    public static func convert(_ buffer: AVAudioPCMBuffer,
                               with converter: AVAudioConverter,
                               to output: AVAudioFormat) -> [Float]? {
        let ratio = output.sampleRate / buffer.format.sampleRate
        // The resampler holds a few frames of its own, so the headroom is not decoration.
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard capacity > 0,
              let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity)
        else { return nil }

        // The input block is declared `@Sendable`, and AVAudioPCMBuffer is not `Sendable`. Boxing
        // the pair is the honest way to say what is true: the block is called synchronously, on
        // this thread, before `convert` returns -- there is no concurrency here to be unsafe about.
        final class Feed: @unchecked Sendable {
            let buffer: AVAudioPCMBuffer
            var offered = false
            init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        }
        let feed = Feed(buffer)
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if feed.offered {
                // One buffer per call: `noDataNow` ends this conversion rather than starving the
                // converter, which would reset its resampler state between tap callbacks.
                outStatus.pointee = .noDataNow
                return nil
            }
            feed.offered = true
            outStatus.pointee = .haveData
            return feed.buffer
        }
        guard status != .error, error == nil, let channel = converted.floatChannelData?[0] else {
            return nil
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
    }

    // MARK: - the faults the system reports

    /// The two notifications that mean the recording is no longer trustworthy (§7, D16).
    ///
    /// macOS has no `AVAudioSession`, so an interruption, an input device change and an AirPods
    /// route change all surface the same way: the engine's configuration changed underneath us.
    /// Sleep is separate, and arrives first on the way down.
    private func observe(_ recording: Recording) {
        let centre = NotificationCenter.default
        let configuration = centre.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: recording.engine,
            queue: nil
        ) { [weak self, weak recording] _ in
            guard let self, let recording else { return }
            escalate(recording, kind: .hardware, reason: FaultReason.deviceChanged)
        }
        let sleep = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self, weak recording] _ in
            guard let self, let recording else { return }
            escalate(recording, kind: .hardware, reason: FaultReason.wentToSleep)
        }
        recording.observers = [configuration, sleep]
    }

    /// A fault raised by something that must not be made to run the daemon's pipeline: a system
    /// notification, or the audio thread.
    ///
    /// Both observers above are registered with `queue: nil`, so their blocks run wherever the
    /// notification is posted -- and `willSleepNotification` is posted on the MAIN thread. What
    /// `fault` goes on to do is not small: it stops the engine, and then the sink runs the whole
    /// tail of the attempt inside the daemon -- discard, the `blocked` indicator, the notification
    /// -- which is up to four `agtermctl`/`osascript` subprocesses at `worstCaseCallSeconds` each.
    /// Doing that inline blocked the main run loop (and with it the SIGTERM/SIGINT sources) while
    /// the machine was suspending, and reconfigured the engine from inside the very configuration-
    /// change notification Apple says not to reconfigure from. From the tap it would be worse
    /// still: that is the render thread.
    ///
    /// Only `recordFault` stays synchronous, and deliberately -- a drain racing the notification
    /// must still see the fault, which is what makes the audio suspect rather than merely late.
    ///
    /// A real `Thread` rather than a queue, for the reason the control socket uses one: the
    /// subprocesses block, and Darwin's non-overcommit global pool does not grow when its threads
    /// do. One per escalation and no more -- `recordFault` answers whether this call is the one
    /// that won, so a device that fails on every buffer still spawns exactly one.
    private func escalate(_ recording: Recording, kind: FaultKind, reason: String) {
        guard recording.recordFault(kind, reason) else { return }
        let thread = Thread { [weak self] in
            guard let self, take(recording.attempt) != nil else { return }
            tearDown(recording)
            report(recording, kind: kind, reason: reason)
        }
        thread.name = "dev.personal.dicta.capture.fault"
        thread.start()
    }

    /// A fault that arrives while the attempt is live: the audio dies immediately rather than at
    /// the next drain, so the user hears about it while still speaking into a dead microphone.
    private func fault(_ recording: Recording, kind: FaultKind, reason: String) {
        recording.recordFault(kind, reason)
        guard take(recording.attempt) != nil else { return }
        tearDown(recording)
        report(recording, kind: kind, reason: reason)
    }

    private func report(_ recording: Recording, kind: FaultKind, reason: String) {
        recording.claimSink()?(.fault(recording.attempt, kind: kind, reason: reason))
    }

    private func take(_ attempt: AttemptID) -> Recording? {
        lock.withLock {
            guard let recording = live, recording.attempt == attempt else { return nil }
            live = nil
            return recording
        }
    }

    /// Idempotent: `drain` and a route change can both reach it, and an engine stopped twice is
    /// cheaper than a branch that has to be right about which of them arrived first.
    private func tearDown(_ recording: Recording) {
        for observer in recording.observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        recording.observers = []
        if recording.engine.isRunning { recording.engine.stop() }
        recording.engine.inputNode.removeTap(onBus: 0)
    }
}
