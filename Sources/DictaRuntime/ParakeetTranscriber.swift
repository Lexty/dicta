import CoreML
import DictaCore
import FluidAudio
import Foundation

// Recognition: Parakeet TDT 0.6B v3 on CoreML/ANE, via FluidAudio (D10).
//
// The normative half of D10 is not the model, it is that **no model loads on the hot path**. That
// is what this file is arranged around, and it is why FluidAudio is linked rather than shelled out
// to: `fluidaudiocli` reloads four `.mlmodelc` bundles per invocation, so every dictation would pay
// ANE compilation while the user watched (§12).
//
// The arrangement is a small state machine -- cold, loading, ready, failed -- and it exists because
// "warm at start" has three failure modes that must be told apart:
//
//   • the models are not on disk. Reported at STARTUP, loudly, with the command that fixes it: a
//     chord that discovers this is a chord that has already thrown away an utterance (§7).
//   • the load is still running when a chord arrives. The attempt WAITS rather than failing:
//     the audio is already recorded, and losing it to a race with the daemon's own start-up would
//     be the worst of both. This is not a load on the hot path -- it is the hot path waiting for
//     the one load there is.
//   • the load failed. Every attempt then fails immediately with the reason the load gave, which is
//     §7's "the model is unavailable" row: no injection, notify, record the error with no text.
//
// The seam between this and FluidAudio is `RecognitionEngine`, and it earns its keep: with a
// counting fake behind it, "no model load occurs anywhere on the attempt path" becomes an assertion
// about a number rather than a claim about a call graph.

/// Loading and inference, split from the lifecycle above it.
///
/// Synchronous and throwing, like the `Transcriber` seam it serves, so the daemon keeps calling
/// recognition from a place where it already owns the attempt.
public protocol RecognitionEngine: Sendable {
    /// Brings the models into memory. Called once, at daemon start.
    func loadModels() throws
    /// One utterance to text, verbatim. Never loads anything.
    func recognise(_ audio: Audio) throws -> String
}

/// Why recognition cannot answer. Separate from FluidAudio's own errors because these are the two
/// §7 rows whose wording the user reads, and both must name a remedy.
public enum RecognitionError: Error, Equatable, CustomStringConvertible {
    /// The `.mlmodelc` bundles are not staged. Names the files and the command that fetches them.
    case modelsMissing(directory: String, missing: [String])
    /// The transcriber was never prepared -- a wiring bug rather than a user's problem, worded so
    /// that whoever reads the record knows which of the two it is.
    case notPrepared
    /// The load ran and failed. Carries the reason, since it is the only description there is.
    case loadFailed(String)
    /// The load, or an inference, outran its ceiling. See `ParakeetTranscriber.patience`.
    case timedOut(seconds: Int)
    /// An inference outran its ceiling and was ABANDONED, and the recogniser has been written off
    /// for the life of this process. See `ParakeetTranscriber.transcribe`.
    case abandoned(seconds: Int)

    public var description: String {
        switch self {
        case let .modelsMissing(directory, missing):
            "the recognition models are not installed in \(directory) (missing "
                + missing.joined(separator: ", ")
                + ") -- run `Dicta --fetch-models` once, then restart the daemon"
        case .notPrepared:
            "the recogniser was never prepared -- this is a wiring bug in dicta, not a setting"
        case let .loadFailed(reason):
            "the recognition models could not be loaded: \(reason)"
        case let .timedOut(seconds):
            "the recogniser did not answer within \(seconds) s -- nothing was typed"
        case let .abandoned(seconds):
            "the recogniser stopped answering (an inference outran its \(seconds) s ceiling and is "
                + "still running) -- restart the daemon; nothing was typed"
        }
    }
}

// MARK: - what has to be on disk

/// Where the Parakeet bundles live and which of them have to be there.
///
/// The file names are taken from FluidAudio's own `ModelNames`, never spelled out here. A library
/// bump that renames `JointDecisionv3.mlmodelc` would otherwise turn into "the models are missing"
/// against a directory that is perfectly complete, and the user would go looking at their disk.
public enum ParakeetModels {
    /// D10's model. v2 is English-only, and this user dictates Russian with English terms in it.
    public static let version: AsrModelVersion = .v3

