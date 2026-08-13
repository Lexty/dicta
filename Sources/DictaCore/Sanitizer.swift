import Foundation

/// The last thing every piece of text passes through before it becomes keystrokes.
///
/// `agtermctl session type` injects REAL keystrokes with no bracketed paste, so a newline in the
/// text is a Return — it submits whatever is sitting in the input line. A dictated prompt that
/// happens to contain a line break would fire off half-written.
///
/// The defence is structural rather than procedural: collapse everything to a single line here, and
/// route EVERY path through this one function — cleaned text, raw text, the raw text used as a
/// fallback when the filter fails, and `dictactl last`. A sanitiser that a fallback path can walk
/// around is not a sanitiser.
public enum Sanitizer {
    /// Characters a terminal would act on rather than display. `\n`/`\r` submit; the Unicode line
    /// and paragraph separators are line breaks too and would survive a naive `\n` check.
    private static let lineBreaks: Set<Character> = [
        "\n",         // U+000A
        "\r",         // U+000D
        "\u{0085}",   // NEL
        "\u{2028}",   // LINE SEPARATOR
        "\u{2029}",   // PARAGRAPH SEPARATOR
    ]

    public static func sanitize(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        var pendingSpace = false

        for character in text {
            if lineBreaks.contains(character) || character.isWhitespace {
                // Any run of whitespace — including the line breaks we are killing — becomes one
                // space, so removing a break never welds two words together.
                pendingSpace = !out.isEmpty
                continue
            }
            if character.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) {
                // Other C0/C1 controls (BEL, ESC, …) would be interpreted by the terminal. They
                // carry no dictated meaning, so they are dropped without leaving a space behind.
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(character)
        }
        return out
    }

    /// The property the whole design leans on. Used by the tests, and cheap enough to assert on the
    /// real path right before injection — if this ever fails, injecting would submit a half-written
    /// prompt, and refusing is strictly better.
    public static func isInjectable(_ text: String) -> Bool {
        !text.isEmpty && !text.contains { lineBreaks.contains($0) }
    }
}
