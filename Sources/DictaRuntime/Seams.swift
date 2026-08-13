import DictaCore
import Foundation

/// The three things the daemon does that touch the world, each behind a protocol so the whole
/// lifecycle can be driven in a test with no microphone, no model and no network.
///
/// The protocols are narrow on purpose. `Injector` in particular is ONE method: a second injection
/// backend (some other app's input field) may arrive later, but generalising before it exists would
/// buy configuration surface and cost nothing but complexity. The seam exists to be faked, not to
/// be extended.

// MARK: - Capture

public protocol Capture: Sendable {
    /// Returns only once audio is genuinely flowing. The daemon announces "speak" off the back of
    /// this returning — announcing earlier would train the user to lose their first syllable.
    func start() async throws
    /// Stops and hands over everything captured, as 16 kHz mono float samples.
    func stop() async -> [Float]
    /// Throws the audio away without producing anything.
    func discard() async
}

/// Step 1's capture: no microphone at all. It records only how long the "recording" lasted, which
/// is enough to prove the chord → daemon → agterm path end to end before any TCC prompt exists.
public actor FakeCapture: Capture {
    private var startedAt: Date?
    public private(set) var startCount = 0
    public private(set) var discardCount = 0

    public init() {}

    public func start() async throws {
        startedAt = Date()
        startCount += 1
    }

    public func stop() async -> [Float] {
        defer { startedAt = nil }
        guard let startedAt else { return [] }
        // One sample per millisecond of "speech" — the duration is the only real signal here, and
        // the fake transcriber reads it back so the round trip shows something that changed.
        let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
        return [Float](repeating: 0, count: max(0, milliseconds))
    }

    public func discard() async {
        startedAt = nil
        discardCount += 1
    }
}

// MARK: - Transcription

public protocol Transcriber: Sendable {
    func transcribe(_ samples: [Float]) async throws -> String
}

/// Canned text, deliberately hostile: it contains a newline, a double space and a trailing space.
///
/// That is the point. If the sanitiser is ever bypassed on some path, this text SUBMITS a
/// half-written prompt the moment it is injected — the failure is loud and immediate in step 1,
/// instead of surfacing months later on a stray transcript that happened to contain a line break.
public struct FakeTranscriber: Transcriber {
    public init() {}

    public func transcribe(_ samples: [Float]) async throws -> String {
        let seconds = Double(samples.count) / 1000.0
        return """
            Проверка диктовки: путь от аккорда до строки ввода работает.
            Длительность записи \(String(format: "%.1f", seconds)) секунды.  Конец.
            """
    }
}

// MARK: - Filter

/// The optional clean-up pass over a transcript: text in, text out, and dicta knows nothing about
/// what performs it.
///
/// v1 ships `NoFilter`. The intended default was `claude -p`, which measured 8.6–10.5 s of fixed
/// CLI startup overhead per call — unusable on a path a human is waiting on. The seam survives that
/// finding unchanged, which is the entire reason it is a seam: what changes is one line of
/// configuration, not any code here.
public protocol Filter: Sendable {
    var isConfigured: Bool { get }
    func run(_ text: String) async throws -> String
}

public struct NoFilter: Filter {
    public init() {}
    public var isConfigured: Bool { false }
    public func run(_ text: String) async throws -> String { text }
}

// MARK: - Injection

public protocol Injector: Sendable {
    func inject(_ text: String, into target: InjectionTarget) async throws
}

public struct AgtermInjector: Injector {
    private let agterm: Agterm

    public init(agterm: Agterm = Agterm()) {
        self.agterm = agterm
    }

    public func inject(_ text: String, into target: InjectionTarget) async throws {
        // Re-validate the captured target rather than trusting it. Between `start` and here the
        // user may have closed the session; agterm identifiers are not guaranteed to stay
        // meaningful, and text landing in the wrong agent's prompt is the worst outcome this tool
        // has. There is deliberately no fallback to "whatever is focused now".
        guard agterm.sessionExists(sessionID: target.sessionID, socket: target.socket) else {
            throw Agterm.Failure.sessionGone(target.sessionID)
        }
        try agterm.type(text: text, into: target)
    }
}
