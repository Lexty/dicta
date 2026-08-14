import Foundation

// Tier 0: the ordered, user-editable replacement dictionary (D9a), as a parser and an engine that
// are both pure functions. The file it parses is hand-written, so every decision below was made for
// one reader -- the human editing it -- rather than for the implementation:
//
//   • **Rules run top to bottom, each on the result of the one above.** The obvious reading of "an
//     ordered list", and the one a person can simulate in their head line by line. It costs a
//     cascade: a rule can rewrite what an earlier rule produced. That is diagnosable rather than
//     mysterious, because §9's `rules` names every rule that fired, in the order they fired.
//   • **Matching is case-insensitive and word-boundary aware**, which is D9a's own wording. A rule
//     for `swift` must not fire inside a longer word, or "swiftly" becomes "Swiftly" and the user
//     is left editing a dictionary to fix a word they never dictated.
//   • **The replacement is inserted verbatim.** No case restoration, no capitalisation matching.
//     The whole point of a rule is a canonical spelling -- `FluidAudio`, `Package.swift` -- and a
//     clever engine that lower-cased it mid-sentence would be undoing the fix on purpose.
//   • **A malformed line costs only itself** (§7). It is skipped, named by line number, and every
//     other rule still applies: a dictation is never blocked over a config file.
//
// What this deliberately is NOT: a regex engine. Patterns are literal text. A misfiring literal is
// findable by reading the file; a misfiring regex written six weeks ago is not, and step 3 is
// scored on naming the offending rule from the record alone.

/// One rule, exactly as the file spelled it.
public struct ReplacementRule: Equatable, Sendable {
    /// The id the file gave it, which is what §9's `rules` records. It comes from the file rather
    /// than from the rule's position so that it **survives editing**: inserting a rule at the top
    /// renumbers nothing, and a record entry naming `fluidaudio` names the same rule tomorrow.
    public let id: String
    /// Literal text, matched case-insensitively and on word boundaries. Never empty -- an empty
    /// pattern matches everywhere and would loop.
    public let pattern: String
    /// Inserted verbatim. May be empty, which deletes the pattern -- a filler word rule.
    public let replacement: String
    /// Where it came from, 1-based, for a message a human can act on.
    public let line: Int

    public init(id: String, pattern: String, replacement: String, line: Int = 0) {
        self.id = id
        self.pattern = pattern
        self.replacement = replacement
        self.line = line
    }
}

/// A line the parser refused, and why. Carries the line number because "the dictionary is broken"
/// is not something a user can act on and "line 12" is.
public struct DictionaryProblem: Equatable, Sendable, CustomStringConvertible {
    /// `nil` for a problem with the file as a whole -- unreadable, or not UTF-8.
    public let line: Int?
    public let detail: String

    public init(line: Int?, detail: String) {
        self.line = line
        self.detail = detail
    }

    public var description: String {
        line.map { "line \($0): \(detail)" } ?? detail
    }
}

/// A parsed dictionary: the rules that survived, the lines that did not, and which file said so.
public struct ReplacementDictionary: Equatable, Sendable {
    public var rules: [ReplacementRule]
    /// Empty for a healthy dictionary. Non-empty is §7's "degraded" -- notify once, apply the rest.
    public var problems: [DictionaryProblem]
    /// §9's half of `rules`: the dictionary's version or mtime, so "which file said that" is a
    /// question with an answer weeks later.
    public var version: String?

    public init(rules: [ReplacementRule] = [],
                problems: [DictionaryProblem] = [],
                version: String? = nil) {
        self.rules = rules
        self.problems = problems
        self.version = version
    }

    /// No dictionary at all: no rules, no problems, nothing to say. This is what an absent file
    /// parses to, and it is deliberately not "degraded" -- see `FileDictionary` in DictaRuntime.
    public static let none = ReplacementDictionary()

    public var isDegraded: Bool { !problems.isEmpty }

    /// The sentence §7 wants notified, once, when the dictionary is degraded.
    ///
    /// It names the count and the first offending line rather than listing everything: the user is
    /// mid-dictation, and the record carries the full list for when they are not.
    public var degradedReason: String? {
        guard let first = problems.first else { return nil }
        let rest = problems.count - 1
        let others = rest > 0 ? " (and \(rest) more)" : ""
        return "the replacement dictionary is degraded -- \(first)\(others); "
            + "the other \(rules.count) rule\(rules.count == 1 ? "" : "s") still applied"
    }
}

/// The **replaced** stage's output (§2): the text, and what the record needs to explain it.
public struct Replaced: Equatable, Sendable {
    public var text: String
    /// §9's `rules`, ready to store: the ids that fired, in order, and the dictionary's version.
    public var applied: RulesApplied

    public init(text: String, applied: RulesApplied) {
        self.text = text
        self.applied = applied
    }
}

public enum Replacements {
    /// The field separator. A vertical bar because dictated speech does not contain one, so no rule
    /// has to be escaped; the replacement is everything after the second bar, bars included.
    public static let separator: Character = "|"

    // MARK: - parsing

