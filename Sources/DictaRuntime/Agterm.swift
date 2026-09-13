import DictaCore
import Foundation

// The adapter over `agtermctl`: the only place in the project that knows agterm's command line.
//
// Everything it does is one of four things -- resolve a target from the live tree, type into it,
// set an indicator, post a notification -- and all four go through a `CommandRunner` seam
// rather than through `Process` directly. That seam is not ceremony: the rules worth asserting here
// are what happens when the tree names no pane, or two, or when `agtermctl` is not installed,
// and none of those can be produced on demand from a live terminal.
//
// Fail closed, everywhere (D6). A target this file cannot name exactly is not a target it guesses
// at: the alternative is somebody else's agent receiving the user's prompt (D4, invariant 3).

/// What one `agtermctl` invocation produced.
public struct CommandOutput: Sendable, Equatable {
    public var status: Int32
    public var standardOutput: String
    public var standardError: String

    public init(status: Int32, standardOutput: String = "", standardError: String = "") {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var succeeded: Bool { status == 0 }
}

/// Running a subprocess, behind a seam so the tests can hand back canned trees and canned failures.
public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput
}

/// Everything the agterm side can refuse to do, in the words the user reads.
public enum AgtermError: Error, Equatable, CustomStringConvertible {
    /// Not installed, or not where it was last seen. §7's loudest configuration failure: every
    /// chord is dead until it is fixed.
    case executableMissing(String)
    case launchFailed(verb: String, reason: String)
    /// The child ran past `ProcessRunner.deadline` and was killed. Its own case rather than a
    /// `launchFailed`, because the two answer opposite questions about the input line: nothing was
    /// launched versus something ran and where it got to is unknown.
    case timedOut(verb: String, seconds: TimeInterval)
    case commandFailed(verb: String, status: Int32, message: String)
    case malformedTree(String)
    case sessionNotFound(String)
    /// The session was in none of the windows this lookup was willing to open, and there were more
    /// of them. Its own case rather than a `sessionNotFound`, because a search that stopped early
    /// has not established that the session is gone -- and `validate` turns "gone" into a delivery
    /// failure the user is told about by name.
    case searchTruncated(session: String, searched: Int, windows: Int)
    /// The session was not in the frontmost window and the remaining windows could not even be
    /// listed. `searchTruncated`'s sibling and for the same reason: one window out of an unknown
    /// number is not a search that has established the session is gone.
    case searchUnavailable(session: String, reason: String)
    /// The tree names no active pane for the session. The attempt does not start (D6).
    case noActivePane(session: String)
    /// More than one. Picking one would be a coin flip with the user's prompt as the stake.
    case ambiguousPane(session: String, panes: [String])
    /// Exactly one, of a kind this build does not know. Accepting it would be D4's forbidden
    /// substitution wearing a different hat.
    case unrecognisedPane(session: String, kind: String)
    /// The hold trigger asked which session is active and the tree named none. Fail closed, exactly
    /// as `noActivePane` does: a keypress carrying no session (D5) has nothing to fall back on,
    /// and "whichever session was active last" is D4's forbidden substitution.
    /// agterm's own native picker is open in this window and is what the user is looking at. Not
    /// a failure of the lookup: the tree answered, and what it said is that the front of the screen
    /// is not a place dicta can put text (D24).
    case pickerOpen(String)
    case noActiveSession
    /// More than one session claims to be active. The tree is not a thing to guess about.
    case ambiguousActiveSession(sessions: [String])

    public var description: String {
        switch self {
        case let .executableMissing(path):
            "agtermctl is not installed at \(path) -- dicta cannot reach agterm"
        case let .launchFailed(verb, reason):
            "agtermctl \(verb) could not be run: \(reason)"
        case let .timedOut(verb, seconds):
            "agtermctl \(verb) did not answer within \(Int(seconds)) s -- agterm is not responding"
        case let .commandFailed(verb, status, message):
            message.isEmpty
                ? "agtermctl \(verb) failed with status \(status)"
                : "agtermctl \(verb) failed: \(message)"
        case let .malformedTree(detail):
            "agterm's session tree could not be read: \(detail)"
        case let .sessionNotFound(session):
            "session \(session) is gone"
        case let .searchTruncated(session, searched, windows):
            "session \(session) was not in the \(searched) of \(windows) agterm windows dicta"
                + " looked in -- refusing to call it gone"
        case let .searchUnavailable(session, reason):
            "session \(session) was not in the frontmost agterm window, and the others could not"
                + " be listed (\(reason)) -- refusing to call it gone"
        case let .noActivePane(session):
            "session \(session) has no active pane -- refusing to guess where the text goes"
        case let .ambiguousPane(session, panes):
            "session \(session) has \(panes.count) active panes (\(panes.joined(separator: ", ")))"
                + " -- refusing to guess where the text goes"
        case .pickerOpen:
            "agterm's picker is open — dicta cannot type into it yet, only into a session"
        case .noActiveSession:
            "agterm's tree names no active session, so there is nowhere to dictate into"
        case let .ambiguousActiveSession(sessions):
            "agterm's tree names \(sessions.count) active sessions at once: "
                + sessions.joined(separator: ", ")
        case let .unrecognisedPane(session, kind):
            "session \(session)'s active pane is a \(kind), which this build does not know"
        }
    }
}

