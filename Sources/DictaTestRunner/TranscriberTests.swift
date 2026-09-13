import DictaCore
import DictaIPC
import DictaRuntime
import Foundation
import Testing

/// Recognition: the rules that hold whatever model is behind the seam.
///
/// What is deliberately NOT here is Parakeet itself. Loading four `.mlmodelc` bundles and decoding
/// a spoken sentence needs 600 MB on disk, the ANE, and a human to judge whether the words are
/// right -- §10 assigns exactly that to a person, in step 2's criterion (b). What a test can hold
/// to account is everything around it: that the models load once and only once, that a chord
/// arriving mid-load waits instead of losing the utterance, that a missing model is diagnosed
/// before the first chord rather than during it, and that unusable output never becomes keystrokes.
/// Spins until `condition` holds, and FAILS at the deadline rather than spinning for ever.
///
/// `while !condition { usleep(1_000) }` with no ceiling is the shape that turns a regression into a
/// hung `Scripts/test.sh` — the only gate this project has — instead of a red assertion. The value
/// is generous on purpose: it is a deadlock detector, not a performance budget.
func waitUntil(_ what: String, seconds: TimeInterval = 10,
               _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline { usleep(1_000) }
    #expect(condition(), "\(what) did not happen within \(Int(seconds)) s",
            sourceLocation: sourceLocation)
}

@Suite("transcriber")
struct TranscriberTests {
    // MARK: - a recogniser that counts what it was asked to do

    /// `RecognitionEngine` with a tally. The tally is the point: "no model load occurs anywhere on
    /// the attempt path" (D10, normative) is otherwise a claim about a call graph, and here it is
    /// an assertion that a number stayed at one.
    final class CountingEngine: RecognitionEngine, @unchecked Sendable {
        struct Broken: Error, CustomStringConvertible {
            var description: String { "the encoder bundle is corrupt" }
        }

        private let lock = NSLock()
        private var loads = 0
        private var heard: [Audio] = []
        private var text: String
        private var loadError: (any Error)?
        private var recogniseError: (any Error)?
        /// Held closed to keep a load in flight for as long as a test needs it.
        private let gate = DispatchSemaphore(value: 0)
        private var blocking = false

        init(text: String = "recognised words") {
            self.text = text
        }

        var loadCount: Int { lock.withLock { loads } }
        var heardAudio: [Audio] { lock.withLock { heard } }

        func setText(_ text: String) { lock.withLock { self.text = text } }
        func setLoadError(_ error: (any Error)?) { lock.withLock { loadError = error } }
        func setRecogniseError(_ error: (any Error)?) { lock.withLock { recogniseError = error } }

        /// Makes the next `loadModels` block until `releaseLoad` is called.
        func blockLoad() { lock.withLock { blocking = true } }
        func releaseLoad() { gate.signal() }

        func loadModels() throws {
            let (error, waiting) = lock.withLock { () -> ((any Error)?, Bool) in
                loads += 1
                return (loadError, blocking)
            }
            if waiting { gate.wait() }
            if let error { throw error }
        }

        func recognise(_ audio: Audio) throws -> String {
            let (text, error) = lock.withLock { () -> (String, (any Error)?) in
                heard.append(audio)
                return (self.text, recogniseError)
            }
            if let error { throw error }
            return text
        }
    }

    // MARK: - warming (D10, §12)

    @Test("preparing loads the models once and runs one dummy inference")
    func prepareWarmsTheModels() throws {
        let engine = CountingEngine()
        let transcriber = ParakeetTranscriber(engine: engine)

        #expect(!transcriber.isReady)
        let summary = try transcriber.prepare()

        #expect(transcriber.isReady)
        #expect(engine.loadCount == 1)
        // The dummy inference is what buys the first real dictation out of paying ANE compilation
        // (§12). A warm-up that loaded the models and stopped there would look identical from
        // outside and cost the user a slow first chord.
        #expect(engine.heardAudio.count == 1)
        let dummy = try #require(engine.heardAudio.first)
        #expect(dummy.sampleRate == Audio.requiredSampleRate)
        // Long enough to actually reach the encoder. A handful of samples would compile nothing.
        #expect(dummy.samples.count == 16_000)
        #expect(summary.warmUpError == nil)
        #expect(summary.loadSeconds >= 0)
    }

