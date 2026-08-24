import DictaCore
import DictaRuntime
import Foundation
import Testing

/// Tier 0: the replacement dictionary (D9a), which is a pure parser and a pure engine.
///
/// The premise is a measurement rather than a guess. Task 10's probe fed real speech through
/// dicta's own path and found that Parakeet **transliterates English technical terms spoken inside
/// Russian into Cyrillic** -- "FluidAudio" comes back spelled phonetically in Cyrillic letters.
/// That is the mistake these rules undo, and it is why every fixture below is Cyrillic that should
/// become Latin rather than the other way round.
///
/// Cyrillic appears as `\u{...}` escapes for the reason `SanitizerTests` gives: the repository is
/// English-only so that `Scripts/lint.sh`'s Cyrillic grep has nothing legitimate to find, and an
/// escape exercises the codepoint while keeping the source ASCII. The gloss beside each fixture is
/// its Latin transliteration, not a translation.
@Suite("replacements")
struct ReplacementsTests {
    // MARK: - fixtures

    /// "flyuid audio" -- what Parakeet hands back when the user says "FluidAudio" in a Russian
    /// sentence.
    static let flyuidAudio = "\u{0444}\u{043B}\u{044E}\u{0438}\u{0434} "
        + "\u{0430}\u{0443}\u{0434}\u{0438}\u{043E}"
    /// The same, capitalised as the recogniser would at the head of a sentence.
    static let flyuidAudioCaps = "\u{0424}\u{043B}\u{044E}\u{0438}\u{0434} "
        + "\u{0410}\u{0443}\u{0434}\u{0438}\u{043E}"
    /// "audio".
    static let audio = "\u{0430}\u{0443}\u{0434}\u{0438}\u{043E}"
    /// "audiokniga" -- one Cyrillic word that STARTS with the fixture above.
    static let audiobook = "\u{0430}\u{0443}\u{0434}\u{0438}\u{043E}"
        + "\u{043A}\u{043D}\u{0438}\u{0433}\u{0430}"
    /// "svift".
    static let svift = "\u{0441}\u{0432}\u{0438}\u{0444}\u{0442}"
    /// "sviftom" -- the same word inflected, which is how Russian ends most of its nouns.
    static let sviftInflected = "\u{0441}\u{0432}\u{0438}\u{0444}\u{0442}\u{043E}\u{043C}"
    /// "paket svift" -- spoken "Package.swift".
    static let paketSvift = "\u{043F}\u{0430}\u{043A}\u{0435}\u{0442} "
        + "\u{0441}\u{0432}\u{0438}\u{0444}\u{0442}"
    /// "privet".
    static let privet = "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}"

    static func dictionary(_ text: String, version: String? = nil) -> ReplacementDictionary {
        Replacements.parse(text, version: version)
    }

    static func replaced(_ text: String, through source: String) -> Replaced {
        Replacements.apply(dictionary(source), to: text)
    }

    // MARK: - the file format