/// A pane as the tree describes it, before it is known to be one dicta can type into.
struct TreeSurface: Equatable {
    var kind: String
    var active: Bool
}

/// `agtermctl`, adapted.
public struct Agterm: Injector, Notifier, Sendable {
    /// Where the tool is looked for, in order. A LaunchAgent's PATH is not a login shell's, so the
    /// absolute paths come first and `PATH` is only the fallback (§12).
    ///
    /// The list itself moved to `AgtermTool` in `DictaCore` when the menu-bar UI became a second
    /// process that shells out to agterm (D27): it cannot link this module, and one operational
    /// fact copied into two binaries is one of them getting fixed alone. This stays as the name the
    /// daemon's own code already used.
    public static let candidatePaths = AgtermTool.candidatePaths

    /// How many agterm windows one session lookup will open a tree on, the frontmost included.
    ///
    /// Bounded rather than exhaustive because every window is another subprocess inside the control
    /// socket's handler lock, and `ProcessRunner.worstCaseCallsPerStop` has to account for each one
    /// of them. Four covers any plausible arrangement of windows; past it the lookup says so
    /// (`AgtermError.searchTruncated`) rather than reporting a session it never looked for as gone.
    public static let maxWindowsSearched = 4

    /// §6's colours. Red for listening, amber for working -- the indicator's default tint says
    /// "an agent is busy", which is precisely the state dicta must not be confused with.
    static let listeningColor = "#FF3B30"
    static let workingColor = "#FFB100"

    public let executable: String
    /// `$AGT_SOCKET` from the keypress, so a non-default agterm instance still resolves rather than
    /// whichever instance answers the default socket first.
    public let agtermSocket: String?
    private let runner: any CommandRunner

    public init(executable: String? = nil,
                agtermSocket: String? = nil,
                runner: any CommandRunner = ProcessRunner()) {
        self.executable = executable ?? Agterm.locate() ?? Agterm.candidatePaths[0]
        self.agtermSocket = agtermSocket
        self.runner = runner
    }

    /// The first `agtermctl` that exists, or `nil` when there is none anywhere -- which is a
    /// startup-time diagnosis, not something to discover on the first chord.
    ///
    /// The candidate list is a parameter so this has a test: on the machine that runs the suite,
    /// `/opt/homebrew/bin/agtermctl` exists, and a lookup that always finds it asserts nothing.
    public static func locate(
        candidates: [String] = Agterm.candidatePaths,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        AgtermTool.locate(candidates: candidates, environment: environment)
    }

    // MARK: - target resolution (§5, D6)

    /// The session id is keypress-accurate; the pane is live focus roughly 40 ms later (F4, §5).
    /// This is where that second half is decided, and where it is refused.
    public func resolveTarget(sessionID: String) throws -> Target {
        let surfaces = try surfaces(ofSession: sessionID)
        let active = surfaces.filter(\.active)
        guard active.count == 1 else {
            throw active.isEmpty
                ? AgtermError.noActivePane(session: sessionID)
                : AgtermError.ambiguousPane(session: sessionID, panes: active.map(\.kind))
        }
        guard let pane = Pane(rawValue: active[0].kind) else {
            throw AgtermError.unrecognisedPane(session: sessionID, kind: active[0].kind)
        }
        return Target(sessionID: sessionID, pane: pane)
    }

    /// The whole target, from live focus, out of ONE `agtermctl tree --json` (D5, §5).
    ///
    /// A chord is expanded by agterm and names the session at the instant of the keypress. A held
    /// key is expanded by nobody, so both halves come from the same live tree — and from the same
    /// READ of it, which is the part worth insisting on. An earlier draft asked for the session
    /// here and let the daemon resolve the pane afterwards through `resolveTarget`. That spent a
    /// second subprocess on the hot path, and each one costs tens of milliseconds from inside the
    /// daemon rather than the ~10 ms a bare `agtermctl tree --json` costs from a shell. Worse than
    /// the cost: the two halves then described two different moments.
    ///
    /// Frontmost-window scope is correct here and is not the trap `surfaces(ofSession:)` documents.
    /// That one sweeps every window because it is looking for a session it was *given*; this one is
    /// asking which session the user is looking at, and the user is looking at the frontmost
    /// window. D22 is what makes that true, by refusing to run at all unless agterm is frontmost.
    public func resolveFocusedTarget(allowingPicker: Bool) throws -> Target {
        let output = try invoke("tree", ["tree", "--json"])
        guard output.succeeded else {
            throw AgtermError.commandFailed(verb: "tree", status: output.status,
                                            message: Self.message(in: output))
        }
        return try Self.focusedTarget(inTree: output.standardOutput,
                                      allowingPicker: allowingPicker)
    }

