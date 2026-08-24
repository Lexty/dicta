import DictaCore
import DictaRecord
import Foundation
import Testing

/// The bounded reader (D27), driven against real files.
///
/// Fixture BYTES rather than a fake, deliberately, for the reason `SegmentAssemblerTests` gives
/// in `acta`: where a FILE is the input, the failures worth catching are about what is on disk —
/// a torn tail a crash left behind, a superseding line further back than the window, a journal
/// larger than one read. A fake would assert the shape of the code and none of that.
@Suite("record reader")
struct RecordReaderTests {
    static func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dicta-reader-\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("record.jsonl")
    }

    static func entry(id: Int, outcome: AttemptOutcome = .injected,
                      final: String = "hello", recognised: String = "hello") -> RecordEntry {
        RecordEntry(id: id,
                    at: Date(timeIntervalSince1970: 1_700_000_000 + Double(id)),
                    outcome: outcome,
                    mode: .clean,
                    recognised: recognised,
                    final: final,
                    target: Target(sessionID: "S", pane: .left))
    }

    static func write(_ entries: [RecordEntry], to url: URL,
                      trailingNewline: Bool = true, extra: String = "") throws {
        var data = Data()
        for entry in entries {
            data.append(try Record.encode(entry))
            data.append(0x0A)
        }
        if !trailingNewline, data.last == 0x0A { data.removeLast() }
        data.append(contentsOf: Array(extra.utf8))
        try data.write(to: url)
    }

    // MARK: - the ordinary cases

    @Test("an absent record is an empty one, not a failure")
    func absentFileIsEmpty() throws {
        let url = try Self.scratch()
        // What a fresh install looks like. A panel opening on it should say "nothing yet".
        let reading = try RecordReader.tail(of: url, entries: 5)
        #expect(reading.entries.isEmpty)
        #expect(reading.reachedStart)
    }

    @Test("an empty file reads as empty")
    func emptyFileIsEmpty() throws {
        let url = try Self.scratch()
        try Data().write(to: url)
        #expect(try RecordReader.tail(of: url, entries: 5).entries.isEmpty)
    }

    @Test("one line reads back as one entry")
    func oneLine() throws {
        let url = try Self.scratch()
        try Self.write([Self.entry(id: 1)], to: url)
        let reading = try RecordReader.tail(of: url, entries: 5)
        #expect(reading.entries.map { $0.id } == [1])
        #expect(reading.reachedStart)
        #expect(reading.malformedLines == 0)
    }

    @Test("fewer are asked for than exist, and the LAST ones come back, oldest first")
    func tailIsTheNewestEntries() throws {
        let url = try Self.scratch()
        try Self.write((1 ... 20).map { Self.entry(id: $0) }, to: url)
        let reading = try RecordReader.tail(of: url, entries: 5)
        // Oldest-first within the window, like the journal it came from — a list that read
        // newest-first would disagree with the file a human opens beside it.
        #expect(reading.entries.map { $0.id } == [16, 17, 18, 19, 20])
        // `reachedStart` is deliberately NOT asserted false here: twenty entries fit in one 16 KiB
        // step, so the reader honestly touches byte zero on its first read. The flag reports what
        // the read did, not what it was asked for — the bound is about BYTES, and it is asserted
        // where it means something, on a journal too big for one step.
    }

    @Test("asking for more than exist returns everything")
    func moreAskedThanExist() throws {
        let url = try Self.scratch()
        try Self.write((1 ... 3).map { Self.entry(id: $0) }, to: url)
        let reading = try RecordReader.tail(of: url, entries: 50)
        #expect(reading.entries.map { $0.id } == [1, 2, 3])
        #expect(reading.reachedStart)
    }

    // MARK: - the cases that bite

    @Test("a torn last line is skipped, and everything above it still reads")
    func tornTailIsSkipped() throws {
        let url = try Self.scratch()
        // What a crash mid-append leaves: the file is append-only, so the damage is always at the
        // end. Refusing to read the whole journal because of it would lose text §9 exists to keep.
        try Self.write((1 ... 3).map { Self.entry(id: $0) }, to: url,
                       extra: "{\"id\":4,\"at\":\"2026-08-2")
        let reading = try RecordReader.tail(of: url, entries: 5)
        #expect(reading.entries.map { $0.id } == [1, 2, 3])
        #expect(reading.malformedLines == 1)
    }

    @Test("a file with no trailing newline still yields its last entry")
    func noTrailingNewline() throws {
        let url = try Self.scratch()
        try Self.write((1 ... 3).map { Self.entry(id: $0) }, to: url, trailingNewline: false)
        #expect(try RecordReader.tail(of: url, entries: 5).entries.map { $0.id } == [1, 2, 3])
    }

    @Test("a superseding line wins, and it is the one met first when reading backwards")
    func supersedingLineWins() throws {
        let url = try Self.scratch()
        // §9: the file cannot be rewritten, so an attempt whose delivery went differently than its
        // saved line claimed gets a SECOND line with the same id, and the reader takes the last.
        try Self.write([
            Self.entry(id: 1),
            Self.entry(id: 2, outcome: .injected, final: "first try"),
            Self.entry(id: 2, outcome: .targetGone, final: "first try"),
        ], to: url)
        let reading = try RecordReader.tail(of: url, entries: 5)
        #expect(reading.entries.count == 2)
        #expect(reading.entries.last?.outcome == .targetGone)
    }

    @Test("counting ATTEMPTS rather than lines is what makes the window mean anything")
    func wantedCountsAttemptsNotLines() throws {
        let url = try Self.scratch()
        // Ten lines, five attempts: every one superseded. A reader that took the last five LINES
        // would answer with three attempts and look like a short journal.
        var entries: [RecordEntry] = []
        for id in 1 ... 5 {
            entries.append(Self.entry(id: id, outcome: .injected))
            entries.append(Self.entry(id: id, outcome: .injectionPartial))
        }
        try Self.write(entries, to: url)
        let reading = try RecordReader.tail(of: url, entries: 5)
        #expect(reading.entries.map { $0.id } == [1, 2, 3, 4, 5])
        #expect(reading.entries.allSatisfy { $0.outcome == .injectionPartial })
    }

    @Test("a cancelled attempt comes back intact, with words and no final")
    func cancelledEntrySurvives() throws {
        let url = try Self.scratch()
        // D26's shape. The UI labels it `cancelled` and offers nothing to copy — and D28's rule
        // does that structurally, because `final` is empty and every affordance reads `final`.
        try Self.write([Self.entry(id: 1, outcome: .aborted, final: "", recognised: "some words")],
                       to: url)
        let entry = try #require(try RecordReader.tail(of: url, entries: 5).entries.first)
        #expect(entry.final.isEmpty)
        #expect(entry.recognised == "some words")
    }

    @Test("D29's returned outcome decodes like any other")
    func returnedDecodes() throws {
        let url = try Self.scratch()
        try Self.write([Self.entry(id: 1, outcome: .returned, final: "for the caller")], to: url)
        let entry = try #require(try RecordReader.tail(of: url, entries: 5).entries.first)
        #expect(entry.outcome == .returned)
        // Unlike a cancelled one, it HAS deliverable text — the pair that reasoning from the
        // outcome's name instead of from `final` gets backwards.
        #expect(!entry.final.isEmpty)
    }

    // MARK: - the property being bought

    @Test("a long journal is not read from the start")
    func readingIsBounded() throws {
        let url = try Self.scratch()
        // Well past one chunk, and past several. This is the whole point of the target: the record
        // is append-only and grows with how long dicta has been useful, and a panel that opens many
        // times a day cannot pay for all of it each time.
        try Self.write((1 ... 4000).map { Self.entry(id: $0) }, to: url)
        let size = try #require(try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size > 512 * 1024, "the fixture is too small to prove anything: \(size) bytes")

        let reading = try RecordReader.tail(of: url, entries: 5)
        #expect(reading.entries.map { $0.id } == [3996, 3997, 3998, 3999, 4000])
        #expect(!reading.reachedStart)
        // The assertion the target exists for. Anything close to `size` here means the reader is
        // walking the journal after all.
        #expect(reading.bytesRead <= RecordReader.chunkBytes * 2,
                "read \(reading.bytesRead) bytes of a \(size)-byte journal")
    }

    @Test("a journal of nothing but supersessions stops at its budget rather than scanning")
    func budgetStopsAPathologicalFile() throws {
        let url = try Self.scratch()
        // One attempt, thousands of lines. Asking for five would otherwise walk to byte zero
        // looking for a fifth distinct id that does not exist — a full scan reached by another
        // route, which is exactly what the budget is for.
        try Self.write((1 ... 4000).map { _ in Self.entry(id: 1) }, to: url)
        let reading = try RecordReader.tail(of: url, entries: 5, budget: 32 * 1024)
        #expect(reading.reachedBudget)
        #expect(!reading.reachedStart)
        #expect(reading.bytesRead <= 32 * 1024 + RecordReader.chunkBytes)
        // And it still answers with what it did find, rather than nothing.
        #expect(reading.entries.map { $0.id } == [1])
    }

    @Test("an entry spanning a chunk boundary is not lost or halved")
    func entriesSpanningChunksSurvive() throws {
        let url = try Self.scratch()
        // Long text, so single entries are large and land across the 16 KiB steps. A reader that
        // mishandled the fragment at the left edge of a chunk would drop or corrupt exactly these.
        let long = String(repeating: "a word ", count: 900)
        let entries = (1 ... 40).map { Self.entry(id: $0, final: long, recognised: long) }
        try Self.write(entries, to: url)
        let reading = try RecordReader.tail(of: url, entries: 6)
        #expect(reading.entries.map { $0.id } == [35, 36, 37, 38, 39, 40])
        #expect(reading.entries.allSatisfy { $0.final == long })
        #expect(reading.malformedLines == 0)
    }

    @Test("blank lines are ignored rather than counted as damage")
    func blankLinesAreNotMalformed() throws {
        let url = try Self.scratch()
        try Self.write((1 ... 2).map { Self.entry(id: $0) }, to: url, extra: "\n\n")
        let reading = try RecordReader.tail(of: url, entries: 5)
        #expect(reading.entries.count == 2)
        #expect(reading.malformedLines == 0)
    }

    @Test("asking for nothing reads nothing")
    func zeroWanted() throws {
        let url = try Self.scratch()
        try Self.write((1 ... 3).map { Self.entry(id: $0) }, to: url)
        let reading = try RecordReader.tail(of: url, entries: 0)
        #expect(reading.entries.isEmpty)
        #expect(reading.bytesRead == 0)
    }

    // MARK: - one reader in the project

    @Test("the bounded reader and the whole-file reader agree")
    func readersAgree() throws {
        let url = try Self.scratch()
        try Self.write([
            Self.entry(id: 1),
            Self.entry(id: 2, outcome: .injected),
            Self.entry(id: 2, outcome: .capped),
            Self.entry(id: 3),
        ], to: url)
        let all = try RecordReader.all(in: url)
        let tail = try RecordReader.tail(of: url, entries: 10).entries
        // Two readers that disagreed about the superseding rule would put `dictactl last` and the
        // panel at odds about the same attempt, which is the failure this target's single ownership
        // of the parsing exists to prevent.
        #expect(all == tail)
    }
}
