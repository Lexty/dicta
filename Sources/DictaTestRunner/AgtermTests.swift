import DictaCore
import DictaRuntime
import Foundation
import Testing

/// The agterm adapter, driven against canned `agtermctl` output.
///
/// Canned rather than live, and this is the whole reason the `CommandRunner` seam exists: the rules
/// under test are what happens when the tree names no pane, or two, or a kind this build does not
/// know, or when `agtermctl` is not installed at all. None of those can be produced on demand in a
/// terminal, and the ones that can would need the user's real session to be the fixture.
@Suite("agterm adapter")
struct AgtermTests {
    // MARK: - harness

    /// Records every invocation and answers from a script. The recording is half the assertions
    /// here: "did not re-aim" and "did not type" are claims about commands that must NOT appear.
    final class StubRunner: CommandRunner, @unchecked Sendable {
        struct Invocation: Equatable, Sendable {
            let executable: String
            let arguments: [String]

            var verb: String { arguments.prefix(2).joined(separator: " ") }
        }

        typealias Answer = @Sendable (Invocation) throws -> CommandOutput

        private let lock = NSLock()
        private var log: [Invocation] = []
        private let answer: Answer

        init(_ answer: @escaping Answer) {
            self.answer = answer
        }

        /// The common case: one canned tree, everything else succeeding silently.
        convenience init(tree: String) {
            self.init { invocation in
                invocation.arguments.first == "tree"
                    ? CommandOutput(status: 0, standardOutput: tree)
                    : CommandOutput(status: 0, standardOutput: #"{"ok":true}"#)
            }
        }

        var invocations: [Invocation] { lock.withLock { log } }

        var verbs: [String] { invocations.map(\.verb) }

        func arguments(of verb: String) -> [String]? {
            invocations.first { $0.verb == verb }?.arguments
        }

        func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
            let invocation = Invocation(executable: executable, arguments: arguments)
            lock.withLock { log.append(invocation) }
            return try answer(invocation)
        }
    }

    typealias SurfaceSpec = (kind: String, active: Bool)
    typealias SessionSpec = (id: String, surfaces: [SurfaceSpec])

    /// A tree in the shape the installed agterm actually prints -- verified against
    /// `agtermctl tree --json` on 2026-08-14, down to the surface ids and the `kind`/`active` pair.
    static func tree(_ sessions: [SessionSpec]) -> String {
        let encoded = sessions.map { session in
            let surfaces = session.surfaces.map { surface in
                """
                {"id":"surface:\(session.id):\(surface.kind)","kind":"\(surface.kind)",\
                "active":\(surface.active),"visible":true}
                """
            }.joined(separator: ",")
            return """
            {"id":"\(session.id)","name":"s","scratch":false,"overlay":false,\
            "surfaces":[\(surfaces)]}
            """
        }.joined(separator: ",")
        return """
        {"ok":true,"result":{"tree":{"sidebarVisible":true,"workspaces":\
        [{"id":"w","name":"work","active":true,"sessions":[\(encoded)]}]}}}
        """
    }

    static let oneLeftPane = tree([(id: "S1", surfaces: [(kind: "left", active: true)])])

    static func agterm(_ runner: StubRunner, socket: String? = nil) -> Agterm {
        Agterm(executable: "/opt/homebrew/bin/agtermctl", agtermSocket: socket, runner: runner)
    }

    // MARK: - resolution: the one good shape

    @Test("exactly one active pane resolves to that pane", arguments: Pane.allCases)
    func exactlyOneActivePane(pane: Pane) throws {
        let runner = StubRunner(tree: Self.tree([
            (id: "S1", surfaces: [(kind: pane.rawValue, active: true)]),
        ]))

        let target = try Self.agterm(runner).resolveTarget(sessionID: "S1")

        #expect(target == Target(sessionID: "S1", pane: pane))
        #expect(runner.verbs == ["tree --json"])
    }

