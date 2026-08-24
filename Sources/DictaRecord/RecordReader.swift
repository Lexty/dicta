import DictaCore
import Foundation

// Reading §9's record off disk, in a target of its own.
//
// TWO reasons, and the second is the one that made it a target rather than a file:
//
//   • **Bounded.** `record.jsonl` is append-only and grows for ever. The menu-bar panel opens many
//     times a day and wants the last five entries; parsing the whole file for that is a cost that
//     rises with how long dicta has been useful. This reads backwards from the end and stops.
//   • **Reachable.** The reader lived in `DictaRuntime`, which links FluidAudio. The UI must not
//     (D27, invariant 8), so it could not have used it. This is the same argument that produced
//     `DictaIPC` — a client needs half of something whose other half drags CoreML through dyld —
//     in its second instance, not a new one.
//
// ⚠️ **This bounds READING. It is not a licence to bound the FILE.** The next thought after "the
// panel parses less now" is "so let us rotate the journal", and rotation would break two things
// silently. §9's superseding line wins because the file is append-only and the reader takes the
// last line per id; a rotation that split one id's two lines across files would return the
// SUPERSEDED one — a wrong answer about a specific attempt, with nothing to show that it happened.
// And `acta` correlates meetings against this journal retrospectively, sometimes long after: rotate
// it and old meetings stop matching with an honest "no candidates", which is indistinguishable from
// "there were no dictations". Append-only has three dependents now — §9's rule, this reader, and
// that correlation pass — and the plurality is the point, because an invariant with one named
// dependent gets repealed when that dependent's reason lapses. If rotation is ever wanted, it owes
// a marker saying the journal does not begin at the beginning of time.

/// Reads the append-only record without parsing it from the start.
public enum RecordReader {
    /// How much is read per backwards step. Large enough that the common case — the last handful of
    /// entries — is one read, small enough that a file of unknown size is never mapped whole.
    public static let chunkBytes = 16 * 1024

    /// The default ceiling on how far back a bounded read will go.
    ///
    /// It exists so that a pathological file cannot turn "show me five rows" into a full scan by
    /// another route: a journal of nothing but superseding lines for one attempt would otherwise be
    /// walked to its beginning looking for a fifth distinct id that is not there. Past this it
    /// stops and says so (`reachedBudget`), rather than quietly returning fewer rows as though the
    /// journal were short.
    public static let defaultBudget = 256 * 1024

    /// What a read found, and what it cost.
    public struct Reading: Sendable, Equatable {
        /// Entries oldest-first, with superseded lines already collapsed (§9).
        public var entries: [RecordEntry]
        /// Bytes actually read. The property the bound is about, and what a test asserts against.
        public var bytesRead: Int
        /// Whether the read walked all the way to the first byte of the file.
        public var reachedStart: Bool
        /// Whether it stopped because it ran out of budget rather than out of file. A caller
        /// showing "the last five" when this is true is showing the last five it could afford,
        /// which is a different claim.
        public var reachedBudget: Bool
        /// Lines that could not be decoded. Not an error: the file is append-only and a crash can
        /// leave a torn tail, so exactly one such line at the very end is ordinary. A count rather
        /// than a throw, because a journal with one bad line still has good ones above it and
        /// refusing to read any of them would lose text that §9 exists to preserve.
        public var malformedLines: Int

        public init(entries: [RecordEntry] = [], bytesRead: Int = 0, reachedStart: Bool = false,
                    reachedBudget: Bool = false, malformedLines: Int = 0) {
            self.entries = entries
            self.bytesRead = bytesRead
            self.reachedStart = reachedStart
            self.reachedBudget = reachedBudget
            self.malformedLines = malformedLines
        }
    }

    public enum ReaderError: Error, Equatable, CustomStringConvertible {
        case cannotRead(path: String, reason: String)

        public var description: String {
            switch self {
            case let .cannotRead(path, reason): "\(path) could not be read: \(reason)"
            }
        }
    }

    /// The last `wanted` attempts, newest last.
    ///
    /// **`wanted` counts ATTEMPTS, not lines, and the difference is load-bearing.** An attempt
    /// whose delivery went differently than its saved line claimed gets a second line with that id
    /// (§9), so the last five lines can be three attempts. Reading backwards until five distinct
    /// ids have been seen is what makes the answer mean what the caller asked for.
    ///
    /// Reading backwards is also what makes the superseding rule free: from the end, the FIRST line
    /// seen for an id is the last one written, which is the one §9 says wins.
    public static func tail(
        of url: URL,
        entries wanted: Int,
        budget: Int = defaultBudget
    ) throws -> Reading {
        guard wanted > 0 else { return Reading(reachedStart: false) }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            // An absent file is an empty record, not a failure: it is what a fresh install looks
            // like, and a panel opening on one should say "nothing yet" rather than show an error.
            guard FileManager.default.fileExists(atPath: url.path) else {
                return Reading(reachedStart: true)
            }
            throw ReaderError.cannotRead(path: url.path, reason: "it could not be opened")
        }
        defer { try? handle.close() }

