import Foundation

// §9's record, as a pure value plus its codec (D19). One entry per attempt, one line of JSON per
// entry, in a file that is only ever appended to.
//
// Three properties of the format are load-bearing rather than incidental:
//
//   • **One line per entry.** JSON escapes every line break, so a `recognised` containing the
//     newline that D8 makes so dangerous still occupies exactly one line. That is what makes a
//     torn tail cost only its own entry, and what makes `O_APPEND` enough for concurrent writers.
//   • **A superseding line wins.** The file cannot be rewritten in place, and the outcome of an
//     attempt is not fully known until injection has been attempted -- while invariant 10 says the
//     text must be on disk *before* that. So an attempt whose delivery goes differently than the
//     saved line claims gets a second line with the same `id`, and the reader takes the last one.
//     The physical file is append-only; `Record.entries` is what "one entry per attempt" means.
//   • **Reading is not injection.** `recognised` comes back exactly as the recogniser produced it,
//     newlines and all (§9, invariant 1's parenthesis). Comparing it with `final` is the only way a
//     replacement misfire is diagnosable, which is the whole reason both are stored.

/// §9's `outcome`: the eleven values the spec lists, and no twelfth.
///
/// The hyphenated raw values are what lands in the file, because the file is read by a human with
/// `tail` at least as often as by this code.
public enum AttemptOutcome: String, Codable, Sendable, CaseIterable {
    /// The keystrokes went in. Whether they arrived is agterm's business; that they were delivered
    /// without error is what this claims.
    case injected
    /// Nothing to inject: the recogniser heard nothing, or a later stage emptied the text. Never
    /// used for a capture failure -- that is `captureFault`, and conflating them is invariant 7.
    case empty
    /// The audio's integrity was in doubt (D16): interruption, route change, engine death, a
    /// wedged attempt. Always discards, always reported as hardware.
    case captureFault = "capture-fault"
    /// The recogniser threw, the model was unavailable, or its output could not be used.
    case recognitionFailed = "recognition-failed"
    /// The filter did not run and **replaced** was injected instead (§7). The text still arrived,
    /// which is why this is not a failure outcome -- it supersedes `injected` because the fallback
    /// is the fact worth keeping.
    case filterFellBack = "filter-fell-back"
    /// The replacement dictionary was missing, unparsable, or had a malformed rule; the rest of the
    /// rules applied and the text still arrived (§7). Task 11 starts emitting it.
    case dictionaryDegraded = "dictionary-degraded"
    /// Re-validation before the keystrokes found the session or the pane gone (D4). Never re-aimed.
    case targetGone = "target-gone"
    /// `session type` never began, so the input line is untouched.
    case injectionFailed = "injection-failed"
    /// `session type` began and then failed: the input line may hold part of the text, and it is
    /// never retried (§7).
    case injectionPartial = "injection-partial"
    /// The duration cap fired (D15). The audio is discarded and nothing is injected, but whatever
    /// text was produced is still here. Task 9 starts emitting it.
    case capped
    /// The user ended the attempt without delivering, or it was cancelled before audio existed.
    case aborted
}

/// §9's `rules`: which replacement rules fired, and which dictionary they came from.
///
/// Present from the start, empty until Task 11 fills it. A field that appears later would make
/// every entry written before it indistinguishable from one where no rule fired.
public struct RulesApplied: Codable, Sendable, Equatable {
    /// The ids of the rules that fired, in the order they were applied.
    public var fired: [String]
    /// The dictionary's version or mtime -- the half of §9 that makes "which file said that" a
    /// question with an answer.
    public var version: String?

    public init(fired: [String] = [], version: String? = nil) {
        self.fired = fired
        self.version = version
    }

    /// No dictionary was involved.
    public static let none = RulesApplied()
}