    @Test("no model load happens anywhere on the attempt path")
    func theAttemptPathLoadsNothing() throws {
        let engine = CountingEngine(text: "one")
        let transcriber = ParakeetTranscriber(engine: engine)
        try transcriber.prepare()

        for _ in 0..<5 {
            _ = try transcriber.transcribe(Audio(samples: [0.1, 0.2], sampleRate: 16_000))
        }

        // D10's normative half. `fluidaudiocli` would have reloaded four bundles five times over,
        // which is the whole reason FluidAudio is linked rather than shelled out to (§12).
        #expect(engine.loadCount == 1)
        #expect(engine.heardAudio.count == 6) // the dummy, plus the five attempts
    }

    @Test("a dummy inference that fails is reported but does not refuse dictation")
    func aFailedWarmUpStillLeavesRecognitionAvailable() throws {
        let engine = CountingEngine()
        engine.setRecogniseError(CountingEngine.Broken())
        let transcriber = ParakeetTranscriber(engine: engine)

        let summary = try transcriber.prepare()

        // The models loaded. Refusing every dictation on the strength of a warm-up would turn a
        // recoverable oddity into a dead daemon -- so it is said out loud and nothing more.
        #expect(summary.warmUpError?.contains("corrupt") == true)
        #expect(transcriber.isReady)
        engine.setRecogniseError(nil)
        #expect(try transcriber.transcribe(Audio(samples: [0], sampleRate: 16_000))
            == "recognised words")
    }

    @Test("recognition returns the model's text verbatim")
    func recognitionIsVerbatim() throws {
        // §2: **recognised** is what the model emitted, hazards and all. Trimming here would put
        // the dictionary's misfires beyond diagnosis, since §9's two fields would no longer differ
        // for the reason the record claims.
        let engine = CountingEngine(text: " Cleaned?  No.\n")
        let transcriber = ParakeetTranscriber(engine: engine)
        try transcriber.prepare()

        #expect(try transcriber.transcribe(Audio(samples: [0], sampleRate: 16_000))
            == " Cleaned?  No.\n")
    }

    // MARK: - the three ways recognition is unavailable (§7)

    @Test("a transcriber nobody prepared refuses rather than loading on the hot path")
    func anUnpreparedTranscriberRefuses() {
        let engine = CountingEngine()
        let transcriber = ParakeetTranscriber(engine: engine)

        #expect(throws: RecognitionError.notPrepared) {
            _ = try transcriber.transcribe(Audio(samples: [0], sampleRate: 16_000))
        }
        // The important half: it did NOT quietly load to be helpful. That would satisfy the chord
        // and break D10 at the same time, in a way no user could see.
        #expect(engine.loadCount == 0)
    }

    @Test("a failed load makes every later attempt fail with the load's own reason")
    func aFailedLoadIsReportedOnEveryAttempt() throws {
        let engine = CountingEngine()
        engine.setLoadError(RecognitionError.modelsMissing(directory: "/models",
                                                           missing: ["Encoder.mlmodelc"]))
        let transcriber = ParakeetTranscriber(engine: engine)

        #expect(throws: RecognitionError.self) { try transcriber.prepare() }
        #expect(!transcriber.isReady)

        // §7's "the model is unavailable" row, and it must keep saying so: a second chord that got
        // `notPrepared` instead would send the reader looking for a wiring bug.
        let thrown = #expect(throws: RecognitionError.self) {
            _ = try transcriber.transcribe(Audio(samples: [0], sampleRate: 16_000))
        }
        #expect("\(try #require(thrown))".contains("Encoder.mlmodelc"))
        #expect(engine.loadCount == 1)
    }

    @Test("an inference abandoned at its ceiling refuses the next chord instead of hanging again")
    func anAbandonedInferenceIsNotRetried() throws {
        // `Blocking.run` gives up on an inference; the `Task` it leaves behind does not. It is
        // still inside FluidAudio's `AsrManager`, which is an actor -- so the NEXT inference
        // queues behind it and spends the whole ceiling to arrive at the same place. Left
        // unlatched, one wedged inference turns into every later dictation costing thirty
        // seconds and reporting a slow recogniser rather than a dead one.
        let engine = CountingEngine(text: "never reached")
        let transcriber = ParakeetTranscriber(engine: engine)
        try transcriber.prepare()
        engine.setRecogniseError(RecognitionError.timedOut(seconds: 30))

        let first = #expect(throws: RecognitionError.self) {
            _ = try transcriber.transcribe(Audio(samples: [0.5], sampleRate: 16_000))
        }
        #expect(try #require(first) == RecognitionError.abandoned(seconds: 30))

        // The engine is not asked again -- which is the whole point, since asking is what costs the
        // thirty seconds -- and the sentence names the remedy rather than describing slowness.
        let heardBefore = engine.heardAudio.count
        engine.setRecogniseError(nil) // it would answer now; the transcriber must not ask.
        let second = #expect(throws: RecognitionError.self) {
            _ = try transcriber.transcribe(Audio(samples: [0.5], sampleRate: 16_000))
        }
        #expect(engine.heardAudio.count == heardBefore)
        #expect("\(try #require(second))".contains("restart the daemon"))
        #expect(!transcriber.isReady)
    }

    @Test("a chord arriving while the models are still loading waits instead of losing the audio")
    func anAttemptWaitsForALoadInFlight() throws {
        let engine = CountingEngine(text: "waited")
        engine.blockLoad()
        let transcriber = ParakeetTranscriber(engine: engine)

        let loading = Thread { _ = try? transcriber.prepare() }
        loading.start()
        // Let the load get as far as blocking. Not a synchronisation point the result depends on:
        // whether `transcribe` arrives before or after the load starts, it must still answer.
        waitUntil("the load reached the engine") { engine.loadCount > 0 }

        let done = DispatchSemaphore(value: 0)
        let answer = Answer()
        let attempt = Thread {
            answer.set(try? transcriber.transcribe(Audio(samples: [0.5], sampleRate: 16_000)))
            done.signal()
        }
        attempt.start()
        // The audio is already recorded by this point in a real attempt. Failing here would throw
        // away an utterance over a race with the daemon's own start-up, which is the worst outcome
        // available: the words are gone AND the recogniser was about to work.
        engine.releaseLoad()
        #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(answer.value == "waited")
        #expect(engine.loadCount == 1)
    }

    @Test("a second prepare loads nothing more, whether the first is running or finished")
    func prepareIsIdempotent() throws {
        // D10 counts: "the models load exactly once". The guard that was supposed to enforce this
        // was written as `lock.withLock { if case .loading = state { return } }` -- where `return`
        // leaves the CLOSURE, not the function, so the body loaded anyway. Two concurrent callers
        // each paid a 600 MB CoreML load, and a second call against a `.ready` transcriber knocked
        // it back to `.loading` and stalled every attempt that arrived meanwhile.
        let engine = CountingEngine(text: "once")
        engine.blockLoad()
        let transcriber = ParakeetTranscriber(engine: engine)

        let first = Thread { _ = try? transcriber.prepare() }
        first.start()
        waitUntil("the first load reached the engine") { engine.loadCount > 0 }

        // While the first load is in flight.
        let secondDone = DispatchSemaphore(value: 0)
        let second = Thread {
            _ = try? transcriber.prepare()
            secondDone.signal()
        }
        second.start()

        engine.releaseLoad()
        #expect(secondDone.wait(timeout: .now() + 10) == .success)
        waitUntil("the transcriber became ready") { transcriber.isReady }

        // And once it has finished.
        _ = try transcriber.prepare()

        #expect(engine.loadCount == 1)
        #expect(transcriber.isReady, "a repeat prepare must not knock a warm transcriber back")
        #expect(try transcriber.transcribe(Audio(samples: [0.5], sampleRate: 16_000)) == "once")
    }

    /// A one-slot box, because the answer is written on one thread and read on another.
    final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var text: String?
        func set(_ text: String?) { lock.withLock { self.text = text } }
        var value: String? { lock.withLock { text } }
    }

    // MARK: - what has to be on disk (the startup self-check)

    @Test("the required model files are the ones FluidAudio names, not a hand-typed list")
    func theRequiredFilesComeFromTheLibrary() {
        let required = ParakeetModels.requiredFiles
        // Four CoreML bundles plus the vocabulary. Spelled out here as a tripwire rather than as
        // the source of truth: the production list is derived from FluidAudio's own `ModelNames`,
        // so a library bump that renames a bundle fails THIS test instead of reporting "the models
        // are missing" against a directory that is perfectly complete.
        #expect(required.contains("Preprocessor.mlmodelc"))
        #expect(required.contains("Encoder.mlmodelc"))
        #expect(required.contains("Decoder.mlmodelc"))
        #expect(required.contains("JointDecisionv3.mlmodelc"))
        #expect(required.contains("parakeet_vocab.json"))
        #expect(required.count == 5)
        #expect(required == required.sorted(),
                "the list is sorted so a message naming them reads the same way twice")
    }

    @Test("the self-check names exactly the files that are absent")
    func missingFilesAreNamedIndividually() {
        let directory = URL(fileURLWithPath: "/models/parakeet-tdt-0.6b-v3-coreml")
        let staged = Set(ParakeetModels.requiredFiles.dropFirst())

        let missing = ParakeetModels.missingFiles(in: directory) { url in
            staged.contains(url.lastPathComponent)
        }

        // A list rather than a Bool, because an interrupted download is the likely shape of this
        // failure and "the models are missing" sends the user to re-fetch all 600 MB of them.
        #expect(missing == [ParakeetModels.requiredFiles[0]])
        #expect(ParakeetModels.missingFiles(in: directory) { _ in true }.isEmpty)
        #expect(ParakeetModels.missingFiles(in: directory) { _ in false }
            == ParakeetModels.requiredFiles)
    }

    @Test("a missing model reads as a remedy, not as a hardware fault")
    func theMissingModelMessageNamesItsRemedy() {
        let error = RecognitionError.modelsMissing(directory: "/models",
                                                   missing: ["Decoder.mlmodelc"])

        let text = error.description
        #expect(text.contains("/models"))
        #expect(text.contains("Decoder.mlmodelc"))
        // The whole point of diagnosing this at startup: the message has to end the problem, not
        // merely describe it (§7). A user who is told "models missing" and nothing else goes
        // looking at their microphone.
        #expect(text.contains("--fetch-models"))
    }

    @Test("the models live under FluidAudio's own cache directory")
    func theModelDirectoryIsTheLibrarysOwn() {
        // Not a path of dicta's choosing: `AsrModels.load` reconstructs the repo folder from the
        // directory it is handed, so staging them anywhere else would load nothing.
        let path = ParakeetModels.directory.path
        #expect(path.contains("FluidAudio/Models"))
        // Note what the folder is NOT called: FluidAudio's HuggingFace repo is
        // `parakeet-tdt-0.6b-v3-coreml`, and its cache folder strips the `-coreml`. Spelling that
        // out anywhere in dicta would put the models one directory away from where they are read.
        #expect(ParakeetModels.directory.lastPathComponent == "parakeet-tdt-0.6b-v3")
    }

    @Test("the daemon's own ceilings fit inside the client's read timeout")
    func daemonCeilingsFitTheClientTimeout() {
        // The daemon does NOT answer before doing the work: a `stop` returns only after drain →
        // recognition → dictionary → sanitiser → keystrokes, all inside the handler lock. So the
        // client's read timeout is a ceiling on the whole pipeline, and any daemon-side ceiling
        // above it reproduces the failure `pipelineRead` was raised to remove -- `dictactl` saying
        // "dicta did not answer" and firing the desktop notification about a dictation that then
        // lands a minute later.
        //
        // These four numbers live in three files and were set independently; before this assertion
        // existed they read 120 + 60 against a client that gave up at 30.
        // Every bounded subprocess the stop path can make, counted on `ProcessRunner` itself rather
        // than guessed at here. This used to read `* 3` -- "validate, session type, announce" --
        // and the real path makes up to twelve, because each notification carries an `osascript`
        // fallback and there are four of them. The assertion held only by undercounting the thing
        // it exists to bound.
        //
        // And `worstCaseCallSeconds` rather than `defaultDeadline`: a call that is killed at the
        // deadline still spends the SIGTERM grace and then the grace the pipe reads get after the
        // SIGKILL, so multiplying by the deadline undercounts every one of these by 60%.
        let calls = Double(ProcessRunner.worstCaseCallsPerStop)
        let agtermCalls = ProcessRunner.worstCaseCallSeconds * calls
        let worstCase = Double(ParakeetTranscriber.patience)
            + Double(ParakeetEngine.inferenceCeiling)
            + agtermCalls
        let givesUpAt = ControlTimeouts.pipelineRead
        #expect(worstCase <= givesUpAt,
                "the daemon would spend \(worstCase) s; the client gives up at \(givesUpAt) s")

        // A focused-field stop runs the same recognition and then delivers inline under the same
        // lock (D32), with its feedback through `osascript` rather than `agtermctl`. The delivery
        // ceiling is built from the injector's enforced bounds -- its deadline, one validation read
        // at the messaging timeout per accessibility message, one pause and one chunk past the
        // last check -- never from the text, which is what the deadline exists to stop mattering.
        let delivery = FocusedFieldInjector.worstCaseSeconds
        #expect(FocusedFieldInjector.deliveryDeadline < delivery,
                "the deadline must sit below the ceiling it stops the delivery under")
        let feedbackCalls = Double(SystemFeedback.worstCaseCallsPerStop)
            * ProcessRunner.worstCaseCallSeconds
        let fieldWorstCase = Double(ParakeetTranscriber.patience)
            + Double(ParakeetEngine.inferenceCeiling)
            + delivery
            + feedbackCalls
        #expect(fieldWorstCase <= givesUpAt,
                "a field stop spends \(fieldWorstCase) s; the client gives up at \(givesUpAt) s")
    }
}