    /// int8, which is FluidAudio's own default and decides which encoder bundle is required.
    public static let encoderPrecision: ParakeetEncoderPrecision = .int8

    public static var directory: URL { AsrModels.defaultCacheDirectory(for: version) }

    /// Sorted so a message naming them reads the same way twice.
    public static var requiredFiles: [String] {
        (ModelNames.ASR.requiredModelsV3(precision: encoderPrecision)
            .union([ModelNames.ASR.vocabularyFile])).sorted()
    }

    /// Which of the required files are absent. `exists` is injected so the check has a test that
    /// does not depend on what happens to be staged on the machine running it.
    public static func missingFiles(
        in directory: URL,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> [String] {
        requiredFiles.filter { !exists(directory.appendingPathComponent($0)) }
    }

    /// The startup self-check (§7's spirit): the answer is a list, not a Bool, so the message can
    /// say WHICH file is missing -- a half-staged directory from an interrupted download is the
    /// likely case, and "the models are missing" sends the user to re-download all 600 MB of them.
    public static func selfCheck() -> RecognitionError? {
        let missing = missingFiles(in: directory)
        guard !missing.isEmpty else { return nil }
        return .modelsMissing(directory: directory.path, missing: missing)
    }

    /// Fetches the bundles from HuggingFace. Deliberately NOT called from the daemon's start-up
    /// path: a LaunchAgent that pulls hundreds of megabytes at login, on whatever network the
    /// laptop woke up on, is not something to do without being asked. `Dicta --fetch-models` is the
    /// asking.
    public static func fetch(progress: @escaping @Sendable (String) -> Void) throws {
        try Blocking.run(seconds: 3_600, label: "the model download") {
            let directory = try await AsrModels.download(
                version: version,
                encoderPrecision: encoderPrecision
            )
            progress("models are staged in \(directory.path)")
        }
    }
}

// MARK: - the transcriber

/// The `Transcriber` seam over Parakeet, warm before the first chord.
public final class ParakeetTranscriber: Transcriber, @unchecked Sendable {
    /// What `prepare` measured, for the daemon to log. A load that took 40 s and a load that took
    /// 2 s are both "ready", and only one of them is worth telling somebody about.
    public struct Summary: Sendable, Equatable {
        public let loadSeconds: Double
        public let warmUpSeconds: Double
        /// A dummy inference that failed. NOT fatal: the models are loaded, and an attempt is still
        /// better off trying than being refused on the strength of a warm-up.
        public let warmUpError: String?

        public init(loadSeconds: Double, warmUpSeconds: Double, warmUpError: String?) {
            self.loadSeconds = loadSeconds
            self.warmUpSeconds = warmUpSeconds
            self.warmUpError = warmUpError
        }
    }

    private enum State {
        case cold
        case loading
        case ready
        case failed(RecognitionError)
    }

    /// How long an attempt waits for a load that is still running. F1 puts inference in the
    /// hundreds of milliseconds; a load is seconds. Anything past this is wedged rather than slow,
    /// and a wedged recognition holds the socket handler's thread -- so it becomes §7's processing
    /// failure instead of a daemon that stops answering chords.
    ///
    /// Sixty is three and a half times the measured 17 s cold load, and it is bounded from above by
    /// `ControlTimeouts.pipelineRead`: the daemon must never be willing to spend longer than the
    /// client will wait, or `dictactl` reports a failure about a dictation that then lands.
    /// `daemonCeilingsFitTheClientTimeout` is where that relationship is asserted.
    public static let patience = 60

    private let engine: any RecognitionEngine
    private let lock = NSLock()
    private let settled = NSCondition()
    private var state: State = .cold

    public init(engine: any RecognitionEngine = ParakeetEngine()) {
        self.engine = engine
    }

    /// Whether an attempt would recognise without waiting. What the daemon's start-up log reports.
    public var isReady: Bool {
        lock.withLock { if case .ready = state { true } else { false } }
    }

    // MARK: warming

