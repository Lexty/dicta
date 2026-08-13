import DictaCore
import DictaRuntime
import Foundation
import Testing

/// The daemon driven end to end with every seam faked: no microphone, no agterm, no model. What is
/// being asserted here is the wiring the pure machine cannot see — that a failing filter still
/// delivers words, that a dead target never falls back to somebody else's pane, and that the
/// sanitiser sits on every path rather than only the tidy one.
@Suite("Демон")
struct DaemonTests {
    // MARK: - Fakes

    final class RecordingInjector: Injector, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(String, InjectionTarget)] = []
        var failure: (any Error)?

        var injected: [(String, InjectionTarget)] { lock.withLock { stored } }

        func inject(_ text: String, into target: InjectionTarget) async throws {
            if let failure { throw failure }
            lock.withLock { stored.append((text, target)) }
        }
    }

    struct CannedTranscriber: Transcriber {
        var text: String
        func transcribe(_ samples: [Float]) async throws -> String { text }
    }

    struct FailingFilter: Filter {
        struct Boom: Error, CustomStringConvertible { var description: String { "фильтр умер" } }
        var isConfigured: Bool { true }
        func run(_ text: String) async throws -> String { throw Boom() }
    }

    struct EmptyFilter: Filter {
        var isConfigured: Bool { true }
        func run(_ text: String) async throws -> String { "   " }
    }

    struct ShoutingFilter: Filter {
        var isConfigured: Bool { true }
        func run(_ text: String) async throws -> String { text.uppercased() }
    }

    /// An agterm that is never reachable, so no test can accidentally paint a real indicator or
    /// type into a real session. `Agterm` swallows its own failures for status/notify by design;
    /// pane resolution fails loudly, so tests that need `start` to succeed drive the daemon through
    /// a target they supply themselves.
    private func daemon(
        transcriber: some Transcriber,
        filter: some Filter = NoFilter(),
        injector: some Injector,
        history: History
    ) -> Daemon {
        Daemon(
            capture: FakeCapture(),
            transcriber: transcriber,
            filter: filter,
            injector: injector,
            agterm: Agterm(executable: "/nonexistent/agtermctl"),
            history: history,
            maxDuration: 600
        )
    }

    private func temporaryHistory() -> History {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dicta-test-\(UUID().uuidString).jsonl")
        return History(url: url)
    }


    /// Drives one full dictation through the daemon with fakes only: begin with a target we supply
    /// (skipping the live-agterm pane lookup), then stop in the requested mode.
    @discardableResult
    private func dictate(_ daemon: Daemon, mode: StopMode) async -> Response {
        _ = await daemon.begin(target: InjectionTarget(sessionID: "SESSION-TEST", pane: .left))
        return await daemon.handle(Request(cmd: "stop", mode: mode))
    }

    // MARK: - Tests

    @Test("падение фильтра не стоит пользователю его слов")
    func filterFailureFallsBackToRaw() async {
        let injector = RecordingInjector()
        let daemon = daemon(
            transcriber: CannedTranscriber(text: "сырой текст"),
            filter: FailingFilter(),
            injector: injector,
            history: temporaryHistory()
        )
        await dictate(daemon, mode: .clean)
        #expect(injector.injected.first?.0 == "сырой текст")
    }

    @Test("пустой ответ фильтра тоже откатывается на сырой текст")
    func emptyFilterFallsBackToRaw() async {
        let injector = RecordingInjector()
        let daemon = daemon(
            transcriber: CannedTranscriber(text: "сырой текст"),
            filter: EmptyFilter(),
            injector: injector,
            history: temporaryHistory()
        )
        await dictate(daemon, mode: .clean)
        #expect(injector.injected.first?.0 == "сырой текст")
    }

    @Test("режим raw не зовёт фильтр вообще")
    func rawModeSkipsFilter() async {
        let injector = RecordingInjector()
        let daemon = daemon(
            transcriber: CannedTranscriber(text: "сырой текст"),
            filter: ShoutingFilter(),
            injector: injector,
            history: temporaryHistory()
        )
        await dictate(daemon, mode: .raw)
        #expect(injector.injected.first?.0 == "сырой текст")
    }

    @Test("аварийный откат на сырой текст тоже проходит санитайзер")
    func fallbackPathIsSanitized() async {
        let injector = RecordingInjector()
        let daemon = daemon(
            // Транскрипт с переводом строки — ровно то, что отправило бы недописанный промпт.
            transcriber: CannedTranscriber(text: "первая строка\nвторая строка"),
            filter: FailingFilter(),
            injector: injector,
            history: temporaryHistory()
        )
        await dictate(daemon, mode: .clean)
        let text = injector.injected.first?.0 ?? ""
        #expect(text == "первая строка вторая строка")
        #expect(Sanitizer.isInjectable(text))
    }

    @Test("тишина не вставляется вообще")
    func silenceInjectsNothing() async {
        let injector = RecordingInjector()
        let daemon = daemon(
            transcriber: CannedTranscriber(text: "   \n  "),
            injector: injector,
            history: temporaryHistory()
        )
        await dictate(daemon, mode: .clean)
        #expect(injector.injected.isEmpty)
    }

    @Test("исчезнувшая цель не подменяется текущей панелью, текст остаётся в истории")
    func deadTargetKeepsTextAndNeverRetargets() async {
        struct Gone: Error, CustomStringConvertible { var description: String { "сессия закрыта" } }
        let injector = RecordingInjector()
        injector.failure = Gone()
        let history = temporaryHistory()
        let daemon = daemon(
            transcriber: CannedTranscriber(text: "важный промпт"),
            injector: injector,
            history: history
        )
        await dictate(daemon, mode: .raw)

        #expect(injector.injected.isEmpty)
        let entry = history.last()
        #expect(entry?.raw == "важный промпт")
        #expect(entry?.outcome == "failed")
    }

    @Test("успешная диктовка ложится в историю с обоими вариантами текста")
    func historyKeepsRawAndFinal() async {
        let injector = RecordingInjector()
        let history = temporaryHistory()
        let daemon = daemon(
            transcriber: CannedTranscriber(text: "исходный текст"),
            filter: ShoutingFilter(),
            injector: injector,
            history: history
        )
        await dictate(daemon, mode: .clean)

        let entry = history.last()
        #expect(entry?.raw == "исходный текст")
        #expect(entry?.text == "ИСХОДНЫЙ ТЕКСТ")
        #expect(entry?.outcome == "injected")
    }

    @Test("после доставки демон снова в покое")
    func settlesAfterDelivery() async {
        let injector = RecordingInjector()
        let daemon = daemon(
            transcriber: CannedTranscriber(text: "текст"),
            injector: injector,
            history: temporaryHistory()
        )
        await dictate(daemon, mode: .clean)
        let response = await daemon.handle(Request(cmd: "status"))
        #expect(response.state == "idle")
    }

    @Test("неизвестная команда отвергается, состояние не меняется")
    func unknownCommand() async {
        let daemon = daemon(
            transcriber: CannedTranscriber(text: "текст"),
            injector: RecordingInjector(),
            history: temporaryHistory()
        )
        let response = await daemon.handle(Request(cmd: "выдумка"))
        #expect(!response.ok)
        #expect(response.state == "idle")
    }
}