/// §7's third recogniser row, and the only one whose rule is a number: output that is not valid
/// UTF-8 or is longer than the frame limit is a processing failure that records the BYTE LENGTH.
@Suite("recognised text")
struct RecognisedTextTests {
    @Test("ordinary text passes through unchanged")
    func textPassesThrough() {
        // Cyrillic as escapes, per this repository's English-only rule: a literal here would
        // give `Scripts/lint.sh`'s Cyrillic grep something legitimate to find, and the
        // grep is only a gate while it has nothing.
        let mixed = "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}, world"
        #expect(RecognisedText.validate(mixed) == .text(mixed))
        #expect(RecognisedText.validate("").failureReason == nil)
    }

    @Test("text at the ceiling still fits a response frame, envelope and all")
    func theCeilingLeavesRoomForTheEnvelope() throws {
        // The property that matters, asserted end to end rather than as an equality between two
        // constants. Text goes back out through the socket when `dictactl last` asks for it, inside
        // a whole `Response` -- `kind`, `state`, `attempt`, `target`, and the JSON quoting. When
        // `maxBytes` was set EQUAL to `Wire.maxFrameBytes`, text in the last few hundred bytes was
        // accepted into the record and then could not be encoded on the way out; the server dropped
        // the connection and `dictactl` reported the live daemon as crashed.
        let atLimit = String(repeating: "a", count: RecognisedText.maxBytes)
        #expect(RecognisedText.validate(atLimit) == .text(atLimit))

        let answer = Response(
            kind: .accepted,
            state: .idle,
            attempt: 4_294_967_296,
            target: Target(sessionID: String(repeating: "s", count: 128), pane: .left),
            text: atLimit
        )
        let frame = try Wire.encode(answer)
        #expect(frame.count <= Wire.maxFrameBytes)
        // And the ceiling is still derived from the wire rather than invented, so raising one
        // number moves the other.
        #expect(RecognisedText.maxBytes
            == Wire.maxFrameBytes - RecognisedText.responseEnvelopeBytes)
    }

    @Test("text at the limit is accepted and one byte more is refused")
    func theLimitIsExact() throws {
        let atLimit = String(repeating: "a", count: RecognisedText.maxBytes)
        #expect(RecognisedText.validate(atLimit) == .text(atLimit))

        let over = atLimit + "a"
        let verdict = RecognisedText.validate(over)
        #expect(verdict == .tooLong(bytes: RecognisedText.maxBytes + 1,
                                    limit: RecognisedText.maxBytes))
        // The number is the diagnostic (§7): "the recogniser returned something unusable" is not
        // something a human reading the record can act on.
        let reason = try #require(verdict.failureReason)
        #expect(reason.contains("\(RecognisedText.maxBytes + 1) bytes"))
        #expect(reason.contains("\(RecognisedText.maxBytes)-byte limit"))
    }

    @Test("the limit is measured in bytes, not in characters")
    func lengthIsCountedInBytes() {
        // Cyrillic is two bytes per character and emoji four. A limit checked against `count` would
        // let twice the frame through and the refusal would happen at the socket instead, where the
        // failure is "dicta could not read the command" and points at the wrong component.
        let cyrillic = String(repeating: "\u{044F}", count: RecognisedText.maxBytes / 2 + 1)
        #expect(cyrillic.count < RecognisedText.maxBytes)
        #expect(RecognisedText.validate(cyrillic)
            == .tooLong(bytes: cyrillic.utf8.count, limit: RecognisedText.maxBytes))
    }

    @Test("bytes that are not valid UTF-8 are refused with their length")
    func invalidUTF8IsRefused() throws {
        // 0xC3 begins a two-byte sequence and 0x28 cannot continue one. Decoded with a substitution
        // this becomes "A?(B" and gets injected; the point of validating rather than repairing is
        // that mojibake never reaches the input line.
        let bytes = Data([0x41, 0xC3, 0x28, 0x42])

        let verdict = RecognisedText.validate(bytes)

        #expect(verdict == .notUTF8(bytes: 4))
        #expect(try #require(verdict.failureReason).contains("4 bytes"))
        #expect(try #require(verdict.failureReason).contains("not valid UTF-8"))
    }

    @Test("valid bytes decode to their text")
    func validBytesDecode() {
        let text = "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}"
        #expect(RecognisedText.validate(Data(text.utf8)) == .text(text))
    }

    @Test("oversized bytes are refused before they are decoded")
    func oversizedBytesAreRefusedWithoutDecoding() {
        // The length check runs first, so a 200 KB frame costs a comparison rather than a decode --
        // the same ordering `Wire.decode` uses, and for the same reason.
        let bytes = Data(repeating: 0xFF, count: RecognisedText.maxBytes + 1)
        #expect(RecognisedText.validate(bytes)
            == .tooLong(bytes: RecognisedText.maxBytes + 1, limit: RecognisedText.maxBytes))
    }
}