/// One attempt, in every field §9 names.
///
/// `recognised` and `final` are separate and both mandatory -- empty strings rather than optionals,
/// because "the recogniser produced nothing" and "this field was not written" are the same thing
/// here and an optional would invite the reader to distinguish them.
public struct RecordEntry: Codable, Sendable, Equatable {
    /// The monotonic attempt id (§2). Never reused, so a second line carrying one is a correction
    /// to the same attempt rather than a new one.
    public var id: AttemptID
    public var at: Date
    public var outcome: AttemptOutcome
    /// The mode the stopping chord chose (D3). `clean` for an attempt that never got a stopping
    /// chord -- an abort while warming has no mode, and inventing a third value for the one field
    /// nobody diagnoses anything from would cost more than it explains.
    public var mode: Mode
    /// Verbatim recogniser output, hazards and all. Empty when recognition never happened.
    public var recognised: String
    /// What was injected, or would have been: replaced, filtered or deliberately not, sanitised.
    public var final: String
    public var rules: RulesApplied
    /// Session id and pane (§5), as resolved at the start and never substituted (D4).
    public var target: Target
    /// The reason the user was shown, when there was one. Several reasons are joined, because an
    /// attempt can have both a filter fallback and a delivery failure.
    public var error: String?

    public init(
        id: AttemptID,
        at: Date,
        outcome: AttemptOutcome,
        mode: Mode,
        recognised: String = "",
        final: String = "",
        rules: RulesApplied = .none,
        target: Target,
        error: String? = nil
    ) {
        self.id = id
        self.at = at
        self.outcome = outcome
        self.mode = mode
        self.recognised = recognised
        self.final = final
        self.rules = rules
        self.target = target
        self.error = error
    }
}

/// The record's codec and its reading rules. Pure: the file itself belongs to `DictaRuntime`.
public enum Record {
    /// ISO 8601 with fractional seconds, in UTC. A human reading the file with `tail` is a
    /// first-class user of it (§9), which rules out a bare `timeIntervalSince1970`.
    ///
    /// A computed property rather than a stored one: the style is not `Sendable`, and there is at
    /// most one record write per attempt, so building it costs nothing worth caching.
    private static var dateStyle: Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    }

    public static func timestamp(_ date: Date) -> String {
        date.formatted(dateStyle)
    }

    public static func date(from text: String) throws -> Date {
        if let parsed = try? Date(text, strategy: dateStyle) { return parsed }
        // A hand-edited line, or one written by a build that predates the fractional seconds.
        return try Date(text, strategy: Date.ISO8601FormatStyle())
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        // Sorted keys so that two entries differing in one field differ in one place, which is what
        // a diff of the record is for. Slashes unescaped so a pane or a path stays readable.
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestamp(date))
        }
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            return try date(from: text)
        }
        return decoder
    }

    /// One entry as one newline-terminated line.
    public static func encode(_ entry: RecordEntry) throws -> Data {
        var data = try encoder.encode(entry)
        data.append(0x0A)
        return data
    }

    public static func decode(_ line: Data) throws -> RecordEntry {
        var body = line
        while let last = body.last, last == 0x0A || last == 0x0D {
            body.removeLast()
        }
        return try decoder.decode(RecordEntry.self, from: body)
    }

    /// Every line that parses, in file order, including lines that a later one supersedes.
    ///
    /// A line that does not parse is skipped rather than fatal: a torn tail from a write that was
    /// interrupted must not hide the hundred entries before it, which is the difference between a
    /// record and a liability.
    public static func lines(in data: Data) -> [RecordEntry] {
        data.split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { try? decode(Data($0)) }
    }

    /// One entry per attempt: the last line written for each id, in the order the ids first appear.
    public static func entries(in data: Data) -> [RecordEntry] {
        collapse(lines(in: data))
    }

    /// Applies the superseding rule to entries already in hand. Shared by the file reader and by
    /// the in-memory fake, so the two cannot disagree about what "one entry per attempt" means.
    public static func collapse(_ entries: [RecordEntry]) -> [RecordEntry] {
        var order: [AttemptID] = []
        var latest: [AttemptID: RecordEntry] = [:]
        for entry in entries {
            if latest.updateValue(entry, forKey: entry.id) == nil { order.append(entry.id) }
        }
        return order.compactMap { latest[$0] }
    }
}
