import DictaCore
import Foundation
import Testing

/// The sanitiser is the single most safety-critical function in the project: `agtermctl session
/// type` injects real keystrokes with NO bracketed paste, so a surviving newline is a Return that
/// submits a half-written prompt. These tests are the executable form of invariant 2 (§8.2).
///
/// Cyrillic and emoji appear here as `\u{...}` escapes rather than as literals. The repository is
/// English-only with no exceptions so that `Scripts/lint.sh`'s Cyrillic grep has nothing legitimate
/// to find; an escape keeps the source ASCII while still exercising the codepoint.
@Suite("sanitiser")
struct SanitizerTests {
    /// Every character the terminal would act on as "end of line", including the two Unicode
    /// separators a naive `\n` check misses.
    static let lineBreaks: [(name: String, scalar: String)] = [
        ("LF", "\u{000A}"),
        ("CR", "\u{000D}"),
        ("NEL", "\u{0085}"),
        ("LINE SEPARATOR", "\u{2028}"),
        ("PARAGRAPH SEPARATOR", "\u{2029}"),
    ]

    @Test("every line break is removed", arguments: SanitizerTests.lineBreaks)
    func lineBreaksRemoved(breaker: (name: String, scalar: String)) {
        let result = Sanitizer.sanitize("first\(breaker.scalar)second")
        #expect(result == .line("first second"), "\(breaker.name) survived")
    }

    @Test("CRLF collapses to a single space rather than two")
    func crlfCollapses() {
        #expect(Sanitizer.sanitize("first\r\nsecond") == .line("first second"))
    }

    @Test("a line break never welds two words together")
    func lineBreakLeavesASpace() {
        // Deleting the break outright would produce "firstsecond", which is a different sentence.
        guard case let .line(text) = Sanitizer.sanitize("first\nsecond") else {
            Issue.record("expected a line")
            return
        }
        #expect(text == "first second")
    }

    @Test("runs of whitespace collapse to one space")
    func whitespaceCollapses() {
        #expect(Sanitizer.sanitize("a  b") == .line("a b"))
        #expect(Sanitizer.sanitize("a \t \u{00A0}\n\n b") == .line("a b"))
    }

    @Test("leading and trailing whitespace is trimmed")
    func edgesTrimmed() {
        #expect(Sanitizer.sanitize("  hello  ") == .line("hello"))
        #expect(Sanitizer.sanitize("\n\thello\r\n") == .line("hello"))
    }