        let size: Int
        do {
            size = Int(try handle.seekToEnd())
        } catch {
            throw ReaderError.cannotRead(path: url.path, reason: "\(error)")
        }
        if size == 0 { return Reading(reachedStart: true) }

        var buffer = Data()
        var offset = size
        var bytesRead = 0
        var collected: [RecordEntry] = []
        var seen: Set<AttemptID> = []
        var malformed = 0
        var reachedBudget = false

        while offset > 0 {
            if bytesRead >= budget {
                reachedBudget = true
                break
            }
            let step = min(chunkBytes, offset, budget - bytesRead)
            offset -= step
            do {
                try handle.seek(toOffset: UInt64(offset))
            } catch {
                throw ReaderError.cannotRead(path: url.path, reason: "\(error)")
            }
            guard let chunk = try? handle.read(upToCount: step), !chunk.isEmpty else {
                throw ReaderError.cannotRead(path: url.path, reason: "a read returned nothing")
            }
            bytesRead += chunk.count
            // The chunk goes in FRONT: `buffer` always runs from the leftmost byte read so far to
            // a boundary already dealt with on the right.
            buffer = chunk + buffer

            // Everything before the first newline is still incomplete — its start is off to the
            // left, in bytes nobody has read — unless the read has reached byte zero, in which case
            // there is nothing further left and it is a whole line.
            var pieces = split(buffer)
            if offset > 0 {
                buffer = pieces.removeFirst()
            } else {
                buffer = Data()
            }
            harvest(pieces, into: &collected, seen: &seen, malformed: &malformed, wanted: wanted)
            if seen.count >= wanted { break }
        }

        return Reading(
            // Collected newest-first while walking backwards; the caller wants a journal, which
            // reads oldest-first like the file it came from.
            entries: collected.reversed(),
            bytesRead: bytesRead,
            reachedStart: offset == 0,
            reachedBudget: reachedBudget,
            malformedLines: malformed
        )
    }

    /// Every entry in the file, superseded lines collapsed (§9). The unbounded read, kept because
    /// `dictactl last --recognised`-style diagnosis and the tests both want the whole journal, and
    /// because having exactly one place that turns bytes into entries is the point of this target.
    public static func all(in url: URL) throws -> [RecordEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            return Record.entries(in: try Data(contentsOf: url))
        } catch {
            throw ReaderError.cannotRead(path: url.path, reason: "\(error)")
        }
    }

    // MARK: - the byte work

    /// Splits on newlines, keeping every piece including empty ones and the trailing remainder.
    ///
    /// Deliberately NOT `Data.split(separator:)`: that drops empty subsequences by default, and the
    /// emptiness is information here — a file ending in a newline produces a final empty piece, and
    /// one that does not ends with the torn tail a crash left behind. The caller distinguishes them
    /// by whether the piece decodes, which is the only test that means anything.
    ///
    /// The FIRST piece is a whole line only when the caller has read to byte zero. Everywhere else
    /// its beginning is still off to the left, and the caller carries it forward.
    static func split(_ buffer: Data) -> [Data] {
        var pieces: [Data] = []
        var start = buffer.startIndex
        var index = buffer.startIndex
        while index < buffer.endIndex {
            if buffer[index] == 0x0A {
                pieces.append(Data(buffer[start ..< index]))
                start = buffer.index(after: index)
            }
            index = buffer.index(after: index)
        }
        pieces.append(Data(buffer[start ..< buffer.endIndex]))
        return pieces
    }

    /// Decodes lines from the END backwards, keeping the first line seen per attempt.
    private static func harvest(
        _ lines: [Data],
        into collected: inout [RecordEntry],
        seen: inout Set<AttemptID>,
        malformed: inout Int,
        wanted: Int
    ) {
        for line in lines.reversed() {
            guard seen.count < wanted else { return }
            let trimmed = line.last == 0x0D ? line.dropLast() : line[...]
            guard !trimmed.isEmpty else { continue }
            guard let entry = try? Record.decode(Data(trimmed)) else {
                malformed += 1
                continue
            }
            // Reading backwards, the first line seen for an id is the LAST one written, which is
            // the one §9 says supersedes. So the collapse costs nothing here — no second pass, and
            // no risk of stopping before the superseding line, because it is the one we meet first.
            guard seen.insert(entry.id).inserted else { continue }
            collected.append(entry)
        }
    }
}