    /// Re-validation immediately before injection (§5, D4).
    ///
    /// Both halves, and only existence: the pane does not have to still be FOCUSED. Focus having
    /// moved to the sibling pane is not a reason to follow it -- the text belongs where the user
    /// was when they started speaking, and re-aiming is the one thing invariant 3 forbids.
    public func validate(_ target: AgtermTarget) throws {
        let surfaces: [TreeSurface]
        do {
            surfaces = try self.surfaces(ofSession: target.sessionID)
        } catch {
            // An unconfirmed target is never typed into, whatever the reason (invariant 3) -- but
            // WHY it could not be confirmed is not one answer, and §9's `outcome` is the field a
            // human greps to decide what went wrong. Only `sessionNotFound` establishes that the
            // session is gone. `searchTruncated` says in so many words that it does not, and
            // calling it `targetGone` put a sentence in front of the user that contradicts itself
            // inside one line -- "the target is gone: ... -- refusing to call it gone" -- while
            // writing `target-gone` into the record for a session that is almost certainly alive.
            // A missing `agtermctl`, a timeout or a refused command say nothing about the session
            // at all. `notStarted` is the truthful one for all of those: no keystroke was sent.
            throw Self.unconfirmed(.agterm(target), error)
        }
        guard surfaces.contains(where: { $0.kind == target.pane.rawValue }) else {
            throw DeliveryFailure.targetGone(
                .agterm(target),
                reason: "the \(target.pane.rawValue) pane of \(target.sessionID) is gone"
            )
        }
    }

    /// How a failed re-validation is named. `targetGone` is reserved for the one error that has
    /// established the session is gone; everything else is `notStarted`, which claims only what is
    /// certain -- that nothing was typed.
    static func unconfirmed(_ target: Target, _ error: any Error) -> DeliveryFailure {
        if case AgtermError.sessionNotFound = error {
            return .targetGone(target, reason: reason(error))
        }
        return .notStarted(target, reason: reason(error))
    }

    /// The session's panes, looked for in every window rather than only in the frontmost one.
    ///
    /// `agtermctl tree` is **window-scoped** -- its `--window` flag "defaults to the frontmost" --
    /// while every other verb dicta sends is addressed by `--target <uuid>` and matches across all
    /// windows. Treating the two as one scope is how a live session becomes `targetGone`: start
    /// dictating in window A, click into window B, press the stop chord there, and the
    /// re-validation asks B's tree about A's session. The text survives in the record, but the
    /// input line never receives it and the reason the user reads is false.
    ///
    /// The frontmost window is asked first and on its own, because it is the answer on every
    /// ordinary chord: the window a keypress came from is the window that is frontmost.
    private func surfaces(ofSession sessionID: String) throws -> [TreeSurface] {
        do {
            return try surfaces(ofSession: sessionID, inWindow: nil)
        } catch AgtermError.sessionNotFound {
            // Absent from the frontmost window's tree, which is not the same as gone.
        }
        // A `window list` that fails leaves the frontmost window as the whole search -- and a
        // search that could not be enumerated has established nothing about the session, exactly
        // as the cap below has not. Swallowing the failure into an empty list walked straight past
        // the truncation guard (`0 <= 0`) and reported `sessionNotFound`, i.e. `targetGone`, for a
        // session dicta had looked for in one window out of an unknown number: the false sentence
        // this whole sweep exists to stop, reached through the one door that was still open.
        let others: [String]
        do {
            others = try otherWindowIDs()
        } catch {
            throw AgtermError.searchUnavailable(session: sessionID, reason: Self.reason(error))
        }
        let searched = others.prefix(Self.maxWindowsSearched - 1)
        for window in searched {
            do {
                return try surfaces(ofSession: sessionID, inWindow: window)
            } catch AgtermError.sessionNotFound {
                continue
            }
        }
        guard others.count <= searched.count else {
            // The cap is disclosed rather than swallowed: a search that stopped early reporting
            // "the session is gone" is the same false statement in a quieter voice.
            throw AgtermError.searchTruncated(session: sessionID,
                                              searched: searched.count + 1,
                                              windows: others.count + 1)
        }
        throw AgtermError.sessionNotFound(sessionID)
    }

    private func surfaces(ofSession sessionID: String,
                          inWindow window: String?) throws -> [TreeSurface] {
        var arguments = ["tree", "--json"]
        if let window { arguments += ["--window", window] }
        let output = try invoke("tree", arguments)
        guard output.succeeded else {
            throw AgtermError.commandFailed(verb: "tree", status: output.status,
                                            message: Self.message(in: output))
        }
        return try Self.surfaces(inTree: output.standardOutput, session: sessionID)
    }

    /// Every window except the frontmost, which the caller has already looked in.
    private func otherWindowIDs() throws -> [String] {
        let output = try invoke("window list", ["window", "list", "--json"])
        guard output.succeeded else {
            throw AgtermError.commandFailed(verb: "window list", status: output.status,
                                            message: Self.message(in: output))
        }
        return try Self.otherWindowIDs(inList: output.standardOutput)
    }