    @Test("a split session resolves to the focused half, not to the first one listed")
    func splitResolvesToFocus() throws {
        let runner = StubRunner(tree: Self.tree([
            (id: "S1", surfaces: [(kind: "left", active: false), (kind: "right", active: true)]),
        ]))

        #expect(try Self.agterm(runner).resolveTarget(sessionID: "S1")
            == Target(sessionID: "S1", pane: .right))
    }

    @Test("another session's focus is never borrowed")
    func focusIsNotBorrowedAcrossSessions() {
        // The failure this forbids is the one that matters most: the text landing in whichever
        // session happens to be focused, which is somebody else's agent (D4, invariant 3).
        let runner = StubRunner(tree: Self.tree([
            (id: "S1", surfaces: [(kind: "left", active: false)]),
            (id: "S2", surfaces: [(kind: "left", active: true)]),
        ]))

        #expect(throws: AgtermError.noActivePane(session: "S1")) {
            try Self.agterm(runner).resolveTarget(sessionID: "S1")
        }
    }

    @Test("the socket the chord was pressed in is passed through")
    func agtermSocketIsPassedThrough() throws {
        // Without it, a second agterm instance's chord resolves against the first instance's tree.
        let runner = StubRunner(tree: Self.oneLeftPane)
        _ = try Self.agterm(runner, socket: "/tmp/agterm-2.sock").resolveTarget(sessionID: "S1")

        #expect(runner.arguments(of: "tree --json")?.suffix(2).map { $0 }
            == ["--socket", "/tmp/agterm-2.sock"])
    }

    // MARK: - resolution: every way it must fail closed (D6)

    @Test("no active pane does not start an attempt")
    func noActivePane() {
        let runner = StubRunner(tree: Self.tree([
            (id: "S1", surfaces: [(kind: "left", active: false)]),
        ]))

        #expect(throws: AgtermError.noActivePane(session: "S1")) {
            try Self.agterm(runner).resolveTarget(sessionID: "S1")
        }
    }

    @Test("a session with no surfaces at all is the same refusal")
    func noSurfaces() {
        let runner = StubRunner(tree: Self.tree([(id: "S1", surfaces: [])]))

        #expect(throws: AgtermError.noActivePane(session: "S1")) {
            try Self.agterm(runner).resolveTarget(sessionID: "S1")
        }
    }

    @Test("two active panes are refused rather than picked between")
    func twoCandidates() {
        let runner = StubRunner(tree: Self.tree([
            (id: "S1", surfaces: [(kind: "left", active: true), (kind: "right", active: true)]),
        ]))

        #expect(throws: AgtermError.ambiguousPane(session: "S1", panes: ["left", "right"])) {
            try Self.agterm(runner).resolveTarget(sessionID: "S1")
        }
    }

    @Test("an active pane of an unknown kind is refused, not accepted as a pane")
    func unrecognisedPane() {
        // A newer agterm growing a fourth surface kind must stop dicta, not make it type into one
        // it has never heard of.
        let runner = StubRunner(tree: Self.tree([
            (id: "S1", surfaces: [(kind: "sidecar", active: true)]),
        ]))

        #expect(throws: AgtermError.unrecognisedPane(session: "S1", kind: "sidecar")) {
            try Self.agterm(runner).resolveTarget(sessionID: "S1")
        }
    }

    @Test("a session that is not in the tree is gone, not empty")
    func sessionAbsent() {
        let runner = StubRunner(tree: Self.tree([
            (id: "S2", surfaces: [(kind: "left", active: true)]),
        ]))

        #expect(throws: AgtermError.sessionNotFound("S1")) {
            try Self.agterm(runner).resolveTarget(sessionID: "S1")
        }
    }

    @Test("malformed JSON is a refusal with a reason, not a crash")
    func malformedTree() {
        for payload in ["{ not json", "", "{\"ok\":true}", "[]"] {
            let runner = StubRunner(tree: payload)
            #expect(throws: (any Error).self) {
                try Self.agterm(runner).resolveTarget(sessionID: "S1")
            }
        }
    }

    @Test("agtermctl exiting non-zero reports agterm's own sentence")
    func treeExitsNonZero() {
        let runner = StubRunner { _ in
            CommandOutput(status: 1, standardOutput: #"{"ok":false,"error":"no such window"}"#)
        }

        #expect(throws: AgtermError.commandFailed(verb: "tree", status: 1,
                                                  message: "no such window")) {
            try Self.agterm(runner).resolveTarget(sessionID: "S1")
        }
    }

    @Test("agtermctl exiting non-zero with only stderr still says something usable")
    func treeExitsWithStderrOnly() {
        let runner = StubRunner { _ in
            CommandOutput(status: 70, standardError: "connection refused\n")
        }

        #expect(throws: AgtermError.commandFailed(verb: "tree", status: 70,
                                                  message: "connection refused")) {
            try Self.agterm(runner).resolveTarget(sessionID: "S1")
        }
    }

    @Test("agtermctl missing from the machine entirely is its own diagnosis")
    func executableMissing() {
        let runner = StubRunner { invocation in
            throw AgtermError.executableMissing(invocation.executable)
        }

        #expect(throws: AgtermError.executableMissing("/opt/homebrew/bin/agtermctl")) {
            try Self.agterm(runner).resolveTarget(sessionID: "S1")
        }
    }

    @Test("locate falls back to PATH, and answers nothing when there is nothing")
    func locateSearchesCandidatesThenPath() throws {
        // A LaunchAgent does not inherit a login shell's PATH (§12), which is why the absolute
        // candidates come first -- and why "not installed anywhere" must be a startup diagnosis
        // rather than a dead chord six hours later.
        let directory = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("dicta-locate-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let planted = directory.appendingPathComponent("agtermctl")
        FileManager.default.createFile(atPath: planted.path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])

        #expect(Agterm.locate(candidates: [], environment: ["PATH": directory.path])
            == planted.path)
        #expect(Agterm.locate(candidates: [planted.path], environment: ["PATH": "/nowhere"])
            == planted.path)
        #expect(Agterm.locate(candidates: [], environment: ["PATH": "/nowhere/at/all"]) == nil)
        #expect(Agterm.locate(candidates: [], environment: [:]) == nil)
    }

    @Test("the real runner refuses a path that is not there rather than reporting a failed command")
    func processRunnerRefusesMissingExecutable() {
        #expect(throws: AgtermError.executableMissing("/nowhere/at/all/agtermctl")) {
            try ProcessRunner().run("/nowhere/at/all/agtermctl", ["tree", "--json"])
        }
    }

    // MARK: - injection

    @Test("the text is typed into the captured pane, byte for byte")
    func injectTypesIntoCapturedPane() throws {
        let runner = StubRunner(tree: Self.oneLeftPane)
        let text = "fix the parser -- it drops the last token"

        try Self.agterm(runner).inject(text, into: Target(sessionID: "S1", pane: .left))

        #expect(runner.verbs == ["tree --json", "session type"])
        let arguments = try #require(runner.arguments(of: "session type"))
        #expect(arguments == ["session", "type", "--pane", "left", "--target", "S1", "--json",
                              "--", text])
        // After `--`, so a dictation that begins with a dash is text and not a flag. Asserting the
        // position rather than merely its presence: `--` after the text would not protect it.
        #expect(arguments.firstIndex(of: "--") == arguments.count - 2)
    }

    @Test("the pane is re-validated before the first keystroke, not after")
    func validationPrecedesTyping() throws {
        let runner = StubRunner(tree: Self.oneLeftPane)
        try Self.agterm(runner).inject("hello", into: Target(sessionID: "S1", pane: .left))

        #expect(runner.verbs.first == "tree --json")
    }

    @Test("a session that has gone is a delivery failure and nothing is typed")
    func targetGoneSession() {
        let runner = StubRunner(tree: Self.tree([
            (id: "S2", surfaces: [(kind: "left", active: true)]),
        ]))

        #expect(throws: (any Error).self) {
            try Self.agterm(runner).inject("hello", into: Target(sessionID: "S1", pane: .left))
        }
        #expect(!runner.verbs.contains("session type"), "text was typed into a dead target")
    }

    @Test("a closed split is a delivery failure, never a fallback to the surviving pane")
    func targetGonePane() throws {
        // The forbidden repair (D4): the right pane is gone, the left one is right there, and
        // typing into it would put the user's prompt in front of a different agent.
        let runner = StubRunner(tree: Self.oneLeftPane)
        let target = Target(sessionID: "S1", pane: .right)

        do {
            try Self.agterm(runner).inject("hello", into: target)
            Issue.record("a closed split was injected into anyway")
        } catch let failure as DeliveryFailure {
            #expect(failure == DeliveryFailure.targetGone(
                target, reason: "the right pane of S1 is gone"
            ))
            #expect(failure.injectionResult == .failed(reason: failure.description))
        }
        #expect(!runner.verbs.contains("session type"))
    }

    @Test("focus having moved is not a reason to follow it")
    func focusMovedIsStillDelivered() throws {
        // Re-validation is about existence, not about focus. The text belongs where the user was
        // when they started speaking (§5).
        let runner = StubRunner(tree: Self.tree([
            (id: "S1", surfaces: [(kind: "left", active: false), (kind: "right", active: true)]),
        ]))

        try Self.agterm(runner).inject("hello", into: Target(sessionID: "S1", pane: .left))

        #expect(runner.arguments(of: "session type")?.contains("left") == true)
    }

    @Test("a refusal from agterm says the input line is untouched")
    func refusalIsNotStarted() throws {
        let runner = StubRunner { invocation in
            invocation.arguments.first == "tree"
                ? CommandOutput(status: 0, standardOutput: Self.oneLeftPane)
                : CommandOutput(status: 1,
                                standardOutput: #"{"ok":false,"error":"no such session: S1"}"#)
        }
        let target = Target(sessionID: "S1", pane: .left)

        do {
            try Self.agterm(runner).inject("hello", into: target)
            Issue.record("a refused injection was reported as delivered")
        } catch let failure as DeliveryFailure {
            #expect(failure == .notStarted(target, reason: "no such session: S1"))
            #expect(failure.injectionResult == .failed(reason: failure.description))
        }
    }

    @Test("a session type that dies partway through must say the insertion may be partial")
    func diedPartwayIsPartial() throws {
        // §7's sharpest row: keystrokes may already be in the terminal, so the user is told it may
        // be incomplete and it is NEVER retried -- a retry would double part of the text.
        let runner = StubRunner { invocation in
            invocation.arguments.first == "tree"
                ? CommandOutput(status: 0, standardOutput: Self.oneLeftPane)
                : CommandOutput(status: -9, standardError: "killed")
        }
        let target = Target(sessionID: "S1", pane: .left)

        do {
            try Self.agterm(runner).inject("hello", into: target)
            Issue.record("a half-finished injection was reported as delivered")
        } catch let failure as DeliveryFailure {
            guard case let .mayBePartial(_, reason) = failure else {
                Issue.record("expected mayBePartial, got \(failure)")
                return
            }
            #expect(reason.contains("-9"))
            #expect(failure.injectionResult == .partial(reason: failure.description))
            #expect(failure.description.contains("may be partial"))
        }
        #expect(runner.verbs.filter { $0 == "session type" }.count == 1,
                "the injection was retried")
    }

    @Test("a session type that cannot be launched is not reported as maybe-partial")
    func launchFailureIsNotStarted() throws {
        let runner = StubRunner { invocation in
            guard invocation.arguments.first == "tree" else {
                throw AgtermError.executableMissing(invocation.executable)
            }
            return CommandOutput(status: 0, standardOutput: Self.oneLeftPane)
        }
        let target = Target(sessionID: "S1", pane: .left)

        do {
            try Self.agterm(runner).inject("hello", into: target)
            Issue.record("an injection that never ran was reported as delivered")
        } catch let failure as DeliveryFailure {
            guard case .notStarted = failure else {
                Issue.record("expected notStarted, got \(failure)")
                return
            }
        }
    }

    // MARK: - feedback (§6)

    @Test("each feedback state sets the indicator §6 names", arguments: Feedback.allCases)
    func feedbackMapping(feedback: Feedback) {
        let runner = StubRunner(tree: Self.oneLeftPane)
        let target = Target(sessionID: "S1", pane: .right)

        Self.agterm(runner).announce(feedback, for: target)

        let arguments = runner.arguments(of: "session status") ?? []
        let expected: (state: String, sound: String?) = switch feedback {
        case .listening: ("active", "Pop")
        case .working: ("active", nil)
        case .done: ("completed", "Tink")
        case .blocked: ("blocked", "Basso")
        }
        #expect(arguments.dropFirst(2).first == expected.state)
        if let sound = expected.sound {
            #expect(arguments.contains(sound))
        } else {
            #expect(!arguments.contains("--sound"), "working is silent (§6)")
        }
        // Always on the attempt's own pane and session: an indicator on the wrong session is a
        // light claiming a recording that is not happening there.
        #expect(arguments.suffix(4).map { $0 } == ["--pane", "right", "--target", "S1"])
    }

    @Test("listening blinks and done resets itself")
    func listeningAndDoneCarryTheirFlags() {
        let target = Target(sessionID: "S1", pane: .left)

        let listening = StubRunner(tree: Self.oneLeftPane)
        Self.agterm(listening).announce(.listening, for: target)
        #expect(listening.arguments(of: "session status")?.contains("--blink") == true)

        let done = StubRunner(tree: Self.oneLeftPane)
        Self.agterm(done).announce(.done, for: target)
        #expect(done.arguments(of: "session status")?.contains("--auto-reset") == true)
    }

    @Test("clearing the indicator puts the session back to idle")
    func clearIndicator() {
        // §7's stale-indicator row: what the daemon does at startup so a crash cannot leave a light
        // claiming a recording that is not happening.
        let runner = StubRunner(tree: Self.oneLeftPane)
        Self.agterm(runner).clearIndicator(for: Target(sessionID: "S1", pane: .left))

        #expect(runner.arguments(of: "session status")
            == ["session", "status", "idle", "--pane", "left", "--target", "S1"])
    }

    @Test("a notification names the session it belongs to")
    func notifyTargetsTheSession() {
        let runner = StubRunner(tree: Self.oneLeftPane)
        Self.agterm(runner).notify("the target is gone", for: Target(sessionID: "S1", pane: .left))

        #expect(runner.arguments(of: "notify the target is gone")
            == ["notify", "the target is gone", "--title", "dicta", "--target", "S1"])
    }

    @Test("a notification agterm cannot show falls back to osascript")
    func notifyFallsBackToOsascript() {
        // agterm may be the very thing that is broken, and a failure the user cannot see is the
        // failure that matters (§7).
        let runner = StubRunner { _ in CommandOutput(status: 1, standardError: "no window") }
        Self.agterm(runner).notify("dicta is not running", for: nil)

        let executables = runner.invocations.map(\.executable)
        #expect(executables == ["/opt/homebrew/bin/agtermctl", "/usr/bin/osascript"])
        #expect(runner.invocations.last?.arguments.last?.contains("dicta is not running") == true)
    }

    @Test("a notification that agterm shows does not also fire osascript")
    func notifyDoesNotDouble() {
        let runner = StubRunner(tree: Self.oneLeftPane)
        Self.agterm(runner).notify("done", for: nil)

        #expect(runner.invocations.count == 1)
    }

    @Test("a quote in a notification cannot break out of the osascript string")
    func notifyQuotesAreEscaped() {
        let runner = StubRunner { _ in CommandOutput(status: 1) }
        Self.agterm(runner).notify(#"say "hi" \ now"#, for: nil)

        let script = try? #require(runner.invocations.last?.arguments.last)
        #expect(script?.contains(#"\"hi\""#) == true)
        #expect(script?.contains(#"\\"#) == true)
    }
}