    @Test("the result never contains a line break of any kind")
    func resultIsSingleLine() {
        let hostile = "  a\nb\r\nc\u{0085}d\u{2028}e\u{2029}f  \t g  "
        guard case let .line(text) = Sanitizer.sanitize(hostile) else {
            Issue.record("expected a line")
            return
        }
        for breaker in Self.lineBreaks {
            #expect(!text.contains(breaker.scalar),
                    "\(breaker.name) survived in \(text.debugDescription)")
        }
        #expect(text == "a b c d e f g")
        #expect(Sanitizer.isInjectable(text))
    }

    @Test("the canned hostile transcript arrives as one line with single spaces")
    func hostileTranscript() {
        // The shape FakeTranscriber will return from Task 5 onwards: a newline, a double space and
        // a trailing space, so that a bypassed sanitiser fails loudly at the first end-to-end run.
        let canned = "first line\nsecond  line with a trailing space "
        #expect(Sanitizer.sanitize(canned) == .line("first line second line with a trailing space"))
    }

    @Test("text that is empty after sanitising is reported as empty, not injected")
    func emptyAfterSanitising() {
        #expect(Sanitizer.sanitize("") == .empty)
        #expect(Sanitizer.sanitize("\n") == .empty)
        #expect(Sanitizer.sanitize("\u{2028}\u{2029}") == .empty)
    }

    @Test("a string of only whitespace is empty")
    func whitespaceOnlyIsEmpty() {
        #expect(Sanitizer.sanitize("   ") == .empty)
        #expect(Sanitizer.sanitize(" \t \r\n ") == .empty)
    }

    @Test("the empty case cannot be read as an injectable string")
    func emptyCarriesNoText() {
        // The return type is what stops a caller from forgetting the empty case: there is no string
        // to reach for, so "inject whatever came back" does not compile into an empty insertion.
        #expect(Sanitizer.sanitize("  ").injectable == nil)
        #expect(Sanitizer.sanitize(" hi ").injectable == "hi")
    }

    @Test("Cyrillic survives untouched")
    func cyrillicSurvives() {
        // "Privet mir" in Cyrillic, split by a newline the sanitiser must turn into one space.
        let input = "  \u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}\n\u{043C}\u{0438}\u{0440} "
        let expected = "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043C}\u{0438}\u{0440}"
        #expect(Sanitizer.sanitize(input) == .line(expected))
    }

    @Test("emoji survive untouched, including multi-scalar clusters")
    func emojiSurvive() {
        // A ZWJ family is several scalars, one of which is a format character. Dropping controls
        // scalar by scalar would shred it; the sanitiser only drops a cluster that is ENTIRELY
        // control characters.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        #expect(Sanitizer.sanitize(" \u{1F600} \(family) ") == .line("\u{1F600} \(family)"))
    }

    @Test("other control characters are dropped without leaving a space")
    func controlsDropped() {
        // BEL and ESC carry no dictated meaning and the terminal would act on them.
        #expect(Sanitizer.sanitize("a\u{0007}b\u{001B}c") == .line("abc"))
    }

    @Test("isInjectable rejects exactly what the sanitiser removes")
    func injectabilityAgreesWithTheSanitiser() {
        #expect(!Sanitizer.isInjectable(""))
        for breaker in Self.lineBreaks {
            #expect(!Sanitizer.isInjectable("a\(breaker.scalar)b"),
                    "\(breaker.name) passed as injectable")
        }
        #expect(Sanitizer.isInjectable("a b"))
    }

    @Test("CRLF is rejected, though it is a single Character equal to neither CR nor LF")
    func crlfIsNotInjectable() {
        // The hole this test exists for. Swift joins CR and LF into ONE grapheme cluster, so the
        // old `Set<Character>` membership test found neither "\r" nor "\n" in "a\r\nb" and reported
        // it injectable -- from the assertion standing immediately before the keystrokes, whose
        // whole job is to stop a Return reaching `agtermctl session type` (D8, invariant 2).
        #expect("a\r\nb".count == 3, "CRLF is one Character; if this changes, so does the hazard")
        #expect(!Sanitizer.isInjectable("a\r\nb"))
        // The sanitiser itself was never fooled -- the cluster is whitespace, so it collapses.
        #expect(Sanitizer.sanitize("a\r\nb") == .line("a b"))
    }

    @Test("isInjectable rejects everything else the sanitiser would change, too")
    func injectabilityIsAgreementAndNotAnApproximation() {
        // A backstop that disagrees with the thing it backs up is not a backstop. These are text
        // the sanitiser does not pass through unchanged, so neither does `isInjectable`.
        #expect(!Sanitizer.isInjectable("   "), "whitespace-only sanitises to .empty")
        #expect(!Sanitizer.isInjectable("a\u{0007}b"), "BEL is dropped by the sanitiser")
        #expect(!Sanitizer.isInjectable(" a b "), "the sanitiser trims")
        #expect(!Sanitizer.isInjectable("a  b"), "the sanitiser collapses runs of whitespace")
        // And its own output always passes, or the daemon would refuse every dictation.
        for raw in ["hello world", " a\r\nb  c ", "\u{1F600} x", "a\u{0007}b"] {
            guard let final = Sanitizer.sanitize(raw).injectable else { continue }
            #expect(Sanitizer.isInjectable(final),
                    "sanitised text must survive the backstop: \(raw)")
        }
    }
}