    // MARK: - injection

    /// Types **final** into the captured target. The text arrives after `--`, so a dictation that
    /// begins with a dash is text and not a flag.
    ///
    /// What is NOT here: a retry. §7 is explicit -- a retry after keystrokes have begun doubles
    /// part of the text, and the user is told the insertion may be partial instead.
    public func inject(_ text: String, into target: Target) throws {
        guard case let .agterm(pane) = target else {
            // The daemon routes a field to its own injector and never here (D31). If one arrives
            // anyway, nothing is typed: agterm has no pane to aim at, and picking the focused one
            // would be D4's forbidden substitution.
            throw DeliveryFailure.notStarted(target,
                                             reason: "a focused field is not an agterm pane")
        }
        try validate(pane)

        let arguments = ["session", "type", "--pane", pane.pane.rawValue,
                         "--target", pane.sessionID, "--json", "--", text]
        let output: CommandOutput
        do {
            output = try invoke("session type", arguments)
        } catch let error as AgtermError {
            if case .timedOut = error {
                // The one failure on this path that may NOT claim the input line is untouched:
                // `agtermctl` ran, typed for as long as it liked, and was killed at the deadline.
                // Where it got to is what nobody knows -- §7's own words for `mayBePartial`.
                throw DeliveryFailure.mayBePartial(target, reason: Self.reason(error))
            }
            // Nothing was launched, so no keystroke can have been delivered. This is the one
            // delivery failure that may honestly claim the input line is untouched.
            throw DeliveryFailure.notStarted(target, reason: Self.reason(error))
        } catch {
            throw DeliveryFailure.notStarted(target, reason: Self.reason(error))
        }
        if output.succeeded { return }
        if let refusal = Self.refusal(in: output) {
            // agterm answered `{"ok":false}`: it decided not to type, before typing anything.
            throw DeliveryFailure.notStarted(target, reason: refusal)
        }
        // It neither typed nor refused cleanly -- it died partway through, and where it got to is
        // exactly what nobody knows. §7 makes that its own row for that reason.
        throw DeliveryFailure.mayBePartial(
            target,
            reason: "agtermctl session type exited with status \(output.status)"
        )
    }

    // MARK: - feedback (§6)

    // A focused field has no session indicator, and its feedback belongs to the notifier the daemon
    // routes it to (D13, D31). Each method below therefore does nothing for one -- not even the
    // osascript fallback, which would be a second notification beside that notifier's.

    public func announce(_ feedback: Feedback, for target: Target) {
        guard case let .agterm(pane) = target else { return }
        _ = try? invoke("session status", Self.statusArguments(feedback, target: pane))
    }

    /// Best effort by design, and loud by preference: if agterm cannot show it, `osascript` can.
    /// agterm may be the very thing that is broken, and §7's point is that the user finds out.
    public func notify(_ message: String, for target: Target?) {
        // After `--`, for the same reason `inject` is: a message is not always a fixed literal --
        // `commandFailed` carries agtermctl's own stderr and `loadFailed` an arbitrary error
        // description -- and one that begins with a dash would be eaten as a flag. §7's whole
        // premise is that these are the failures nobody is watching, so losing one is the worst
        // outcome available.
        if case .focusedField = target { return }
        var arguments = ["notify", "--title", "dicta"]
        if let session = target?.sessionID { arguments += ["--target", session] }
        arguments += ["--", message]
        if let output = try? invoke("notify", arguments), output.succeeded { return }
        let script = "display notification \(Self.quoted(message)) with title \"dicta\""
        _ = try? runner.run("/usr/bin/osascript", ["-e", script])
    }

    public func clearIndicator(for target: Target) {
        guard case let .agterm(pane) = target else { return }
        _ = try? invoke("session status", ["session", "status", "idle",
                                           "--pane", pane.pane.rawValue,
                                           "--target", pane.sessionID])
    }

    static func statusArguments(_ feedback: Feedback, target: AgtermTarget) -> [String] {
        var arguments = ["session", "status"]
        switch feedback {
        case .listening:
            arguments += ["active", "--blink", "--sound", "Pop", "--color", listeningColor]
        case .working:
            arguments += ["active", "--color", workingColor]
        case .done:
            arguments += ["completed", "--auto-reset", "--sound", "Tink"]
        case .blocked:
            // Always paired with a notification carrying the reason: an indicator that goes red
            // with nothing to read is "lost silently" wearing a colour.
            arguments += ["blocked", "--sound", "Basso"]
        }
        return arguments + ["--pane", target.pane.rawValue, "--target", target.sessionID]
    }

    // MARK: - running it

