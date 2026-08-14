import DictaCore
import DictaRuntime
import Foundation
import Testing

/// The record (§9): the entry as a value, the file it lives in, and what the daemon puts in it.
///
/// Three claims here are the ones the record exists for, and none of them is about JSON:
///
///   • Every attempt leaves exactly one entry, including the attempts that produced no text at all
///     (D17). A gap in the record is indistinguishable from a dictation that never happened.
///   • The text is on disk BEFORE the first keystroke is attempted (invariant 10), the only
///     route by which a delivery failure does not cost the user their words.
///   • `recognised` comes back verbatim and `final` comes back sanitised, independently. Comparing
///     them is the diagnostic step 3 is scored on, and it needs both to survive the round trip.
@Suite("record")
struct RecordTests {
    static let when = Date(timeIntervalSince1970: 1_766_000_000)
    static let target = Target(sessionID: "S1", pane: .left)

    static func entry(
        id: AttemptID = 1,
        outcome: AttemptOutcome = .injected,
        mode: Mode = .clean,
        recognised: String = " dicta hears you\nfrom the  fake transcriber ",
        final: String = "dicta hears you from the fake transcriber",
        rules: RulesApplied = RulesApplied(fired: ["mr-1"], version: "2026-08-14T00:00:00Z"),
        error: String? = nil
    ) -> RecordEntry {
        RecordEntry(id: id, at: when, outcome: outcome, mode: mode, recognised: recognised,
                    final: final, rules: rules, target: target, error: error)
    }

    // MARK: - the entry as a value (§9's fields)

    @Test("every field §9 names survives the round trip", arguments: AttemptOutcome.allCases)
    func everyFieldRoundTrips(outcome: AttemptOutcome) throws {
        let original = Self.entry(id: 17, outcome: outcome, mode: .raw, error: "the pane went away")

        let decoded = try Record.decode(Record.encode(original))

        // Equality over the whole value, so a field added later without a test fails here first.
        #expect(decoded == original)
        #expect(decoded.at == Self.when)
        #expect(decoded.rules.fired == ["mr-1"])
        #expect(decoded.rules.version == "2026-08-14T00:00:00Z")
        #expect(decoded.target == Self.target)
        #expect(decoded.error == "the pane went away")
    }