    /// Loads the models and runs one dummy inference, so the first real dictation pays no ANE
    /// compilation (§12). Call once, at daemon start, off the attempt path.
    ///
    /// Throws only when the models cannot be loaded at all -- the case the self-check is loud
    /// about. A dummy inference that fails comes back in the summary instead, because refusing to
    /// recognise on the strength of a warm-up would turn a recoverable oddity into a dead daemon.
    @discardableResult
    public func prepare() throws -> Summary {
        // The decision is taken inside the lock and RETURNED, rather than returned from inside the
        // closure: `return` in a `withLock` body exits the closure, not the function, so a guard
        // written that way loads the models anyway -- silently, and twice.
        let alreadyWarm = lock.withLock { () -> Bool in
            switch state {
            case .loading, .ready:
                return true
            case .cold, .failed:
                state = .loading
                return false
            }
        }
        guard !alreadyWarm else {
            // A second caller does not get its own load. It waits for the one already running (or
            // returns at once when it has finished) -- the models load exactly once (D10).
            try awaitReadiness()
            return Summary(loadSeconds: 0, warmUpSeconds: 0, warmUpError: nil)
        }
        let loadStart = Date()
        do {
            try engine.loadModels()
        } catch {
            let failure = error as? RecognitionError ?? .loadFailed(Daemon.reason(error))
            publish(.failed(failure))
            throw failure
        }
        let loadSeconds = Date().timeIntervalSince(loadStart)

        // The dummy inference, and the reason it is a second of silence rather than a handful of
        // samples: what is being paid for here is the ANE compiling the encoder graph, and that
        // only happens when a buffer actually reaches it.
        let warmUpStart = Date()
        var warmUpError: String?
        do {
            _ = try engine.recognise(Audio(samples: [Float](repeating: 0, count: 16_000),
                                           sampleRate: Audio.requiredSampleRate))
        } catch {
            warmUpError = Daemon.reason(error)
        }
        publish(.ready)
        return Summary(loadSeconds: loadSeconds,
                       warmUpSeconds: Date().timeIntervalSince(warmUpStart),
                       warmUpError: warmUpError)
    }

    private func publish(_ next: State) {
        settled.lock()
        lock.withLock { state = next }
        settled.broadcast()
        settled.unlock()
    }

    // MARK: the seam

    public func transcribe(_ audio: Audio) throws -> String {
        try awaitReadiness()
        do {
            return try engine.recognise(audio)
        } catch let error as RecognitionError {
            // An inference that outran its ceiling was ABANDONED, not cancelled: `Blocking.run`
            // stops waiting and leaves its `Task` inside FluidAudio's `AsrManager`, which is an
            // actor. Every later inference queues behind it and times out too, so recognition is
            // over until the process restarts. Latching that here turns thirty wasted seconds per
            // chord, with a message that reads like a slow machine, into an immediate refusal
            // naming the remedy -- and it is the transcriber's to latch, because "is recognition
            // available" is the one question this type exists to answer.
            if case let .timedOut(seconds) = error {
                let wedge = RecognitionError.abandoned(seconds: seconds)
                publish(.failed(wedge))
                throw wedge
            }
            throw error
        }
    }

    /// Blocks until the state is `ready`, or throws the reason it never will be.
    ///
    /// `.cold` throws rather than loading: a transcriber nobody prepared is a wiring mistake, and
    /// loading here to paper over it would put the model load on the hot path -- which is the one
    /// thing D10 states normatively.
    private func awaitReadiness() throws {
        let deadline = Date().addingTimeInterval(Double(Self.patience))
        settled.lock()
        defer { settled.unlock() }
        while true {
            switch lock.withLock({ state }) {
            case .ready:
                return
            case .cold:
                throw RecognitionError.notPrepared
            case let .failed(error):
                throw error
            case .loading:
                guard settled.wait(until: deadline) else {
                    throw RecognitionError.timedOut(seconds: Self.patience)
                }
            }
        }
    }
}

// MARK: - FluidAudio

/// Parakeet behind `RecognitionEngine`. The only file in dicta that knows FluidAudio exists.
public final class ParakeetEngine: RecognitionEngine, @unchecked Sendable {
    /// The ceiling on one inference. D15 caps a recording at ten minutes, which F1 puts at a few
    /// seconds of decoding (66.8 s of speech in 0.42 s, measured), so thirty is seventy times the
    /// worst case and firmly into wedged. Bounded from above by `ControlTimeouts.pipelineRead` for
    /// the reason spelled out on `ParakeetTranscriber.patience`.
    public static let inferenceCeiling = 30