    private func invoke(_ verb: String, _ arguments: [String]) throws -> CommandOutput {
        let arguments = Self.withSocket(agtermSocket, in: arguments)
        do {
            return try runner.run(executable, arguments)
        } catch let AgtermError.timedOut(_, seconds) {
            // The runner knows only the executable; the verb is what the user needs to read, and
            // `inject` needs the case to survive intact to classify the delivery.
            throw AgtermError.timedOut(verb: verb, seconds: seconds)
        } catch let error as AgtermError {
            throw error
        } catch {
            throw AgtermError.launchFailed(verb: verb, reason: "\(error)")
        }
    }

    /// `--socket` goes BEFORE the `--` separator, never after it.
    ///
    /// Everything past `--` is positional, and `agtermctl session type` declares exactly one
    /// positional. Appending the socket at the end therefore turned every injection into
    /// `Error: 2 unexpected arguments: '--socket', '…'` -- and since that exit carries no
    /// `{"ok":false}`, `refusal(in:)` reads nothing and the failure reports as `mayBePartial`:
    /// the user is warned the insertion may be partial when in truth not one keystroke was sent.
    /// The keymap snippet passes `--socket "$AGT_SOCKET"`, so this was the normal path.
    static func withSocket(_ socket: String?, in arguments: [String]) -> [String] {
        guard let socket else { return arguments }
        guard let separator = arguments.firstIndex(of: "--") else {
            return arguments + ["--socket", socket]
        }
        var spliced = arguments
        spliced.insert(contentsOf: ["--socket", socket], at: separator)
        return spliced
    }

    // MARK: - reading what came back

    /// agterm's own sentence, when it produced one. Its JSON error beats stderr: it names the thing
    /// that went wrong ("no such session: …") rather than describing a failed process.
    static func message(in output: CommandOutput) -> String {
        if let refusal = refusal(in: output) { return refusal }
        let stderr = output.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr.isEmpty
            ? output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            : stderr
    }

    /// `{"ok":false,"error":"…"}` -- a deliberate refusal, as opposed to a process that fell over.
    /// The difference decides whether the user is told the input line is untouched.
    static func refusal(in output: CommandOutput) -> String? {
        guard let data = output.standardOutput.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ok"] as? Bool == false
        else { return nil }
        return (object["error"] as? String) ?? "agterm refused the command"
    }

    static func reason(_ error: any Error) -> String {
        (error as? AgtermError)?.description ?? "\(error)"
    }

    /// An AppleScript string literal. The line breaks matter: a raw newline inside one is a syntax
    /// error, so a multi-line reason -- agtermctl's stderr, most of the time -- would lose the
    /// notification on the very path that exists because agterm is already broken.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    // MARK: - the tree

    /// Only the fields target resolution reads. Everything else agterm sends -- titles, cwds, font
    /// sizes -- is ignored on purpose: a decoder that insisted on the whole payload would break on
    /// the next agterm release for no gain.
    private struct TreeEnvelope: Decodable {
        struct Envelope: Decodable { let tree: Tree }
        struct Tree: Decodable {
            let workspaces: [Workspace]
            /// The id of the native picker awaiting an answer **in this window**, absent when there
            /// is none. Window-scoped, like the tree itself, which is exactly the scope D24 wants:
            /// the hold key is aimed at the frontmost window and so is this field.
            let pickPending: String?
        }
        struct Workspace: Decodable {
            let sessions: [Session]?
            /// Read only by the hold trigger's lookup: a session is active *within* a workspace,
            /// so every workspace names one and only the active one's answer is live.
            let active: Bool?
        }

        struct Session: Decodable {
            let id: String
            let surfaces: [Surface]?
            let active: Bool?
        }

        struct Surface: Decodable {
            let kind: String
            let active: Bool?
        }

        let ok: Bool?
        let error: String?
        let result: Envelope?
    }

    /// Only the fields the window sweep reads.
    private struct WindowEnvelope: Decodable {
        struct Envelope: Decodable { let windows: [Window] }
        struct Window: Decodable {
            let id: String
            let active: Bool?
            let open: Bool?
        }

        let ok: Bool?
        let error: String?
        let result: Envelope?
    }

    /// The ids of every window that is open and is NOT the frontmost one. Pure, for the same reason
    /// the tree parser is: a second agterm window cannot be conjured up inside a test.
    public static func otherWindowIDs(inList json: String) throws -> [String] {
        guard let data = json.data(using: .utf8), !data.isEmpty else {
            throw AgtermError.malformedTree("agtermctl window list printed nothing")
        }
        let envelope: WindowEnvelope
        do {
            envelope = try JSONDecoder().decode(WindowEnvelope.self, from: data)
        } catch {
            throw AgtermError.malformedTree("the window list is not the JSON this build expects")
        }
        if envelope.ok == false {
            throw AgtermError.commandFailed(verb: "window list", status: 0,
                                            message: envelope.error ?? "agterm refused to answer")
        }
        guard let result = envelope.result else {
            throw AgtermError.malformedTree("the answer carries no windows")
        }
        return result.windows
            .filter { $0.open != false && $0.active != true }
            .map(\.id)
    }