    @Test("the eleven outcomes are exactly §9's, spelled as §9 spells them")
    func outcomeVocabularyIsTheSpecs() {
        // Not a tautology: the table in §9 is what a human greps the file with, so the raw values
        // are part of the interface and a rename would silently break every note about the record.
        #expect(Set(AttemptOutcome.allCases.map(\.rawValue)) == [
            "injected", "empty", "capture-fault", "recognition-failed", "filter-fell-back",
            "dictionary-degraded", "target-gone", "injection-failed", "injection-partial",
            "capped", "aborted",
        ])
        #expect(AttemptOutcome.allCases.count == 11)
    }

    @Test("an entry whose recognised text carries line breaks still occupies one line")
    func hostileTextStaysOnOneLine() throws {
        // The premise of the whole file format. If a newline in `recognised` reached the file
        // unescaped, one dictation would become two entries and the tail of the record would be
        // permanently unreadable.
        let original = Self.entry(recognised: "one\ntwo\r\nthree\u{2028}four")

        let line = try Record.encode(original)

        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)
        #expect(line.dropLast().contains(0x0D) == false)
        #expect(try Record.decode(line).recognised == "one\ntwo\r\nthree\u{2028}four")
    }

    @Test("recognised and final round-trip independently, including when they differ")
    func recognisedAndFinalAreIndependent() throws {
        // §9's reason for storing both: a misfire is only diagnosable by comparing them, so a
        // codec that derived one from the other would destroy the diagnosis.
        let original = Self.entry(recognised: "use the  socket\nplease ",
                                  final: "use the unix socket please")

        let decoded = try Record.decode(Record.encode(original))

        #expect(decoded.recognised == "use the  socket\nplease ")
        #expect(decoded.final == "use the unix socket please")
        #expect(decoded.recognised != decoded.final)
    }

    @Test("an entry with no error and no rules omits nothing it needs")
    func minimalEntryRoundTrips() throws {
        let original = RecordEntry(id: 3, at: Self.when, outcome: .aborted, mode: .clean,
                                   target: Self.target)

        let decoded = try Record.decode(Record.encode(original))

        #expect(decoded == original)
        #expect(decoded.recognised.isEmpty)
        #expect(decoded.final.isEmpty)
        #expect(decoded.rules == .none)
        #expect(decoded.error == nil)
    }

    // MARK: - reading a file that is not perfect

    @Test("a torn trailing line does not hide the entries before it")
    func truncatedTailIsTolerated() throws {
        var data = Data()
        data += try Record.encode(Self.entry(id: 1))
        data += try Record.encode(Self.entry(id: 2))
        // A write interrupted halfway: exactly what a crash mid-append leaves behind.
        let partial = try Record.encode(Self.entry(id: 3))
        data += partial.prefix(partial.count / 2)

        let entries = Record.entries(in: data)

        #expect(entries.map(\.id) == [1, 2])
    }

    @Test("garbage in the middle costs only its own line")
    func garbageLineIsSkipped() throws {
        var data = Data()
        data += try Record.encode(Self.entry(id: 1))
        data += Data("{not json at all\n".utf8)
        data += Data("\n".utf8)
        data += try Record.encode(Self.entry(id: 2))

        #expect(Record.entries(in: data).map(\.id) == [1, 2])
    }

    @Test("an empty record reads as no entries rather than as an error")
    func emptyRecordIsEmpty() {
        #expect(Record.entries(in: Data()).isEmpty)
        #expect(Record.lines(in: Data()).isEmpty)
    }

    @Test("a superseding line for the same attempt wins, and the order is preserved")
    func lastLineForAnIDWins() throws {
        // How a delivery failure is recorded without a second entry: the pre-injection line saved
        // the text, and this one carries the verdict the injection produced afterwards (§9).
        var data = Data()
        data += try Record.encode(Self.entry(id: 1))
        data += try Record.encode(Self.entry(id: 2, outcome: .injected))
        data += try Record.encode(Self.entry(id: 2, outcome: .injectionPartial,
                                             error: "agtermctl was killed"))
        data += try Record.encode(Self.entry(id: 3))

        let entries = Record.entries(in: data)

        #expect(entries.map(\.id) == [1, 2, 3])
        #expect(entries[1].outcome == .injectionPartial)
        #expect(entries[1].error == "agtermctl was killed")
        // The physical file is append-only: every line is still there to read.
        #expect(Record.lines(in: data).count == 4)
    }

    @Test("a hand-written line with whole-second timestamps still parses")
    func timestampsWithoutFractionsParse() throws {
        let line = Data("""
        {"at":"2026-08-14T10:11:12Z","final":"hi","id":4,"mode":"clean","outcome":"injected",\
        "recognised":"hi","rules":{"fired":[]},"target":{"pane":"left","sessionID":"S1"}}
        """.utf8)

        let entry = try Record.decode(line)

        #expect(entry.id == 4)
        #expect(Record.timestamp(entry.at).hasPrefix("2026-08-14T10:11:12"))
    }

    // MARK: - the file

    /// A record in a temporary directory, removed with the test.
    final class Scratch {
        let directory: URL
        let history: FileHistory

        init() {
            directory = URL(fileURLWithPath: "/tmp")
                .appendingPathComponent("dicta-record-\(UUID().uuidString.prefix(8))",
                                        isDirectory: true)
            history = FileHistory(url: directory.appendingPathComponent("record.jsonl"))
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        var raw: Data { (try? Data(contentsOf: history.url)) ?? Data() }
    }

    @Test("a record that cannot be opened says so, with the path and the reason")
    func unwritableRecordNamesItself() throws {
        // §7's "history append fails" row is asserted elsewhere against `FailingHistory`, which
        // throws its own error -- so the sentence the user ACTUALLY reads when their record is
        // unwritable, and the `strerror` behind it, had never run. This is the same technique
        // `FileDictionaryTests.unreadableFileIsDegraded` uses.
        let scratch = Scratch()
        try FileManager.default.createDirectory(at: scratch.directory,
                                                withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: scratch.directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: scratch.directory.path)
        }

        let thrown = #expect(throws: HistoryError.self) {
            try scratch.history.append(Self.entry(id: 1))
        }

        let message = "\(try #require(thrown))"
        // The path, because a user with more than one machine has more than one record; and the
        // errno's own words, because "could not be opened" alone is not a diagnosis.
        #expect(message.contains(scratch.history.url.path))
        #expect(message.contains("Permission denied"), "the errno must be spelled out: \(message)")
    }

    @Test("a record that cannot be read is a clean error rather than an empty history")
    func unreadableRecordIsAnError() throws {
        // The distinction that matters: an ABSENT file is an empty record (a fresh install), and an
        // unreadable one is a failure. Collapsing the two would make `dictactl last` answer "dicta
        // has no record yet" to a user whose dictations are all still on disk.
        let scratch = Scratch()
        try FileManager.default.createDirectory(at: scratch.directory,
                                                withIntermediateDirectories: true)
        try scratch.history.append(Self.entry(id: 1))
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: scratch.history.url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: scratch.history.url.path)
        }

        let thrown = #expect(throws: HistoryError.self) { try scratch.history.entries() }

        #expect("\(try #require(thrown))".contains(scratch.history.url.path))
        // And the absent case is still not an error.
        let fresh = Scratch()
        #expect(try fresh.history.entries().isEmpty)
    }

    @Test("appending creates the record on demand and adds exactly one line per entry")
    func appendingIsAppendOnly() throws {
        let scratch = Scratch()

        try scratch.history.append(Self.entry(id: 1))
        try scratch.history.append(Self.entry(id: 2, mode: .raw))

        #expect(try scratch.history.entries().map(\.id) == [1, 2])
        #expect(try scratch.history.last()?.id == 2)
        #expect(try scratch.history.last()?.mode == .raw)
        #expect(scratch.raw.filter { $0 == 0x0A }.count == 2)
        // The record holds every word the user has dictated: the most private file dicta owns.
        let mode = try FileManager.default
            .attributesOfItem(atPath: scratch.history.url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o600)
    }

    @Test("a record that does not exist yet reads as empty rather than throwing")
    func missingFileReadsAsEmpty() throws {
        let scratch = Scratch()

        #expect(try scratch.history.entries().isEmpty)
        #expect(try scratch.history.last() == nil)
    }

    @Test("concurrent writers interleave whole lines and lose none")
    func concurrentWritersDoNotTearEachOther() throws {
        // `O_APPEND` plus one `write` per entry is the whole mechanism. A real `Thread` per writer
        // rather than `DispatchQueue.global()`, for the reason CLAUDE.md records: these block on
        // file I/O, and the non-overcommit pool does not grow when its threads block.
        let scratch = Scratch()
        // A value, so the thread bodies capture nothing that is not `Sendable`.
        let history = scratch.history
        let writers = 8
        let each = 12
        let done = DispatchSemaphore(value: 0)
        for writer in 0 ..< writers {
            let thread = Thread {
                for index in 0 ..< each {
                    try? history.append(Self.entry(id: writer * 100 + index,
                                                   recognised: String(repeating: "x", count: 200)))
                }
                done.signal()
            }
            thread.start()
        }
        for _ in 0 ..< writers { done.wait() }

        // Every line parses: a torn line would show up as a shortfall here, since nothing else in
        // this test can lose one.
        let lines = try scratch.history.lines()
        #expect(lines.count == writers * each)
        #expect(Set(lines.map(\.id)).count == writers * each)
        #expect(scratch.raw.filter { $0 == 0x0A }.count == writers * each)
    }

    // MARK: - what the daemon writes (D17, invariant 10)

    @Test("the clean path leaves exactly one entry, holding both stages of the text")
    func cleanPathRecordsOneEntry() throws {
        let harness = DaemonTests.Harness()

        harness.dictate()

        let entries = try harness.history.entries()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.id == 1)
        #expect(entry.outcome == .injected)
        #expect(entry.mode == .clean)
        // Verbatim, hazards and all -- the newline that would have submitted the prompt is in the
        // record, and only the record.
        #expect(entry.recognised == FakeTranscriber.hostileText)
        #expect(entry.final == FakeTranscriber.sanitizedHostileText)
        #expect(entry.target == DaemonTests.target)
        #expect(entry.error == nil)
        #expect(entry.at == harness.clock.now)
        // One line, not two: nothing superseded a delivery that worked.
        #expect(harness.history.appended.count == 1)
    }

    @Test("the raw path records the mode the stopping chord chose")
    func rawPathRecordsItsMode() throws {
        let harness = DaemonTests.Harness()

        harness.dictate(.raw)

        #expect(try harness.history.last()?.mode == .raw)
        #expect(try harness.history.last()?.outcome == .injected)
    }

    @Test("the entry is on disk before the first keystroke is attempted")
    func textReachesTheRecordBeforeInjection() throws {
        // Invariant 10, asserted as the ordering it actually is: the injector reads the record from
        // inside `inject`, which is the one moment at which "before" and "after" differ.
        let history = FakeHistory()
        let injector = SnoopingInjector(record: { (try? history.entries()) ?? [] })
        let harness = DaemonTests.Harness(injector: injector, history: history)

        harness.dictate()

        let seen = injector.recordDuringInjection
        #expect(seen.count == 1)
        #expect(seen.first?.recognised == FakeTranscriber.hostileText)
        #expect(seen.first?.final == FakeTranscriber.sanitizedHostileText)
    }

    @Test("an attempt that never reached recognition is still recorded", arguments: [
        "warming", "recording", "draining",
    ])
    func abortedAttemptsAreRecorded(state: String) throws {
        // D17: an outcome and a reason with no text is the honest record. A gap would read as a
        // dictation that never happened, which is the failure property 2 is about.
        let harness = DaemonTests.Harness()
        let id = state == "warming" ? (harness.chord().attempt ?? 0) : harness.startRecording()
        if state == "draining" { harness.chord() }

        harness.send(Request(cmd: .abort))

        let entries = try harness.history.entries()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.id == id)
        #expect(entry.outcome == .aborted)
        #expect(entry.recognised.isEmpty)
        #expect(entry.final.isEmpty)
        #expect(entry.error == "aborted")
        #expect(entry.target == DaemonTests.target)
    }

    @Test("a stop while warming is recorded as aborted, with the reason it was shown")
    func cancelWhileWarmingIsRecorded() throws {
        let harness = DaemonTests.Harness()
        harness.chord()

        harness.chord()

        let entry = try #require(try harness.history.last())
        #expect(entry.outcome == .aborted)
        #expect(entry.error == "stopped before the microphone started")
    }

    @Test("a capture fault is recorded as a fault and never as empty")
    func captureFaultIsRecordedAsHardware() throws {
        let harness = DaemonTests.Harness()
        let id = harness.startRecording()

        harness.capture.reportFault(id, reason: "the input device went away")

        let entry = try #require(try harness.history.last())
        // Invariant 7, in the record as well as in the notification: `empty` here would tell the
        // user next week that they had said nothing.
        #expect(entry.outcome == .captureFault)
        #expect(entry.outcome != .empty)
        #expect(entry.error == "the input device went away")
        #expect(entry.final.isEmpty)
    }

    @Test("a fault while stopping is recorded as a fault too")
    func faultWhileStoppingIsRecordedAsHardware() throws {
        let harness = DaemonTests.Harness()
        let id = harness.startRecording()
        harness.chord()

        harness.capture.reportFault(id, reason: "the audio session was interrupted")

        #expect(try harness.history.last()?.outcome == .captureFault)
        #expect(try harness.history.entries().count == 1)
    }

    @Test("a whitespace-only transcript is recorded as empty, with the transcript kept")
    func emptyRecognitionKeepsTheTranscript() throws {
        let harness = DaemonTests.Harness()
        harness.transcriber.setText("   \n  ")

        harness.dictate()

        let entry = try #require(try harness.history.last())
        #expect(entry.outcome == .empty)
        // Verbatim, so "the recogniser produced only whitespace" is distinguishable from "the
        // recogniser produced nothing at all" a week later (§9).
        #expect(entry.recognised == "   \n  ")
        #expect(entry.final.isEmpty)
        #expect(entry.error == "nothing was recognised")
    }

    @Test("a recogniser that throws is recorded with its error and no text")
    func recognitionFailureIsRecorded() throws {
        let harness = DaemonTests.Harness()
        harness.transcriber.setError(AgtermError.executableMissing("the model"))

        harness.dictate()

        let entry = try #require(try harness.history.last())
        #expect(entry.outcome == .recognitionFailed)
        #expect(entry.recognised.isEmpty)
        #expect(entry.final.isEmpty)
        #expect(entry.error?.contains("the recogniser failed") == true)
    }

    @Test("a filter that fell back is recorded as such, with the text that still arrived")
    func filterFallbackIsRecorded() throws {
        let harness = DaemonTests.Harness()
        harness.filter.setError(DaemonTests.CountingFilter.Failure())

        harness.dictate(.clean)

        let entry = try #require(try harness.history.last())
        // §7: the text arrived, so this is not a failure -- but the fallback is the fact worth
        // keeping, and it supersedes `injected`.
        #expect(entry.outcome == .filterFellBack)
        #expect(entry.final == FakeTranscriber.sanitizedHostileText)
        #expect(entry.error?.contains("the filter did not run") == true)
    }

    @Test("a delivery failure supersedes the saved line rather than adding an attempt",
          arguments: [
              (DeliveryFailure.targetGone(DaemonTests.target, reason: "the pane went"),
               AttemptOutcome.targetGone),
              (DeliveryFailure.notStarted(DaemonTests.target, reason: "agterm refused"),
               AttemptOutcome.injectionFailed),
              (DeliveryFailure.mayBePartial(DaemonTests.target, reason: "killed"),
               AttemptOutcome.injectionPartial),
          ])
    func deliveryFailuresSupersede(failure: DeliveryFailure, outcome: AttemptOutcome) throws {
        let harness = DaemonTests.Harness()
        harness.injector.setFailure(failure)

        harness.dictate()

        // Two lines on disk, one attempt in the record: the first saved the text before the
        // keystrokes were attempted, the second says how they went (§9, invariant 10).
        #expect(harness.history.appended.count == 2)
        #expect(harness.history.appended.first?.outcome == .injected)
        let entries = try harness.history.entries()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.outcome == outcome)
        // The text survives the failure. That is the only reason the pre-injection write exists.
        #expect(entry.final == FakeTranscriber.sanitizedHostileText)
        #expect(entry.recognised == FakeTranscriber.hostileText)
        #expect(entry.error == failure.description)
    }

    @Test("every attempt leaves exactly one entry, whatever ended it")
    func oneEntryPerAttemptAcrossOutcomes() throws {
        let harness = DaemonTests.Harness()

        harness.dictate()                                    // 1: injected
        harness.transcriber.setText("  ")
        harness.dictate()                                    // 2: empty
        harness.transcriber.setText(FakeTranscriber.hostileText)
        harness.injector.setFailure(.notStarted(DaemonTests.target, reason: "agterm refused"))
        harness.dictate()                                    // 3: injection-failed
        harness.injector.setFailure(nil)
        let faulted = harness.startRecording()
        harness.capture.reportFault(faulted, reason: "the engine died")   // 4: capture-fault
        harness.chord()
        harness.send(Request(cmd: .abort))                    // 5: aborted

        let entries = try harness.history.entries()
        // Monotonic, never reused, and in the order they happened (§2, §9).
        #expect(entries.map(\.id) == [1, 2, 3, 4, 5])
        #expect(entries.map(\.outcome) == [.injected, .empty, .injectionFailed, .captureFault,
                                           .aborted])
    }

    @Test("a rejected chord adds no entry of its own")
    func rejectedCommandsAreNotAttempts() throws {
        let harness = DaemonTests.Harness()
        let id = harness.startRecording()

        harness.send(Request(cmd: .start, sessionID: "S1"))
        harness.send(Request(cmd: .stop, mode: .clean, attempt: 99))

        // Neither is an attempt: one was refused, one named an attempt that does not exist. The
        // live attempt's own entry arrives when it ends, and not before.
        #expect(harness.history.appended.isEmpty)
        harness.chord()
        harness.capture.reportDrained(id)
        #expect(try harness.history.entries().count == 1)
    }

    // MARK: - §7: the record failing must not cost the dictation

    @Test("a failing append still delivers the text, then says recovery is unavailable")
    func failingAppendStillInjects() throws {
        let harness = DaemonTests.Harness(history: FailingHistory())

        harness.dictate()

        // §7: still inject if injection is otherwise safe. Losing the dictation as well as the
        // record would make a broken disk cost the user their words twice.
        #expect(harness.injector.lastText == FakeTranscriber.sanitizedHostileText)
        let messages = harness.notifier.messages
        #expect(messages.contains { $0.contains("could not save this dictation") })
        #expect(messages.contains { $0.contains("recovery from the record is unavailable") })
        #expect(harness.daemon.state == .idle)
    }

    @Test("the complaint about the record comes after the keystrokes, not instead of them")
    func historyComplaintFollowsTheInjection() throws {
        // §7's order. A complaint that arrived first would look like a refusal, and the user would
        // stop and check their input line instead of carrying on.
        let holder = DaemonTests.Locked<DaemonTests.Harness?>(nil)
        let injector = SnoopingInjector(messages: { holder.value?.notifier.messages.count ?? -1 })
        let harness = DaemonTests.Harness(injector: injector, history: FailingHistory())
        holder.set(harness)
        // The box → harness → injector → closure → box cycle would keep `Harness.deinit` from ever
        // running, leaving the temp directory behind on every run.
        defer { holder.set(nil) }

        harness.dictate()

        #expect(injector.injections == 1)
        // Nothing had been said when the keystrokes began, and the complaint is there afterwards.
        #expect(injector.messagesBefore == 0)
        #expect(harness.notifier.messages.count == 1)
    }

    // MARK: - reading it back (`dictactl last`)

    @Test("last prints final by default and the verbatim transcript on request")
    func lastReadsBothFields() throws {
        let harness = DaemonTests.Harness()
        harness.dictate()

        let final = harness.send(Request(cmd: .last))
        let verbatim = harness.send(Request(cmd: .last, verbatim: true))

        #expect(final.kind == .accepted)
        #expect(final.text == FakeTranscriber.sanitizedHostileText)
        #expect(final.attempt == 1)
        #expect(final.target == DaemonTests.target)
        // Reading text back is not injection, so the sanitiser does not apply (§9, invariant 1's
        // parenthesis) -- the newline and the double space come back exactly as recognised.
        #expect(verbatim.kind == .accepted)
        #expect(verbatim.text == FakeTranscriber.hostileText)
        #expect(verbatim.text?.contains("\n") == true)
        #expect(verbatim.text?.contains("  ") == true)
    }

    @Test("last on an empty record says so rather than printing nothing")
    func lastWithNoRecord() {
        let harness = DaemonTests.Harness()

        let response = harness.send(Request(cmd: .last))

        #expect(response.kind == .noop)
        #expect(response.text == nil)
        #expect(response.message == "dicta has no record yet")
    }

    @Test("last names the outcome when the attempt produced no text")
    func lastOnATextlessAttempt() throws {
        let harness = DaemonTests.Harness()
        harness.chord()
        harness.send(Request(cmd: .abort))

        let response = harness.send(Request(cmd: .last))

        #expect(response.kind == .noop)
        #expect(response.text == nil)
        let message = try #require(response.message)
        #expect(message.contains("#1"))
        #expect(message.contains("aborted"))
    }

    @Test("last reports a record it cannot read instead of pretending it is empty")
    func lastOnAnUnreadableRecord() throws {
        let harness = DaemonTests.Harness(history: FailingHistory())

        let response = harness.send(Request(cmd: .last))

        #expect(response.kind == .rejected)
        #expect(try #require(response.message).contains("could not read the record"))
    }

    @Test("last reads the most recent attempt, not the first")
    func lastIsTheMostRecent() throws {
        let harness = DaemonTests.Harness()
        harness.dictate()
        harness.transcriber.setText("the second thing")
        harness.dictate()

        #expect(harness.send(Request(cmd: .last)).text == "the second thing")
        #expect(harness.send(Request(cmd: .last, verbatim: true)).text == "the second thing")
    }

    // MARK: - the client's side of it

    @Test("last --recognised asks for the verbatim transcript, and only last takes it")
    func recognisedFlagParses() throws {
        let parsed = try #require(try? ClientCommand.parse(["last", "--recognised"]).get())

        #expect(parsed.request.cmd == .last)
        #expect(parsed.request.verbatim == true)
        // A chord's frame carries only what the chord said, so the flag is absent, not false.
        let plain = try #require(try? ClientCommand.parse(["last"]).get())
        #expect(plain.request.verbatim == nil)

        for verb in ["toggle", "start", "stop", "abort", "status"] {
            let arguments = verb == "toggle" || verb == "start"
                ? [verb, "--session", "S1", "--recognised"]
                : [verb, "--recognised"]
            #expect(ClientCommand.parse(arguments) == .failure(.flagNotAccepted(
                flag: "--recognised", by: Command(rawValue: verb) ?? .status
            )))
        }
    }

    @Test("--recognised consumes no value, so a following flag still parses")
    func recognisedFlagIsAValueOfItsOwn() throws {
        let parsed = try #require(try? ClientCommand.parse(
            ["last", "--recognised", "--control", "/tmp/dicta.sock"]
        ).get())

        #expect(parsed.request.verbatim == true)
        #expect(parsed.controlSocket == "/tmp/dicta.sock")
    }

    @Test("the request carries the flag over the wire")
    func verbatimSurvivesTheWire() throws {
        let request = Request(cmd: .last, verbatim: true)

        let decoded = try Wire.decode(Request.self, from: try Wire.encode(request))

        #expect(decoded == request)
        #expect(decoded.verbatim == true)
    }

    // MARK: - helpers

    /// A history that cannot write and cannot read: §7's row, which no real filesystem produces on
    /// demand without filling a disk.
    final class FailingHistory: History, @unchecked Sendable {
        struct Unavailable: Error, CustomStringConvertible {
            var description: String { "the disk said no" }
        }

        func append(_ entry: RecordEntry) throws { throw Unavailable() }
        func entries() throws -> [RecordEntry] { throw Unavailable() }
    }

    /// An injector that looks around from INSIDE the injection, which is the only moment at which
    /// "the text reached the record before the keystrokes" and "the complaint came afterwards" are
    /// falsifiable claims rather than descriptions of a finished list.
    final class SnoopingInjector: Injector, @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: [RecordEntry] = []
        private var calls = 0
        private var notifications = 0
        private let readRecord: @Sendable () -> [RecordEntry]
        private let readMessages: @Sendable () -> Int

        init(record: @escaping @Sendable () -> [RecordEntry] = { [] },
             messages: @escaping @Sendable () -> Int = { 0 }) {
            readRecord = record
            readMessages = messages
        }

        var recordDuringInjection: [RecordEntry] { lock.withLock { snapshot } }
        var injections: Int { lock.withLock { calls } }
        /// Notifications the user had already been shown when the keystrokes began.
        var messagesBefore: Int { lock.withLock { notifications } }

        func inject(_ text: String, into target: Target) throws {
            let entries = readRecord()
            let messages = readMessages()
            lock.withLock {
                snapshot = entries
                notifications = messages
                calls += 1
            }
        }
    }
}