    /// Parses the file's text. Never throws and never returns nothing: a file of pure nonsense
    /// yields no rules and a problem per line, which is exactly §7's "skip only the offending
    /// rules" when every rule offends.
    public static func parse(_ text: String, version: String? = nil) -> ReplacementDictionary {
        var rules: [ReplacementRule] = []
        var problems: [DictionaryProblem] = []
        var seen: Set<String> = []

        // Empty subsequences kept, so the line numbers reported are the file's own.
        //
        // Splitting on the three ASCII endings by hand rather than on `Character.isNewline`, and
        // neither of those choices is idle. `split(separator: "\n")` alone does not split a CRLF
        // file at all -- "\r\n" is ONE Swift grapheme cluster and is not equal to "\n" -- so the
        // whole file would parse as a single malformed rule (measured: this test failed first).
        // And `isNewline` would additionally split on U+2028, U+2029 and NEL, which would make it
        // impossible for a rule to carry one of those in its replacement. §2 states that the
        // dictionary is capable of introducing a line break, and the sanitiser exists downstream
        // precisely to catch it; a format that quietly could not do so would make that claim
        // vacuous and leave the defence untested.
        for (index, raw) in text.split(omittingEmptySubsequences: false,
                                       whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            .enumerated() {
            let number = index + 1
            // `whitespacesAndNewlines` rather than `whitespaces`, so a CRLF file does not carry a
            // carriage return into every replacement -- which would be invisible in an editor and
            // would be injected as a keystroke.
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }

            // `maxSplits: 2`, so a replacement may contain a bar; `omittingEmptySubsequences:
            // false`, so an empty replacement is still a third field rather than a missing one.
            let fields = line.split(separator: separator, maxSplits: 2,
                                    omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 3 else {
                problems.append(DictionaryProblem(
                    line: number,
                    detail: "expected \"id \(separator) pattern \(separator) replacement\""))
                continue
            }
            let (id, pattern, replacement) = (fields[0], fields[1], fields[2])
            guard !id.isEmpty, !id.contains(where: \.isWhitespace) else {
                problems.append(DictionaryProblem(
                    line: number, detail: "the id is empty or contains a space"))
                continue
            }
            guard !pattern.isEmpty else {
                // An empty pattern matches at every position; there is no useful reading of it.
                problems.append(DictionaryProblem(
                    line: number, detail: "rule \"\(id)\" has an empty pattern"))
                continue
            }
            guard seen.insert(id).inserted else {
                // §9's `rules` must name exactly one rule, so the second claimant loses rather than
                // both sharing a name that no longer identifies anything.
                problems.append(DictionaryProblem(
                    line: number, detail: "the id \"\(id)\" is already used by an earlier rule"))
                continue
            }
            rules.append(ReplacementRule(id: id, pattern: pattern, replacement: replacement,
                                         line: number))
        }
        return ReplacementDictionary(rules: rules, problems: problems, version: version)
    }

    // MARK: - applying

    /// Runs every rule, in file order, each over the previous one's output.
    ///
    /// Terminates by construction: a rule never rescans its own replacement (the scan continues
    /// after the text it inserted), and there are finitely many rules, so `a -> aa` is a rewrite
    /// rather than a hang.
    public static func apply(_ dictionary: ReplacementDictionary, to text: String) -> Replaced {
        var current = text
        var fired: [String] = []
        for rule in dictionary.rules {
            let (next, hit) = apply(rule, to: current)
            if hit { fired.append(rule.id) }
            current = next
        }
        return Replaced(text: current,
                        applied: RulesApplied(fired: fired, version: dictionary.version))
    }

    /// One rule over one string: every occurrence that clears the boundary test, left to right.
    /// The flag is "did this rule change anything", which is what §9's `rules` means by "fired".
    public static func apply(_ rule: ReplacementRule, to text: String) -> (String, Bool) {
        guard !rule.pattern.isEmpty else { return (text, false) }
        var out = ""
        var cursor = text.startIndex
        var fired = false
        while cursor < text.endIndex,
              let found = text.range(of: rule.pattern, options: [.caseInsensitive],
                                     range: cursor ..< text.endIndex) {
            if holdsBoundary(in: text, at: found) {
                out += text[cursor ..< found.lowerBound]
                out += rule.replacement
                // After the match in the ORIGINAL text, so the replacement is never rescanned by
                // this rule. Later rules see it, which is the documented cascade.
                cursor = found.upperBound
                fired = true
            } else {
                // A rejected match still consumes its first character, or the same position would
                // be found forever.
                let next = text.index(after: found.lowerBound)
                out += text[cursor ..< next]
                cursor = next
            }
        }
        out += text[cursor...]
        return (out, fired)
    }

    /// What counts as being "inside a word": a letter, a digit, or an underscore, judged over
    /// Unicode -- so Cyrillic and Latin are treated alike, which is the whole point in text that
    /// mixes them.
    public static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// The boundary rule, stated so a human can predict it: **a boundary is required only on a side
    /// where the pattern's own edge is a word character.**
    ///
    /// That is the predictable half of a regex `\b` without the surprising half. A pattern ending
    /// in punctuation -- `c++`, `package.swift` -- imposes no condition on what follows it, whereas
    /// a real `\b` there would demand a letter and the rule would silently never fire.
    ///
    /// The edges are taken from the MATCHED text rather than from the pattern: case-insensitive
    /// matching can change length (the German sharp s against `SS`), and the text is what the
    /// neighbours are adjacent to.
    public static func holdsBoundary(in text: String, at range: Range<String.Index>) -> Bool {
        guard let first = text[range].first, let last = text[range].last else { return false }
        if isWordCharacter(first), range.lowerBound > text.startIndex,
           isWordCharacter(text[text.index(before: range.lowerBound)]) {
            return false
        }
        if isWordCharacter(last), range.upperBound < text.endIndex,
           isWordCharacter(text[range.upperBound]) {
            return false
        }
        return true
    }
}