    private let lock = NSLock()
    private var manager: AsrManager?
    private var decoderLayers = 2

    public init() {}

    /// Loads from the staged directory and never downloads. The distinction matters: a load that
    /// silently reaches for the network turns "the models are missing" -- a condition with a clear
    /// remedy -- into a first dictation that hangs for as long as the download takes.
    public func loadModels() throws {
        if let error = ParakeetModels.selfCheck() { throw error }
        try Blocking.run(seconds: 600, label: "the model load") { [self] in
            let models = try await AsrModels.load(
                from: ParakeetModels.directory,
                version: ParakeetModels.version,
                encoderPrecision: ParakeetModels.encoderPrecision
            )
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            let layers = await manager.decoderLayerCount
            lock.withLock {
                self.manager = manager
                self.decoderLayers = layers
            }
        }
    }

    public func recognise(_ audio: Audio) throws -> String {
        let (manager, layers) = lock.withLock { (self.manager, self.decoderLayers) }
        guard let manager else { throw RecognitionError.notPrepared }
        return try Blocking.run(seconds: Self.inferenceCeiling, label: "recognition") {
            // A FRESH decoder state per utterance. The RNNT prediction network is stateful, and
            // carrying it over would let the previous dictation's tail bias this one's first words.
            var state = TdtDecoderState.make(decoderLayers: layers)
            // `language: nil` is D10's automatic language identification: naming a language would
            // switch on a script filter, and this user code-mixes Russian with English terms inside
            // one sentence.
            let result = try await manager.transcribe(audio.samples, decoderState: &state)
            // Verbatim (§2): no trimming, no punctuation policy. What the model emitted is what
            // reaches §9's `recognised`, because a replacement misfire is only diagnosable against
            // an untouched copy.
            return result.text
        }
    }
}

// MARK: - the async/sync bridge

/// Runs one `async` body to completion from a synchronous caller.
///
/// FluidAudio's API is actor-based; the `Transcriber` seam is synchronous and throwing,
/// deliberately (see `Seams.swift`: async seams would make D13's and invariant 10's ordering
/// assertions rest on scheduling rather than on the code under test). Something has to bridge, and
/// this is it.
///
/// **The caller must not be a Swift-concurrency cooperative thread.** On Darwin the cooperative
/// pool is non-overcommit and does not grow when its threads block, so blocking one of them while
/// waiting for a `Task` on the same pool is a deadlock -- the exact failure CLAUDE.md records about
/// the control socket. dicta's callers are real `Thread`s (the socket serves each connection on
/// one, and capture reports on the audio thread), which is what makes this safe rather than merely
/// lucky.
enum Blocking {
    /// The handover. A class over a lock rather than a captured `var`, because the value is written
    /// on the `Task`'s thread and read on the blocked one.
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<Value, any Error>?
        func set(_ result: Result<Value, any Error>) { lock.withLock { value = result } }
        var result: Result<Value, any Error>? { lock.withLock { value } }
    }

    static func run<T: Sendable>(
        seconds: Int,
        label: String,
        _ body: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let box = Box<T>()
        let gate = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do {
                box.set(.success(try await body()))
            } catch {
                box.set(.failure(error))
            }
            gate.signal()
        }
        guard gate.wait(timeout: .now() + .seconds(seconds)) == .success else {
            throw RecognitionError.timedOut(seconds: seconds)
        }
        guard let result = box.result else {
            // Signalled without a result is impossible by construction; refusing beats returning a
            // value nobody produced, and naming the step makes the impossible case diagnosable.
            throw RecognitionError.loadFailed("\(label) answered with nothing")
        }
        return try result.get()
    }
}