    /// Pure, for the same reason `surfaces(inTree:session:)` is: a workspace arrangement is a
    /// value here rather than something that has to be clicked into place.
    ///
    /// Two filters, in this order: the **active workspace** first, then the active session inside
    /// it. Anything other than exactly one survivor at either step throws (D6's fail-closed rule).
    ///
    /// On the installed build the first filter is, measured, redundant: a live tree with 9
    /// workspaces marked exactly one session active, and it was in the active workspace (checked
    /// 2026-08-23). It is kept because that is an observation and not a guarantee — agterm does not
    /// document which sessions carry `active`, and a build that started marking the last-used
    /// session of every workspace would, without this filter, hand back one at random from a
    /// workspace the user is not looking at. The failure would be silent and would look exactly
    /// like D4's forbidden substitution.
    public static func focusedTarget(inTree json: String,
                                     allowingPicker: Bool = false) throws -> Target {
        // Before anything else (D24). agterm's picker is agterm's own window, so a dictation begun
        // while one is open passes D22's frontmost check and then delivers into the terminal
        // BEHIND the dialog -- not where the user is looking, and silently. The tree names the
        // picker, so this is knowable from the read that was happening anyway.
        //
        // `allowingPicker` is the one exception and it is not a loophole: it is set only when a
        // caller is waiting for the text (D29), which is precisely the case where the dialog is
        // not somewhere the text was going to go anyway.
        if !allowingPicker, let picker = try decodeTree(json).pickPending, !picker.isEmpty {
            throw AgtermError.pickerOpen(picker)
        }
        let session = try activeSession(inTree: json)
        // Deliberately the SAME pane rule the chord path uses, read out of the same JSON: exactly
        // one recognisable active surface, or nothing (D6). A held key must not be able to reach a
        // pane a chord could not.
        let active = try surfaces(inTree: json, session: session).filter(\.active)
        guard active.count == 1 else {
            throw active.isEmpty
                ? AgtermError.noActivePane(session: session)
                : AgtermError.ambiguousPane(session: session, panes: active.map(\.kind))
        }
        guard let pane = Pane(rawValue: active[0].kind) else {
            throw AgtermError.unrecognisedPane(session: session, kind: active[0].kind)
        }
        return Target(sessionID: session, pane: pane)
    }

    public static func activeSession(inTree json: String) throws -> String {
        let workspaces = try decodeTree(json).workspaces.filter { $0.active == true }
        guard workspaces.count == 1 else {
            // Zero is a tree with nothing focused; more than one cannot happen and is therefore
            // exactly the sort of thing to refuse rather than to pick from.
            let sessions = workspaces.flatMap { ($0.sessions ?? []).map(\.id) }
            throw workspaces.isEmpty
                ? AgtermError.noActiveSession
                : AgtermError.ambiguousActiveSession(sessions: sessions)
        }
        let active = (workspaces[0].sessions ?? []).filter { $0.active == true }
        guard active.count == 1 else {
            throw active.isEmpty
                ? AgtermError.noActiveSession
                : AgtermError.ambiguousActiveSession(sessions: active.map(\.id))
        }
        return active[0].id
    }

    /// Pure, so every shape of tree in `AgtermTests` is a value rather than a running terminal.
    /// The envelope, unwrapped and its refusal turned into an error. Shared by the two readers of
    /// the tree so that a change in how agterm reports a refusal cannot be fixed in one of them and
    /// forgotten in the other.
    private static func decodeTree(_ json: String) throws -> TreeEnvelope.Tree {
        guard let data = json.data(using: .utf8), !data.isEmpty else {
            throw AgtermError.malformedTree("agtermctl tree printed nothing")
        }
        let envelope: TreeEnvelope
        do {
            envelope = try JSONDecoder().decode(TreeEnvelope.self, from: data)
        } catch {
            throw AgtermError.malformedTree("the output is not the JSON tree this build expects")
        }
        if envelope.ok == false {
            throw AgtermError.commandFailed(verb: "tree", status: 0,
                                            message: envelope.error ?? "agterm refused to answer")
        }
        guard let result = envelope.result else {
            throw AgtermError.malformedTree("the answer carries no tree")
        }
        return result.tree
    }

    static func surfaces(inTree json: String, session: String) throws -> [TreeSurface] {
        let tree = try decodeTree(json)
        let sessions = tree.workspaces.flatMap { $0.sessions ?? [] }
        guard let found = sessions.first(where: { $0.id == session }) else {
            throw AgtermError.sessionNotFound(session)
        }
        return (found.surfaces ?? []).map {
            TreeSurface(kind: $0.kind, active: $0.active ?? false)
        }
    }
}

// MARK: - the real runner

/// One pipe's bytes, handed between the draining thread and the thread that waits for it. A class
/// with a lock rather than a captured `var`, because the closure crosses a thread boundary.
private final class DrainedPipe: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ value: Data) { lock.withLock { data = value } }
    func get() -> Data { lock.withLock { data } }
}