    @Test("a rule is id, pattern and replacement, separated by bars")
    func parsesARule() {
        let book = Self.dictionary("fluidaudio | \(Self.flyuidAudio) | FluidAudio")
        #expect(book.problems.isEmpty)
        #expect(book.rules == [ReplacementRule(id: "fluidaudio", pattern: Self.flyuidAudio,
                                               replacement: "FluidAudio", line: 1)])
    }

    @Test("blank lines and whole-line comments are skipped, and do not shift line numbers")
    func skipsCommentsAndBlanks() {
        let book = Self.dictionary("""
        # dicta replacements

           # indented comment
        first | one | 1
        """)
        #expect(book.problems.isEmpty)
        #expect(book.rules.map(\.id) == ["first"])
        // The line number is the file's own, which is the only thing a user can act on.
        #expect(book.rules.first?.line == 4)
    }

    @Test("surrounding spaces are trimmed from every field")
    func trimsFields() {
        let book = Self.dictionary("  spaced   |   one two   |   1 2  ")
        #expect(book.rules.first?.pattern == "one two")
        #expect(book.rules.first?.replacement == "1 2")
    }

    @Test("a replacement may be empty, which deletes the pattern")
    func emptyReplacementDeletes() {
        let book = Self.dictionary("filler | erm |")
        #expect(book.problems.isEmpty)
        #expect(book.rules.first?.replacement == "")
        #expect(Replacements.apply(book, to: "so erm anyway").text == "so  anyway")
    }

    @Test("a replacement may contain a bar; only the first two separate fields")
    func replacementMayContainABar() {
        let book = Self.dictionary("pipe | pipe | a | b")
        #expect(book.problems.isEmpty)
        #expect(book.rules.first?.replacement == "a | b")
    }

    @Test("a CRLF file does not carry a carriage return into the replacement")
    func handlesCRLF() {
        // A carriage return is invisible in an editor and IS a keystroke: `agtermctl session type`
        // would submit the input line on it. The sanitiser would catch it downstream, but a rule
        // that quietly contained one would be undiagnosable from the record.
        let book = Self.dictionary("crlf | one | two\r\nsecond | three | four\r\n")
        #expect(book.problems.isEmpty)
        #expect(book.rules.map(\.replacement) == ["two", "four"])
    }

    @Test("the version travels with the dictionary and reaches the record")
    func versionTravels() {
        let book = Self.dictionary("one | a | b", version: "2026-08-14T10:00:00Z")
        let result = Replacements.apply(book, to: "a")
        #expect(result.applied.version == "2026-08-14T10:00:00Z")
        #expect(result.applied.fired == ["one"])
    }

    // MARK: - malformed rules, each costing only itself (§7)

    /// One line per shape the parser refuses. Every one of them is surrounded by healthy rules in
    /// the test below, because §7's requirement is not "reject it" -- it is "skip ONLY it".
    static let malformed: [(name: String, line: String)] = [
        ("no separator at all", "just some text"),
        ("only two fields", "half | a pattern"),
        ("an empty id", " | a pattern | a replacement"),
        ("an id containing a space", "two words | a pattern | a replacement"),
        ("an empty pattern", "hollow |  | a replacement"),
    ]

    @Test("a malformed rule is skipped and every other rule still applies",
          arguments: ReplacementsTests.malformed)
    func malformedRuleIsolated(bad: (name: String, line: String)) {
        let book = Self.dictionary("""
        before | one | 1
        \(bad.line)
        after | two | 2
        """)
        #expect(book.rules.map(\.id) == ["before", "after"], "\(bad.name) took a neighbour with it")
        #expect(book.problems.count == 1)
        #expect(book.problems.first?.line == 2)
        #expect(book.isDegraded)
        // The text still arrives -- a config file never blocks a dictation (§7).
        #expect(Replacements.apply(book, to: "one and two").text == "1 and 2")
    }

    @Test("a duplicate id loses, so the record names exactly one rule")
    func duplicateIDLoses() {
        let book = Self.dictionary("""
        same | one | 1
        same | two | 2
        """)
        #expect(book.rules.map(\.pattern) == ["one"])
        #expect(book.problems.count == 1)
        #expect(book.problems.first?.line == 2)
    }

    @Test("a file of pure nonsense yields no rules and one problem per line")
    func allLinesMalformed() {
        let book = Self.dictionary("nonsense\nmore nonsense")
        #expect(book.rules.isEmpty)
        #expect(book.problems.map(\.line) == [1, 2])
        #expect(Replacements.apply(book, to: "untouched").text == "untouched")
    }

    @Test("the degraded reason names a line and says the rest still applied")
    func degradedReasonIsActionable() throws {
        let book = Self.dictionary("""
        good | one | 1
        nonsense
        also nonsense
        """)
        let reason = try #require(book.degradedReason)
        #expect(reason.contains("line 2"), "the reason must name a line: \(reason)")
        #expect(reason.contains("and 1 more"))
        #expect(reason.contains("1 rule still applied"))
        #expect(ReplacementDictionary.none.degradedReason == nil)
        #expect(!ReplacementDictionary.none.isDegraded)
    }

    // MARK: - ordering (the format's stated semantics)

    @Test("an earlier rule's output IS visible to a later one")
    func rulesCascade() {
        // The format states it: rules run top to bottom, each over the previous one's result. The
        // assertion is here so that a future "optimisation" into a single simultaneous pass is a
        // failing test rather than a silent change in what a user's file means.
        let result = Self.replaced("one", through: """
        first | one | two
        second | two | three
        """)
        #expect(result.text == "three")
        #expect(result.applied.fired == ["first", "second"])
    }

    @Test("a rule never rescans its own replacement, so a growing rule terminates")
    func ruleDoesNotRescanItself() {
        let result = Self.replaced("a a", through: "grow | a | a a")
        #expect(result.text == "a a a a")
        #expect(result.applied.fired == ["grow"])
    }

    @Test("overlapping rules resolve by file order: the earlier one consumes the text")
    func overlappingRules() {
        let result = Self.replaced("new york city", through: """
        city | york city | YC
        state | new york | NY
        """)
        // `city` ran first and took "york city" with it, so `state` finds nothing left to match.
        #expect(result.text == "new YC")
        #expect(result.applied.fired == ["city"])
    }

    @Test("matches within one rule are taken left to right and never overlap")
    func overlapWithinARule() {
        let result = Self.replaced("a a a", through: "pair | a a | b")
        // The scan continues AFTER the text it consumed, so the middle token belongs to the first
        // match and is not matched a second time as the start of another.
        #expect(result.text == "b a")
    }

    @Test("a pattern cannot match inside a word even by overlapping itself")
    func overlapInsideAWordIsRefused() {
        // "aa" appears twice in "aaa" and neither occurrence has a boundary on both sides, so the
        // rule does not fire at all. This is the boundary rule doing its job rather than a gap:
        // an engine that took the leftmost match here would rewrite the inside of a word.
        #expect(Self.replaced("aaa", through: "pair | aa | b").text == "aaa")
    }

    // MARK: - matching (D9a: case-insensitive, word-boundary aware)

    @Test("matching is case-insensitive across both alphabets")
    func caseInsensitive() {
        #expect(Self.replaced("FLUIDAUDIO", through: "f | fluidaudio | FluidAudio").text
            == "FluidAudio")
        #expect(Self.replaced(Self.flyuidAudioCaps,
                              through: "f | \(Self.flyuidAudio) | FluidAudio").text == "FluidAudio")
    }

    @Test("the replacement is inserted verbatim, with no case restoration")
    func replacementIsVerbatim() {
        // The whole point of a rule is a canonical spelling. An engine that matched the source's
        // capitalisation would lower-case `FluidAudio` mid-sentence and undo the fix on purpose.
        let result = Self.replaced("FLUIDAUDIO and fluidaudio",
                                   through: "f | fluidaudio | FluidAudio")
        #expect(result.text == "FluidAudio and FluidAudio")
    }

    @Test("a rule does not fire inside a longer word, in either alphabet")
    func wordBoundariesHold() {
        #expect(Self.replaced("swiftly", through: "s | swift | Swift").text == "swiftly")
        #expect(Self.replaced("a swift end", through: "s | swift | Swift").text == "a Swift end")
        #expect(Self.replaced(Self.audiobook, through: "a | \(Self.audio) | audio").text
            == Self.audiobook)
        #expect(Self.replaced("x \(Self.audio) y", through: "a | \(Self.audio) | audio").text
            == "x audio y")
    }

    @Test("a Russian word ending declines the rule, which is the documented cost")
    func inflectionIsNotMatched() {
        // "sviftom" is "Swift" inflected, and the boundary rule means it does NOT fire. That is the
        // predictable behaviour rather than the clever one: a user who wants the inflected form
        // writes a second rule for it, and the example file says so. Asserted so the cost is
        // visible in the test list rather than discovered in a dictation.
        #expect(Self.replaced(Self.sviftInflected, through: "s | \(Self.svift) | Swift").text
            == Self.sviftInflected)
    }

    @Test("punctuation and Cyrillic both count as boundaries")
    func boundariesInMixedText() {
        let sentence = "\(Self.privet), \(Self.flyuidAudio)!"
        let result = Self.replaced(sentence, through: "f | \(Self.flyuidAudio) | FluidAudio")
        #expect(result.text == "\(Self.privet), FluidAudio!")
    }

    @Test("a pattern whose own edge is punctuation imposes no boundary on that side")
    func punctuationEdgedPattern() {
        // A real regex `\b` after `.swift` would demand a letter next and the rule would silently
        // never fire. The stated rule -- a boundary only where the pattern's edge is a word
        // character -- is the one a human can predict.
        let result = Self.replaced("open \(Self.paketSvift).",
                                   through: "p | \(Self.paketSvift) | Package.swift")
        #expect(result.text == "open Package.swift.")
    }

    @Test("a multi-word pattern matches across the space")
    func multiWordPattern() {
        let result = Self.replaced("say \(Self.flyuidAudio) now",
                                   through: "f | \(Self.flyuidAudio) | FluidAudio")
        #expect(result.text == "say FluidAudio now")
    }

    // MARK: - what the record is given (§9)

    @Test("the rules field names exactly the rules that fired, in order")
    func firedRulesAreExact() {
        let result = Self.replaced("one three", through: """
        first | one | 1
        second | two | 2
        third | three | 3
        """)
        #expect(result.text == "1 3")
        #expect(result.applied.fired == ["first", "third"], "a rule that matched nothing was named")
    }

    @Test("a rule that fires many times is named once")
    func firedOncePerRule() {
        let result = Self.replaced("one one one", through: "first | one | 1")
        #expect(result.text == "1 1 1")
        #expect(result.applied.fired == ["first"])
    }

    @Test("an empty dictionary changes nothing and names no rules")
    func emptyDictionaryIsIdentity() {
        let result = Replacements.apply(.none, to: " hostile\ntext  ")
        #expect(result.text == " hostile\ntext  ")
        #expect(result.applied == RulesApplied.none)
    }

    // MARK: - the hazards the dictionary can introduce

    @Test("a replacement containing a line break survives here and is caught by the sanitiser")
    func lineBreakInAReplacementIsCaughtDownstream() {
        // The dictionary is ALLOWED to produce a line break -- it is text substitution and nothing
        // more. This is precisely why §2 puts the sanitiser last (invariant 1): a stage running
        // after it could reintroduce the one hazard it exists to remove.
        //
        // U+2028 rather than a newline, because the file is line-oriented: a literal newline in the
        // source would be the end of the rule, not part of it. U+2028 is a line break the terminal
        // would act on, it is the one a naive `\n` check misses, and it travels inside one line --
        // so this is the hazard a rule can genuinely carry, not a contrived one.
        let book = Self.dictionary("break | now | first\u{2028}second")
        #expect(book.problems.isEmpty)
        let result = Replacements.apply(book, to: "type now please")
        #expect(result.text.contains("\u{2028}"),
                "the engine must not silently clean up after a rule")
        #expect(!Sanitizer.isInjectable(result.text))
        #expect(Sanitizer.sanitize(result.text) == .line("type first second please"))
    }

    @Test("a replacement that empties the text is visible as such")
    func replacementCanEmptyTheText() {
        // §7: the dictionary must not silently delete a dictation. The engine's job is to report
        // what it did; the daemon turns this into "empty" plus a reason naming the rule.
        let result = Self.replaced("erm", through: "filler | erm |")
        #expect(Sanitizer.sanitize(result.text) == .empty)
        #expect(result.applied.fired == ["filler"])
    }

    // MARK: - the example file that ships

    static var exampleFile: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Sources/DictaTestRunner
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // the repository root
            .appendingPathComponent("docs/replacements.example.conf")
    }

    @Test("the example dictionary that ships parses with no problems")
    func exampleFileIsHealthy() throws {
        // The same anti-drift argument as the keymap snippet: the file is documentation that the
        // daemon will actually parse, and a format change that leaves it behind would be found by
        // the user rather than here.
        let text = try String(contentsOf: Self.exampleFile, encoding: .utf8)
        let book = Replacements.parse(text, version: "example")
        let trouble = book.problems.map(\.description).joined(separator: "; ")
        #expect(book.problems.isEmpty, "the shipped example is degraded: \(trouble)")
        #expect(book.rules.count >= 5)
        #expect(Set(book.rules.map(\.id)).count == book.rules.count)
        // Every rule matches Cyrillic and replaces it with something: that is what Tier 0 is FOR
        // (D9a), and an example that showed anything else would teach the wrong workflow. What is
        // deliberately NOT asserted is that the replacement is Latin. It was, while the file held
        // nothing but names; the vocabulary added on 2026-08-23 also repairs mishearings whose
        // correct form is still Russian -- a garbled string that is no word at all, put back to the
        // word the user said -- and a check demanding Latin would forbid exactly those.
        //
        // The one shape allowed through without Cyrillic is a pattern with no LETTERS in it at all.
        // That is the third pass of the version-number block, where the left-hand side of the join
        // is a digit an earlier rule produced -- `6 .` is the entire pattern, and there is no
        // Cyrillic left in it to require. The carve-out is stated as "no letters" rather than as an
        // exemption list because that is the property that keeps the file's edge: a rule matching
        // an English word still cannot be added, whatever it is called.
        for rule in book.rules {
            let cyrillic = rule.pattern.contains { $0.isCyrillic }
            let letters = rule.pattern.contains { $0.isLetter }
            #expect(cyrillic || !letters,
                    "rule \(rule.id) has no Cyrillic, and is not pure digits and punctuation")
            #expect(!rule.replacement.isEmpty, "rule \(rule.id) deletes text")
        }
    }

    @Test("every rule in the example dictionary still fires with the whole book in front of it")
    func exampleFileHasNoDeadRules() throws {
        // "Put the specific rules above the general ones" is advice at the top of the shipped file,
        // and it was advice the file itself broke: the one-word rule for "Swift" sat above the
        // two-word rule for "Package.swift", whose pattern CONTAINS it. The cascade rewrote the
        // second half of the longer phrase first, and the `package` rule then searched for a phrase
        // that no longer existed. A dead rule is worse than a missing one — the user can read it,
        // and the record's `rules` names the rule that DID fire, which is the field step 3 is
        // scored on. Feeding each rule its own pattern through the entire book turns the advice
        // into a check.
        let text = try String(contentsOf: Self.exampleFile, encoding: .utf8)
        let book = Replacements.parse(text, version: "example")
        for rule in book.rules {
            let result = Replacements.apply(book, to: rule.pattern)
            #expect(result.applied.fired.contains(rule.id),
                    "rule \(rule.id) never fires on its own pattern — an earlier rule ate it")
        }
    }

    /// What marks a line in the shipped file as an expectation rather than prose.
    static let checkPrefix = "# check \(Replacements.separator)"

    @Test("every check line in the example dictionary produces what it claims")
    func exampleFileChecksHold() throws {
        // The file carries its own expectations, written as
        //
        //     # check | <what the recogniser said> | <what the book must turn it into>
        //
        // which is a comment to the parser and an assertion here. `exampleFileHasNoDeadRules`
        // above catches only the case where a rule cannot fire on its OWN pattern; the cascade's
        // other failure -- a rule rewriting the sentence a later rule was written for, with both
        // rules still looking correct on the page -- needs a whole sentence to show up in. Every
        // check line runs through the whole book in file order, so what is pinned here is the
        // behaviour of every rule with the rest of the book in front of it.
        let text = try String(contentsOf: Self.exampleFile, encoding: .utf8)
        let book = Replacements.parse(text, version: "example")
        var checks = 0
        for (index, raw) in text.split(omittingEmptySubsequences: false,
                                       whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix(Self.checkPrefix) else { continue }
            let fields = line.dropFirst(Self.checkPrefix.count)
                .split(separator: Replacements.separator, maxSplits: 1,
                       omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 2, !fields[0].isEmpty else {
                #expect(Bool(false), "line \(index + 1): a check needs an input and an output")
                continue
            }
            checks += 1
            let result = Replacements.apply(book, to: fields[0])
            #expect(result.text == fields[1],
                    "line \(index + 1): the book turned \"\(fields[0])\" into \"\(result.text)\"")
        }
        // A file that quietly lost its checks would leave this test green and asserting nothing --
        // the same shape as a test bundle that builds and never runs (D18).
        #expect(checks >= 10, "the example file has stopped carrying its own checks")
    }

    @Test("the example file's commented-out misfire rule is a rule, not prose")
    func exampleMisfireRuleIsUsable() throws {
        // Step 3 is scored by adding a deliberately wrong rule and naming it from the record. The
        // example ships that rule commented out; uncommenting it must produce a PARSING rule, or
        // the workflow the file documents does not work.
        let text = try String(contentsOf: Self.exampleFile, encoding: .utf8)
        let uncommented = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("#misfire") }
            .map { $0.dropFirst() }
            .joined(separator: "\n")
        #expect(!uncommented.isEmpty, "the example no longer carries a #misfire rule")
        let book = Replacements.parse(String(uncommented))
        #expect(book.problems.isEmpty)
        #expect(book.rules.count == 1)
    }
}

