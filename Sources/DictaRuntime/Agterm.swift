import DictaCore
import Foundation

/// Everything dicta knows about agterm, in one place: it shells out to `agtermctl`.
///
/// A CLI rather than the raw control socket on purpose — `agtermctl` is the supported surface, it
/// already handles framing and error shapes, and the whole interaction is a handful of calls per
/// dictation, none of them on a path where a few milliseconds of process spawn matter.
public struct Agterm: Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case notInstalled(String)
        case commandFailed(String, Int32, String)
        case sessionGone(String)

        public var description: String {
            switch self {
            case .notInstalled(let path):
                "agtermctl не найден: \(path)"
            case .commandFailed(let cmd, let code, let err):
                "agtermctl \(cmd) вернул \(code): \(err)"
            case .sessionGone(let id):
                "сессия \(id.prefix(8)) больше не существует"
            }
        }
    }

    public var executable: String

    public init(executable: String = Agterm.defaultExecutable) {
        self.executable = executable
    }

    public static var defaultExecutable: String {
        if let override = ProcessInfo.processInfo.environment["DICTA_AGTERMCTL"], !override.isEmpty {
            return override
        }
        for candidate in ["/opt/homebrew/bin/agtermctl", "/usr/local/bin/agtermctl"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "/opt/homebrew/bin/agtermctl"
    }

    // MARK: - Target resolution

    /// Which pane the user is actually focused in, for a given session.
    ///
    /// This exists because the installed agterm build does NOT export `$AGT_PANE` to custom keymap
    /// commands — its own `keymap.conf` header lists the available tokens and the pane is not among
    /// them. The tree answers the same question and does it better: it reports the live focus rather
    /// than what the keymap runner happened to know, so a session that was split after the chord
    /// fired still resolves correctly.
    public func focusedPane(sessionID: String, socket: String?) throws -> Pane {
        let output = try run(["tree", "--json"] + socketArgs(socket), command: "tree")
        guard let data = output.data(using: .utf8),
              let tree = try? JSONDecoder().decode(TreeResponse.self, from: data)
        else {
            throw Failure.commandFailed("tree", 0, "не разобрал JSON дерева")
        }
        guard let session = tree.session(id: sessionID) else {
            throw Failure.sessionGone(sessionID)
        }
        let active = session.surfaces?.first { $0.active == true } ?? session.surfaces?.first
        return active.flatMap { Pane(rawValue: $0.kind ?? "left") } ?? .left
    }

    /// Whether the captured target is still real. Called immediately BEFORE injecting, not only at
    /// capture: a session that closed mid-dictation must make the text go to the history log and a
    /// notification — never to whichever pane happens to be focused now, because that is somebody
    /// else's agent.
    public func sessionExists(sessionID: String, socket: String?) -> Bool {
        guard let output = try? run(["tree", "--json"] + socketArgs(socket), command: "tree"),
              let data = output.data(using: .utf8),
              let tree = try? JSONDecoder().decode(TreeResponse.self, from: data)
        else { return false }
        return tree.session(id: sessionID) != nil
    }

    // MARK: - Actions

    public func type(text: String, into target: InjectionTarget) throws {
        _ = try run(
            ["session", "type", "--stdin", "--target", target.sessionID, "--pane", target.pane.rawValue]
                + socketArgs(target.socket),
            command: "session type",
            stdin: text
        )
    }

    public func status(
        _ state: String,
        target: InjectionTarget?,
        blink: Bool = false,
        autoReset: Bool = false,
        sound: String? = nil,
        color: String? = nil
    ) {
        var args = ["session", "status", state]
        if blink { args.append("--blink") }
        if autoReset { args.append("--auto-reset") }
        if let sound { args += ["--sound", sound] }
        if let color { args += ["--color", color] }
        if let target {
            args += ["--target", target.sessionID, "--pane", target.pane.rawValue]
            args += socketArgs(target.socket)
        }
        // Feedback is best-effort by design: a failure to paint an indicator must never take down a
        // dictation that otherwise worked.
        _ = try? run(args, command: "session status")
    }

    public func notify(_ body: String, target: InjectionTarget? = nil) {
        var args = ["notify", body, "--title", "dicta"]
        if let target {
            args += ["--target", target.sessionID]
            args += socketArgs(target.socket)
        }
        _ = try? run(args, command: "notify")
    }

    // MARK: - Plumbing

    private func socketArgs(_ socket: String?) -> [String] {
        guard let socket, !socket.isEmpty else { return [] }
        return ["--socket", socket]
    }

    @discardableResult
    private func run(_ args: [String], command: String, stdin: String? = nil) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw Failure.notInstalled(executable)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        if stdin != nil {
            process.standardInput = Pipe()
        }

        try process.run()

        if let stdin, let pipe = process.standardInput as? Pipe {
            pipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? pipe.fileHandleForWriting.close()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw Failure.commandFailed(
                command,
                process.terminationStatus,
                String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}

// MARK: - `agtermctl tree --json`

private struct TreeResponse: Decodable {
    struct Surface: Decodable {
        var kind: String?
        var active: Bool?
    }

    struct Session: Decodable {
        var id: String?
        var surfaces: [Surface]?
    }

    struct Workspace: Decodable {
        var sessions: [Session]?
    }

    struct Tree: Decodable {
        var workspaces: [Workspace]?
    }

    struct Result: Decodable {
        var tree: Tree?
    }

    var ok: Bool?
    var result: Result?

    func session(id: String) -> Session? {
        result?.tree?.workspaces?
            .compactMap(\.sessions)
            .flatMap { $0 }
            .first { $0.id == id }
    }
}