/// A one-way flag set on the deadline thread and read on the thread that waited for the child.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func raise() { lock.withLock { value = true } }
    var isRaised: Bool { lock.withLock { value } }
}

/// `Process`, with the two failure modes that matter kept apart: a tool that is not installed, and
/// one that ran and disagreed.
public struct ProcessRunner: CommandRunner {
    /// The ceiling on one `agtermctl` invocation, and the reason the daemon cannot be wedged by a
    /// beachballed agterm.
    ///
    /// `agtermctl` has no client-side timeout of its own: pointed at a control socket that accepts
    /// and never answers, it blocks for ever. Every invocation here runs inside `ControlServer`'s
    /// handler lock, which serialises EVERY command -- so one hung `tree --json` on the keypress
    /// path took the whole daemon down with it: later chords blocked on the lock and reported
    /// "dicta did not answer", `status`/`abort`/`last` died too, and `KeepAlive` could not help
    /// because the process was alive. It never recovered without a manual `launchctl kickstart`.
    ///
    /// Five seconds is about 125x the measured cost of the slowest verb (`tree --json`, 38 ms, F4),
    /// so it is a wedge detector rather than a budget anything real has to fit inside.
    public static let defaultDeadline: TimeInterval = 5.0

    /// How many of these calls ONE `stop` can make before the daemon answers, worst case.
    ///
    /// Enumerated rather than estimated, because `daemonCeilingsFitTheClientTimeout` multiplies it
    /// by `defaultDeadline` to assert that the daemon is never willing to spend longer than
    /// `ControlTimeouts.pipelineRead`. It read `3` -- "validate, session type, announce" -- which
    /// left fifteen seconds standing in for what can be sixty, and the assertion passed while the
    /// property it names did not hold. Every notification is TWO calls, not one: `Agterm.notify`
    /// falls back to `osascript` when agtermctl will not answer, which is exactly the case where
    /// both spend their whole deadline.
    ///
    ///  1. `.announce(.working)`
    ///  2. the dictionary's degradation notice, and 3. its `osascript` fallback
    ///  4. the filter's fallback notice, and 5. its `osascript` fallback (step 4's `Filter`; the
    ///     seam is `NoFilter` today, and the budget must already fit when it is not)
    ///  6. `validate` -- `agtermctl tree --json` on the frontmost window, and 7. `window list`
    ///     plus 8-10. a tree per window the sweep is willing to open
    ///     (`Agterm.maxWindowsSearched`, less the frontmost one already counted)
    /// 11. `session type`
    /// 12. the terminal `.announce(.done)` or `.announce(.blocked)`
    /// 13. the delivery failure's `.notify`, and 14. its `osascript` fallback
    /// 15. the record's "recovery is unavailable" notice, and 16. its `osascript` fallback
    public static let worstCaseCallsPerStop = 16

    /// The longest ONE of those calls can take, which is not `defaultDeadline`.
    ///
    /// A child that ignores SIGTERM spends `graceAfterTerminate` more, and descendants holding the
    /// pipes open spend `graceAfterKill` after that. `daemonCeilingsFitTheClientTimeout` multiplies
    /// this rather than the deadline, because a budget built out of the number the deadline is
    /// named after is a budget that undercounts by 60% exactly when it matters.
    public static var worstCaseCallSeconds: TimeInterval {
        defaultDeadline + graceAfterTerminate + graceAfterKill
    }

    /// How long a child gets to honour SIGTERM before SIGKILL. A child that ignores the polite
    /// signal would otherwise hold this thread's pipes open, and the wedge would simply move here.
    public static let graceAfterTerminate: TimeInterval = 2.0

    /// How long the reads get AFTER the child has been killed, before this call gives up on them.
    ///
    /// Killing the child is not enough to end a read. Foundation dups the pipe's write end into the
    /// child, and **every process the child spawns inherits it** -- so `readDataToEndOfFile`
    /// returns at EOF, which needs the last holder to close, not the direct child to die.
    /// Measured: a child
    /// that leaves a background descendant and is SIGKILLed at 2 s left the read blocked until the
    /// grandchild exited at 8 s, and `expired.isRaised` is only consulted once the read returns.
    /// The deadline above therefore bounded the child and not this call, which is precisely the
    /// wedge it is documented to prevent.
    ///
    /// So the reads are bounded too, and on expiry this call unwinds with whatever it has. The
    /// draining threads are left behind rather than interrupted: closing a descriptor another
    /// thread is blocked reading is how a file descriptor gets reused underneath it. They are one
    /// stack each, they end when the descendant does, and `AgtermError.timedOut` has already gone
    /// back to the caller by then.
    public static let graceAfterKill: TimeInterval = 1.0

    private let deadline: TimeInterval
    private let graceAfterTerminate: TimeInterval
    private let graceAfterKill: TimeInterval

