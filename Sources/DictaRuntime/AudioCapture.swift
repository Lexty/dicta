import AVFoundation
import AppKit
import CoreAudio
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

/// Which input device a prepared engine was built against, and at what rate.
///
/// The whole point of building an engine ahead of the chord (see `Prepared`) is that the expensive
/// part happens while nobody is waiting. The whole risk of it is that the world moves in between:
/// AirPods connect, a dock is unplugged, the machine wakes up somewhere else. An engine built for a
/// device that is gone would either fail to start -- costing the user the dictation they just
/// spoke -- or, worse, record at a format nobody checked.
///
/// This is the token that makes reuse decidable. It is read from CoreAudio rather than from the
/// engine, deliberately: `AVAudioEngine` publishes a configuration-change notification for a
/// RUNNING engine, and a prepared engine is by definition not running, so the notification is not a
/// guarantee available here. Two property reads are.
public struct InputDeviceIdentity: Equatable, Sendable {
    public let deviceID: UInt32
    public let sampleRate: Double

    public init(deviceID: UInt32, sampleRate: Double) {
        self.deviceID = deviceID
        self.sampleRate = sampleRate
    }

    /// The default input device as of now, or `nil` when CoreAudio would not say -- which is
    /// treated as "cannot verify" and therefore as "do not reuse".
    public static var current: InputDeviceIdentity? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &device) == noErr, device != kAudioObjectUnknown
        else { return nil }

        var rate = Double(0)
        size = UInt32(MemoryLayout<Double>.size)
        address.mSelector = kAudioDevicePropertyNominalSampleRate
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr,
              rate > 0
        else { return nil }
        return InputDeviceIdentity(deviceID: device, sampleRate: rate)
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
        /// Serialises `tearDown`, and guards `observers` with it.
        ///
        /// Its own lock rather than `lock`, and not merely for tidiness: teardown calls
        /// `engine.stop()`, which returns only once the render thread has quiesced -- and the
        /// render thread takes `lock` in `absorb`. Holding that one across `stop()` is a deadlock.
        let teardownLock = NSLock()
        /// **Guarded by `teardownLock`.** Two threads can reach `tearDown` for the same recording
        /// at once: a discard or a fault takes the recording and tears it down while `begin` is
        /// still blocked inside `engine.start()`, and `begin` tears it down again the moment that
        /// call returns (it must -- see `claimStarted`). Unsynchronised, that is one thread
        /// iterating this array while the other assigns over it.
        var observers: [any NSObjectProtocol] = []

        /// The box the installed tap reads this recording out of. Held strongly here and weakly by
        /// the tap block, which is what keeps `engine -> tap -> slot -> recording -> engine` from
        /// being a retain cycle.
        let slot: TapSlot

        init(attempt: AttemptID, sink: @escaping CaptureEventSink, engine: AVAudioEngine,
             converter: AVAudioConverter, output: AVAudioFormat, slot: TapSlot) {
            self.attempt = attempt
            self.sink = sink
            self.engine = engine
            self.converter = converter
            self.output = output
            self.slot = slot
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

    /// Which recording the installed tap is feeding, as a box.
    ///
    /// A tap installed ahead of the chord (see `Prepared`) cannot capture the attempt it will
    /// serve, because that attempt does not exist yet. It reads this instead, and finds `nil` in
    /// exactly the two windows where the right thing to do is drop the buffer: before an attempt
    /// has claimed the engine, and after teardown has detached it.
    private final class TapSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var recording: Recording?

        var current: Recording? { lock.withLock { recording } }
        func attach(_ recording: Recording) { lock.withLock { self.recording = recording } }
        func detach() { lock.withLock { recording = nil } }
    }

    /// An engine that is built, formatted and tapped -- and **not started**.
    ///
    /// This is the whole of the optimisation. Measured on this machine (2026-08-23), a chord spends
    /// ~29 ms in `engine.inputNode` and ~5 ms in `installTap` before it can spend ~39 ms in
    /// `engine.start()`; doing the first two ahead of time takes ~34 ms off the path between the
    /// keypress and a live microphone.
    ///
    /// What makes it allowed rather than merely faster: **none of those three calls starts the
    /// device.** Measured with a probe reading `kAudioDevicePropertyDeviceIsRunningSomewhere` on
    /// the default input -- `inputNode`, `installTap` and `prepare()` all leave it `false`, and
    /// only `start()` flips it to `true`. A prepared engine therefore lights no microphone
    /// indicator, which is the trade this project refuses to make (AGENTS.md, F4). Holding a
    /// *started* engine warm between attempts remains refused, and this is not that.
    ///
    /// Single use. A second `start()` on a STOPPED engine measured 104 ms against 41 ms on a fresh
    /// one, so nothing here is recycled: an attempt consumes its prepared engine and teardown asks
    /// for another.
    private final class Prepared: @unchecked Sendable {
        let engine: AVAudioEngine
        let converter: AVAudioConverter
        let output: AVAudioFormat
        let slot: TapSlot
        /// The device this was built against, read before the build began. `nil` means CoreAudio
        /// would not say, which `reusesPrepared` treats as a refusal rather than as a match.
        let identity: InputDeviceIdentity?

        init(engine: AVAudioEngine, converter: AVAudioConverter, output: AVAudioFormat,
             slot: TapSlot, identity: InputDeviceIdentity?) {
            self.engine = engine
            self.converter = converter
            self.output = output
            self.slot = slot
            self.identity = identity
        }
    }

    /// Why a preparation could not be built. Mapped onto the same two faults `begin` has always
    /// reported, so a chord that has to build inline fails exactly as it did before.
    private enum PrepareFailure: Error {
        case noUsableFormat
        case conversionFailed
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
    /// The engine waiting for the next chord, if one is ready. **Guarded by `lock`.**
    private var prepared: Prepared?
    /// Whether a preparation thread is running. **Guarded by `lock`.**
    private var preparing = false
    /// Bumped by every invalidation, so a preparation that was already in flight when the world
    /// moved underneath it is dropped on arrival rather than stored. **Guarded by `lock`.**
    private var preparedGeneration: UInt64 = 0
    private var sleepObserver: (any NSObjectProtocol)?

    public init(access probe: @escaping AccessProbe = { MicrophoneAccess.current }) {
        self.probe = probe
        // Sleep is the one event that a device token cannot catch: the machine wakes with the same
        // default input at the same rate, and an engine built before it went down may or may not
        // still be usable. Rather than find out on the first chord of the morning -- which is a
        // dictation the user has already spoken -- the prepared engine is dropped on the way down
        // and rebuilt on the way back. This observer is the process's, not an attempt's: the
        // per-recording sleep observer in `observe` faults a LIVE attempt, which is a different
        // question with a different answer.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.invalidatePrepared()
        }
    }

    deinit {
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
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

        // The prepared engine if one is ready and still describes the device that is actually
        // there, and otherwise exactly what this function used to do inline. The fallback is not a
        // degraded mode: it is the old path, unchanged, and it is what runs on the first chord
        // after a start, after a route change, and after a wake.
        let prepared: Prepared
        do {
            prepared = try claimPrepared() ?? buildPrepared()
        } catch PrepareFailure.noUsableFormat {
            sink(.fault(attempt, kind: .hardware, reason: FaultReason.noUsableFormat))
            return
        } catch {
            sink(.fault(attempt, kind: .hardware, reason: FaultReason.conversionFailed))
            return
        }

        let engine = prepared.engine
        let recording = Recording(attempt: attempt, sink: sink, engine: engine,
                                  converter: prepared.converter, output: prepared.output,
                                  slot: prepared.slot)
        // Before the engine starts, necessarily: the tap is already installed, so the slot is the
        // only thing standing between the first buffer and the recording it belongs to.
        prepared.slot.attach(recording)
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

    // MARK: - the engine built ahead of the chord

    /// Builds one now, so the first chord does not have to. Called at daemon start, once the
    /// microphone is known to be granted.
    ///
    /// Public because the daemon owns the decision of when to spend 34 ms of nobody's time; this
    /// type owns only what that time buys.
    public func prewarm() {
        prepareInBackground()
    }

    /// Whether a prepared engine may still be used, as a value.
    ///
    /// Pure, and separated from the engine for the same reason `drainOutcome` and `retainsDevice`
    /// are: the rule is what matters and a device cannot be unplugged inside a test. Unknown on
    /// either side is a refusal -- an engine we cannot prove belongs to the device in front of the
    /// user is one that gets thrown away, because the cost of being wrong is a dictation recorded
    /// from nowhere, and the cost of being needlessly careful is 34 ms.
    public static func reusesPrepared(prepared: InputDeviceIdentity?,
                                      current: InputDeviceIdentity?) -> Bool {
        guard let prepared, let current else { return false }
        return prepared == current
    }

    /// Takes the prepared engine if there is one and it still matches the device.
    private func claimPrepared() -> Prepared? {
        let candidate: Prepared? = lock.withLock {
            let taken = prepared
            prepared = nil
            return taken
        }
        guard let candidate else { return nil }
        guard Self.reusesPrepared(prepared: candidate.identity, current: .current) else {
            // The device moved while this was waiting. Nothing was started, so there is nothing to
            // stop -- only the tap to take back off a node that is about to be released.
            release(candidate)
            return nil
        }
        return candidate
    }

    /// Everything `begin` used to do before `engine.start()`, in one place, so that the inline path
    /// and the prepared one cannot drift apart.
    private func buildPrepared() throws -> Prepared {
        // Read BEFORE the build rather than after it: a device that changes while this is running
        // leaves a token that no longer matches, and the next claim throws the engine away. The
        // other order would record the world as it is at the end of a build that raced it.
        let identity = InputDeviceIdentity.current
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw PrepareFailure.noUsableFormat
        }
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Audio.requiredSampleRate,
                                         channels: 1,
                                         interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: output)
        else {
            throw PrepareFailure.conversionFailed
        }

        let slot = TapSlot()
        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) {
            [weak self, weak slot] buffer, _ in
            guard let recording = slot?.current, !recording.absorb(buffer) else { return }
            self?.escalate(recording, kind: .hardware, reason: FaultReason.conversionFailed)
        }
        return Prepared(engine: engine, converter: converter, output: output, slot: slot,
                        identity: identity)
    }

    /// Builds the next one on a thread of its own, if there is not one already.
    ///
    /// A real `Thread` for the reason everything else in this project uses one: this blocks in
    /// CoreAudio, and Darwin's non-overcommit global pool does not grow when its threads block.
    ///
    /// Nothing here is on any attempt's path, so a failure is silent on purpose: the chord that
    /// finds no prepared engine builds one inline and reports whatever goes wrong there, which is
    /// the behaviour this project had before any of this existed.
    private func prepareInBackground() {
        guard probe() == .granted else { return }
        let generation: UInt64? = lock.withLock {
            guard prepared == nil, !preparing else { return nil }
            preparing = true
            return preparedGeneration
        }
        guard let generation else { return }

        let thread = Thread { [weak self] in
            guard let self else { return }
            let built = try? buildPrepared()
            var orphan: Prepared?
            lock.withLock {
                preparing = false
                guard let built else { return }
                // The generation is the answer to "did the world move while this was building".
                // A sleep or a claim that bumped it means this engine describes a moment that has
                // passed, and storing it would hand the next chord exactly the stale engine the
                // token exists to prevent.
                if preparedGeneration == generation, prepared == nil {
                    prepared = built
                } else {
                    orphan = built
                }
            }
            if let orphan { release(orphan) }
        }
        thread.name = "dev.personal.dicta.capture.prepare"
        thread.start()
    }

    /// Throws away whatever is waiting, and makes any preparation in flight arrive too late.
    private func invalidatePrepared() {
        let orphan: Prepared? = lock.withLock {
            preparedGeneration &+= 1
            let taken = prepared
            prepared = nil
            return taken
        }
        if let orphan { release(orphan) }
    }

    /// A prepared engine that will never be used. It was never started, so this is only the tap.
    private func release(_ candidate: Prepared) {
        candidate.slot.detach()
        candidate.engine.inputNode.removeTap(onBus: 0)
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
        recording.teardownLock.withLock { recording.observers = [configuration, sleep] }
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
    ///
    /// Idempotent is not the same as thread-safe, and both are needed. `take` hands the recording
    /// to one thread, so `drain`, `discard`, `fault` and `escalate` cannot overlap -- but the
    /// `claimStarted` branch in `begin` tears down a recording ANOTHER thread has already taken,
    /// deliberately, because that thread's teardown ran before `engine.start()` and left the engine
    /// running with nobody holding it. Those two are genuinely concurrent whenever a discard lands
    /// while `begin` is blocked inside `start()` on a wedged HAL, which is the case the warm-up
    /// watchdog exists to produce. So each run is serialised against the other, and both still do
    /// the work: whichever is second stops an engine the first could not have stopped yet.
    private func tearDown(_ recording: Recording) {
        // The next engine, asked for FIRST -- before the teardown this function exists to do.
        //
        // The engine this attempt consumed is spent: a second `start()` on a stopped engine
        // measured 104 ms against 41 on a fresh one, so nothing here is recycled. Where the build
        // is asked for turned out to matter as much as that it happens at all, and all three
        // placements were measured rather than argued (10 warm attempts each, medians):
        //
        //   after `engine.stop()`, at the end of teardown   130 ms, p90 152-170, 2-3 of 10 over
        //   immediately after `start()`, during recording   155 ms, p90 160, 6 of 10 over
        //   here, overlapping `engine.stop()`               129 ms, p90 139, 1 of 10 over
        //
        // Preparing during the dictation is the one that looks cleverest and is the worst: a second
        // engine being built while the first is recording costs the recording. Preparing after the
        // stop is correct but late -- `engine.stop()` returns only once the render thread has
        // quiesced, and a chord arriving inside that window finds nothing ready and pays the ~34 ms
        // itself. Overlapping the stop spends time that is already being spent.
        //
        // Harmless when teardown runs twice for the same recording, which it legitimately does:
        // `prepareInBackground` builds nothing when one is ready or already being built.
        prepareInBackground()
        recording.teardownLock.withLock {
            for observer in recording.observers {
                NotificationCenter.default.removeObserver(observer)
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
            recording.observers = []
            // Before the engine is stopped, so a buffer already in flight on the render thread
            // finds nothing rather than appending to a recording the daemon has finished with.
            recording.slot.detach()
            if recording.engine.isRunning { recording.engine.stop() }
            recording.engine.inputNode.removeTap(onBus: 0)
        }
    }
}