private extension Character {
    /// Cyrillic, judged by codepoint, so the assertion above does not depend on a locale.
    var isCyrillic: Bool {
        unicodeScalars.contains { (0x0400 ... 0x04FF).contains(Int($0.value)) }
    }
}

/// The dictionary as a FILE (D19: the rules are pure and live above; the reading is here).
///
/// What these assert is mostly about what dicta does when the file is not what it hoped for --
/// §7's promise that a config file never costs a dictation is only kept if every shape of a broken
/// one has an answer.
@Suite("dictionary file")
struct FileDictionaryTests {
    /// A temp directory per test, removed when the test's own reference to it goes away; `/tmp` for
    /// the reason the other suites give. A bare `static func directory()` handed back a URL nobody
    /// owned, so every run left four more directories in `/tmp` -- the same `Scratch` shape
    /// `RecordTests` uses, which leaks none.
    final class Scratch {
        let url: URL

        init() {
            url = URL(fileURLWithPath: "/tmp")
                .appendingPathComponent("dicta-dict-\(UUID().uuidString.prefix(8))",
                                        isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        func file(_ name: String) -> URL { url.appendingPathComponent(name) }
    }

    @Test("an absent file is an empty dictionary, and is NOT degraded")
    func absentFileIsSilent() {
        // §7 lists "missing" with "unparsable", and this is where the two part company: a file that
        // has never existed is how a user who does not want a dictionary says so, and notifying
        // them on every dictation would teach them to dismiss dicta's notifications.
        let scratch = Scratch()
        let absent = scratch.file("absent.conf")
        let book = FileDictionary(url: absent).load()
        #expect(book.rules.isEmpty)
        #expect(!book.isDegraded)
        #expect(book.degradedReason == nil)
        #expect(book == .none)
    }

    @Test("a file on disk parses, and its version is its mtime in the record's own format")
    func fileParsesWithItsMtime() throws {
        let scratch = Scratch()
        let url = scratch.file("replacements.conf")
        try "one | a | b\n".write(to: url, atomically: true, encoding: .utf8)

        let book = FileDictionary(url: url).load()

        #expect(book.rules.map(\.id) == ["one"])
        #expect(!book.isDegraded)
        // §9 asks for "the version or mtime". A timestamp in the record's format so that a `rules`
        // field and an `at` field read the same way, and so a backup can be identified by its date.
        let version = try #require(book.version)
        let stamped = try Record.date(from: version)
        let mtime = try #require(FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        #expect(abs(stamped.timeIntervalSince(mtime)) < 0.01)
    }

    @Test("a file that cannot be read is degraded and names itself")
    func unreadableFileIsDegraded() throws {
        let scratch = Scratch()
        let url = scratch.file("locked.conf")
        try "one | a | b\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: url.path) }

        let book = FileDictionary(url: url).load()

        #expect(book.rules.isEmpty)
        #expect(book.isDegraded)
        #expect(book.degradedReason?.contains(url.path) == true)
    }

    @Test("a file that is not valid UTF-8 is degraded rather than mojibake")
    func invalidUTF8IsDegraded() throws {
        // Repairing it would be worse than refusing it: a rule silently containing U+FFFD would
        // never fire, and the user would be left editing a file that looks right.
        let scratch = Scratch()
        let url = scratch.file("binary.conf")
        try Data([0x6F, 0x6E, 0x65, 0x20, 0x7C, 0xFF, 0xFE, 0x7C, 0x62]).write(to: url)

        let book = FileDictionary(url: url).load()

        #expect(book.rules.isEmpty)
        #expect(book.isDegraded)
        #expect(book.degradedReason?.contains("UTF-8") == true)
    }

    @Test("the shipped example file loads through the real reader")
    func exampleFileLoads() {
        // The parser is exercised on it above; this is the whole path a daemon takes, including
        // reading the bytes off disk as UTF-8.
        let book = FileDictionary(url: ReplacementsTests.exampleFile).load()
        #expect(!book.isDegraded)
        #expect(book.rules.count >= 5)
    }
}