    /// The graces are parameters for one reason: the test that proves the reads are bounded has to
    /// wait out both of them, and a suite that runs in half a second should not spend three of
    /// them holding a stopwatch. Nothing in the daemon passes anything but the defaults.
    public init(deadline: TimeInterval = ProcessRunner.defaultDeadline,
                graceAfterTerminate: TimeInterval = ProcessRunner.graceAfterTerminate,
                graceAfterKill: TimeInterval = ProcessRunner.graceAfterKill) {
        self.deadline = deadline
        self.graceAfterTerminate = graceAfterTerminate
        self.graceAfterKill = graceAfterKill
    }

    public func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw AgtermError.executableMissing(executable)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw AgtermError.launchFailed(verb: executable, reason: "\(error)")
        }
        // Read before waiting: a pipe that fills while nobody drains it wedges the child, and
        // `tree --json` on a busy machine is comfortably larger than a pipe buffer.
        //
        // BOTH pipes, concurrently, and that is the half that was missing. Draining stdout to EOF
        // and only then reading stderr deadlocks whenever the child fills stderr's buffer before
        // closing stdout: the child blocks writing, this thread blocks reading, and neither
        // `ProcessRunner` nor `Agterm` has a timeout to break it. Since this runs inside the
        // control socket's handler lock, one wedged `agtermctl` would wedge every chord.
        // NEITHER read happens on this thread, for the reason spelled out on `graceAfterKill`: a
        // read to EOF cannot be bounded from the outside, so the only way to put a ceiling on it is
        // to wait on a semaphore instead of on the descriptor. The FileHandles are captured by the
        // closures so the `Pipe` cannot take their descriptors out from under a blocked read.
        let outRead = out.fileHandleForReading
        let errRead = err.fileHandleForReading
        let stdoutCollected = DrainedPipe()
        let stderrCollected = DrainedPipe()
        let stdoutDrained = DispatchSemaphore(value: 0)
        let stderrDrained = DispatchSemaphore(value: 0)
        let stdoutThread = Thread {
            stdoutCollected.set(outRead.readDataToEndOfFile())
            stdoutDrained.signal()
        }
        stdoutThread.name = "dev.personal.dicta.process.stdout"
        stdoutThread.start()
        let stderrThread = Thread {
            stderrCollected.set(errRead.readDataToEndOfFile())
            stderrDrained.signal()
        }
        stderrThread.name = "dev.personal.dicta.process.stderr"
        stderrThread.start()

        // The deadline, on a thread of its own because the reads above are what it exists to
        // unblock. Killing the child closes ITS ends of both pipes, which is enough whenever the
        // child is the only holder -- and the ceiling below covers the case where it is not.
        let finished = DispatchSemaphore(value: 0)
        let expired = Flag()
        let deadline = self.deadline
        let watchdog = Thread {
            guard finished.wait(timeout: .now() + deadline) == .timedOut else { return }
            expired.raise()
            process.terminate()
            guard finished.wait(timeout: .now() + graceAfterTerminate) == .timedOut else {
                return
            }
            // `isRunning` is false only once Foundation has reaped the child, so the pid it hands
            // back here is still this child's and not a recycled one.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        watchdog.name = "dev.personal.dicta.process.deadline"
        watchdog.start()

        // One absolute instant for both waits, so two sequential waits cannot spend two budgets.
        let ceiling = DispatchTime.now() + deadline + graceAfterTerminate + graceAfterKill
        let drained = stdoutDrained.wait(timeout: ceiling) == .success
            && stderrDrained.wait(timeout: ceiling) == .success
        guard drained else {
            // The pipes outlived the child. Nothing here waits for the process: `waitUntilExit`
            // polls a child that has already been SIGKILLed, and the answer would change nothing.
            // One signal releases the watchdog whichever of its two waits it is sitting in.
            finished.signal()
            throw AgtermError.timedOut(verb: executable, seconds: deadline)
        }
        // The watchdog stays ARMED across this wait, and that is the whole reason the signal moved
        // below it. Draining is not exiting: a child that closes both pipe ends and then hangs --
        // `sh -c 'exec 1>&- 2>&-; sleep 20'` reproduces it exactly -- satisfies both reads at once,
        // so a signal here disarmed the deadline and left `waitUntilExit` unbounded. Measured at
        // 20 s against a 1 s deadline. Every `agtermctl` call runs inside `ControlServer`'s handler
        // lock, so that is the permanent wedge `defaultDeadline` exists to prevent, and it also
        // breaks the premise of `daemonCeilingsFitTheClientTimeout`: the call must be bounded by
        // `worstCaseCallSeconds`, not merely the reads.
        process.waitUntilExit()
        finished.signal()
        if expired.isRaised {
            // The verb is filled in by `Agterm.invoke`, which is the only caller that knows it.
            throw AgtermError.timedOut(verb: executable, seconds: deadline)
        }
        return CommandOutput(
            status: process.terminationStatus,
            standardOutput: String(decoding: stdoutCollected.get(), as: UTF8.self),
            standardError: String(decoding: stderrCollected.get(), as: UTF8.self)
        )
    }
}
