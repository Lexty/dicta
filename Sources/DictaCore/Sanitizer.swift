import Foundation

/// The result of sanitising. Two cases, not an optional and not a bare string, because the empty
/// case is a real outcome the caller must handle: §7 says an empty insertion is worse than none, so
/// "inject whatever came back" has to fail to compile rather than fail quietly at the terminal.
public enum SanitizedText: Equatable, Sendable {
    /// Guaranteed non-empty, containing no line break of any kind and no leading or trailing
    /// whitespace. This is **final** (§2) — the only string that is ever injected.
    case line(String)
    /// Nothing survived sanitising. Notify, do not inject.
    case empty

    /// The text, when there is any. Named for its one legitimate use so that reaching for it reads
    /// as a decision rather than as an unwrap.
    public var injectable: String? {
        switch self {
        case let .line(text): text
        case .empty: nil
        }
    }
}

/// The last thing every piece of text passes through before it becomes keystrokes.
///
/// `agtermctl session type` injects REAL keystrokes with no bracketed paste, so a newline in the
/// text is a Return — it submits whatever is sitting in the input line. A dictated prompt that
/// happens to contain a line break would fire off half-written (§1, property 3).
///
/// The defence is structural rather than procedural: collapse everything to a single line here, and
/// route EVERY path through this one function — cleaned text, raw text, and the fallback to
/// **replaced** after a filter failure (invariant 1). A sanitiser a fallback path can walk around
/// is not a sanitiser; the first draft of the step-1 skeleton leaked exactly there.
///
/// It is *last* (§2): the replacement dictionary and the filter are both capable of introducing a
/// newline, so a stage running after it could reintroduce the one hazard it exists to remove.
/// Reading text back out of the record is not injection and is exempt (§9).
public enum Sanitizer {
    /// Characters a terminal would act on as "end of line". `\n` and `\r` submit; the Unicode line
    /// and paragraph separators are line breaks too and would survive a naive `\n` check.
    private static let lineBreaks: Set<Character> = [
        "\u{000A}",   // LF
        "\u{000D}",   // CR
        "\u{0085}",   // NEL
        "\u{2028}",   // LINE SEPARATOR
        "\u{2029}",   // PARAGRAPH SEPARATOR
    ]

    public static func sanitize(_ text: String) -> SanitizedText {
        var out = String()
        out.reserveCapacity(text.count)
        var pendingSpace = false

        for character in text {
            if lineBreaks.contains(character) || character.isWhitespace {
                // Any run of whitespace — including the line breaks being removed — becomes one
                // space, so deleting a break never welds two words together. Leaving `out` empty
                // means a leading run produces no space, and a trailing run's pending space is
                // never flushed: that is the trimming, with no second pass.
                pendingSpace = !out.isEmpty
                continue
            }
            if character.unicodeScalars.allSatisfy(CharacterSet.controlCharacters.contains) {
                // Other C0/C1 controls (BEL, ESC, …) would be interpreted by the terminal and carry
                // no dictated meaning, so they are dropped without leaving a space behind. The test
                // is over the WHOLE grapheme cluster: an emoji joined by U+200D contains a format
                // character, and shredding it scalar by scalar would mangle real text.
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(character)
        }
        return out.isEmpty ? .empty : .line(out)
    }

    /// The property the whole design leans on (invariant 2). Used by the tests, and cheap enough to
    /// assert on the real path immediately before injection — if it ever fails there, injecting
    /// would submit a half-written prompt, and refusing is strictly better.
    public static func isInjectable(_ text: String) -> Bool {
        !text.isEmpty && !text.contains { lineBreaks.contains($0) }
    }
}
