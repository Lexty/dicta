import DictaCore
import Testing

/// The sanitiser is the one guard between a transcript and real keystrokes. `agtermctl session
/// type` has no bracketed paste, so a surviving newline is a Return that submits a half-written
/// prompt. These assertions are the contract.
@Suite("Санитайзер")
struct SanitizerTests {
    @Test("перевод строки не доживает до вставки")
    func killsNewlines() {
        let text = Sanitizer.sanitize("первая строка\nвторая строка")
        #expect(text == "первая строка вторая строка")
        #expect(Sanitizer.isInjectable(text))
    }

    @Test("все виды разрывов строки, включая юникодные")
    func killsEveryLineBreak() {
        for breakCharacter in ["\n", "\r", "\r\n", "\u{0085}", "\u{2028}", "\u{2029}"] {
            let text = Sanitizer.sanitize("до\(breakCharacter)после")
            #expect(text == "до после", "разрыв \(breakCharacter.unicodeScalars.map(\.value)) уцелел")
            #expect(Sanitizer.isInjectable(text))
        }
    }

    @Test("удаление разрыва не склеивает слова")
    func doesNotWeldWords() {
        #expect(Sanitizer.sanitize("одно\nдва") == "одно два")
        #expect(Sanitizer.sanitize("одно  \n  два") == "одно два")
    }

    @Test("пробелы схлопываются, края обрезаются")
    func collapsesWhitespace() {
        #expect(Sanitizer.sanitize("  много   пробелов  \t тут  ") == "много пробелов тут")
    }

    @Test("управляющие символы выброшены без следа")
    func dropsControlCharacters() {
        #expect(Sanitizer.sanitize("те\u{0007}кст") == "текст")
        #expect(Sanitizer.sanitize("те\u{001B}кст") == "текст")
    }

    @Test("пустое и пробельное не считается пригодным для вставки")
    func rejectsEmpty() {
        #expect(!Sanitizer.isInjectable(""))
        #expect(Sanitizer.sanitize("   \n  ").isEmpty)
    }

    @Test("нормальный текст не портится")
    func leavesGoodTextAlone() {
        let text = "Запусти тесты и покажи, что не прошло."
        #expect(Sanitizer.sanitize(text) == text)
    }
}
