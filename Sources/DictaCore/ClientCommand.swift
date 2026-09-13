// What `dictactl`'s argument vector means, as a pure function (D19).
//
// This lives in DictaCore rather than in the executable for one reason: an executable target cannot
// be imported, so anything decided inside `Sources/dictactl/main.swift` is unreachable from the
// test runner. The keymap is the only caller that matters and it is edited by hand, months apart,
// so "does this line still mean what it meant" is exactly the question a test should answer -- and
// `docs/keymap.snippet.conf` is checked against this parser rather than against a human's reading
// of it.
//
// The parser is strict on purpose. An unknown flag is a usage error rather than something silently
// dropped: a keymap line invoking a flag this build does not have would otherwise start a dictation
// that quietly ignores the mode the user asked for.

/// The socket the daemon listens on is addressed by `--control`; `--socket` is **agterm's** socket
/// (`$AGT_SOCKET`), which is a different thing entirely and travels on the wire. Conflating the two
/// would send dictations to whichever agterm answered first.
public enum ClientCommand {
    /// One parsed invocation: the frame to send, and where to send it.
    public struct Invocation: Equatable, Sendable {
        /// What goes on the wire.
        public var request: Request
        /// `--control`: dicta's own control socket, when overridden. `nil` means `Paths.current`.
        public var controlSocket: String?

        public init(request: Request, controlSocket: String? = nil) {
            self.request = request
            self.controlSocket = controlSocket
        }
    }

    /// Everything that makes an argument vector unusable. Each is a distinct value because each
    /// deserves a distinct sentence on the user's desktop -- the keymap is edited blind, and
    /// "dictactl: bad arguments" would send the user to read source code.
    public enum UsageError: Error, Equatable, CustomStringConvertible {
        case noCommand
        case unknownCommand(String)
        case unknownFlag(String)
        case flagNotAccepted(flag: String, by: Command)
        case missingValue(flag: String)
        case missingSession(Command)
        case unknownMode(String)
        case unexpectedArgument(String)
        case unknownTimeout(String)
        /// `configure` with nothing to record.
        case nothingToConfigure
        /// A scope nobody can choose: unknown, empty, or `undecided`.
        case unchoosableScope(String)

        public var description: String {
            switch self {
            case .noCommand:
                "no verb given — expected one of \(ClientCommand.verbs.joined(separator: ", "))"
            case let .unknownCommand(verb):
                "unknown verb \"\(verb)\" — expected one of "
                    + ClientCommand.verbs.joined(separator: ", ")
            case let .unknownFlag(flag):
                "unknown option \(flag)"
            case let .flagNotAccepted(flag, command):
                "\(command.rawValue) does not take \(flag)"
            case let .missingValue(flag):
                "\(flag) needs a value"
            case let .missingSession(command):
                "\(command.rawValue) needs --session — pass \"$AGT_SESSION_ID\" from the keymap"
            case let .unknownMode(mode):
                "unknown mode \"\(mode)\" — expected clean or raw"
            case let .unknownTimeout(raw):
                "\"\(raw)\" is not a number of seconds"
            case let .unexpectedArgument(argument):
                "unexpected argument \"\(argument)\""
            case .nothingToConfigure:
                "configure needs --scope, --offer-seen or both"
            case let .unchoosableScope(scope):
                "scope \"\(scope)\" cannot be chosen — expected "
                    + ClientCommand.choosableScopes.map(\.rawValue).joined(separator: " or ")
            }
        }
    }

    /// Process exit codes, so the keymap, a shell and a test all read the same meanings.
    public enum ExitCode {
        /// The daemon accepted the command, or it was a legitimate no-op (§6).
        public static let ok: Int32 = 0
        /// The daemon refused it. The daemon owns the sound and the notification for this (§6), so
        /// the client only reports it.
        public static let rejected: Int32 = 1
        /// The argument vector is wrong — almost always a keymap edit.
        public static let usage: Int32 = 2
        /// The daemon could not be reached at all. §7 calls for a loud local failure here.
        public static let unreachable: Int32 = 3
        /// `dictate` came back with no text: nobody spoke in time, or another caller held the
        /// claim. Its own code because a script must be able to tell "no dictation" from "the
        /// daemon refused" and from "the daemon is not there" — `PROMPT=$(dictactl dictate) || …`
        /// is the whole point of the verb (D29).
        public static let nothingDictated: Int32 = 4
    }

    public static let verbs = Command.allCases.map(\.rawValue)

    public static let usage = """
    usage: dictactl <verb> [options]

    verbs:
      toggle         start if idle, otherwise stop and deliver — what every chord calls (D7)
      start          begin an attempt
      stop           end an attempt and deliver in the given mode
      abort          end an attempt and deliver nothing
      status         print the daemon's current state
      last           print the text of the most recent attempt
      watch          print the daemon's state as one JSON line per change, until it stops (D27)
      dictate        wait for the next dictation and print its text — nothing is typed (D29)
      configure      record where dictation goes, as the setup window does (D31)
      accessibility  read the Accessibility grant; with --prompt, ask the system for it first

    options:
      --mode <clean|raw>   clean runs the filter, raw skips it and nothing else (§2)
      --session <id>       the agterm session the chord fired in; pass "$AGT_SESSION_ID"
      --socket <path>      agterm's control socket; pass "$AGT_SOCKET"
      --control <path>     dicta's own control socket (defaults to the one under
                           ~/Library/Application Support/dev.personal.dicta)
      --recognised         on last: print the recogniser's verbatim output instead of what was
                           injected — the two together are how a replacement misfire is diagnosed
      --timeout <seconds>  on dictate: how long to wait for the user to speak before giving up
      --scope <agterm-only|other-apps>
                           on configure: agterm's panes only, or the focused field of other apps too
      --offer-seen         on configure: the one-time offer to type into other apps was answered
      --prompt             on accessibility: show the system's permission dialog (other-apps only)

    examples:
      # dictate into a native dialog that dicta cannot type into: collect the text first,
      # then open the dialog already carrying it.
      PROMPT=$(dictactl dictate) && agtermctl pick --query "$PROMPT" --allow-custom
    """

    private static let modeFlag = "--mode"
    private static let sessionFlag = "--session"
    private static let agtermSocketFlag = "--socket"
    private static let controlFlag = "--control"
    private static let recognisedFlag = "--recognised"
    private static let timeoutFlag = "--timeout"
    private static let scopeFlag = "--scope"
    private static let offerSeenFlag = "--offer-seen"
    private static let promptFlag = "--prompt"

    private static let allFlags = [modeFlag, sessionFlag, agtermSocketFlag, controlFlag,
                                   recognisedFlag, timeoutFlag, scopeFlag, offerSeenFlag,
                                   promptFlag]

    /// Flags that are their own value. It was one flag once, and it stayed a list, which is why the
    /// next two cost one line each.
    private static let booleanFlags = [recognisedFlag, offerSeenFlag, promptFlag]

    /// The scopes a person can choose. `undecided` is where nobody has chosen yet, and the daemon
    /// refuses it too; spelling it here would only move the refusal one round trip later.
    public static let choosableScopes: [SetupScope] = [.agtermOnly, .otherApps]

    /// Which flags each verb accepts. `--socket` and `--control` are universal because both are
    /// about *reaching* something rather than about what to do; `--session` is not, because only
    /// the two verbs that can begin an attempt have a target to pin (§5).
    private static func acceptedFlags(for command: Command) -> [String] {
        switch command {
        case .toggle: [modeFlag, sessionFlag, agtermSocketFlag, controlFlag]
        case .start: [sessionFlag, agtermSocketFlag, controlFlag]
        case .stop: [modeFlag, agtermSocketFlag, controlFlag]
        case .last: [recognisedFlag, agtermSocketFlag, controlFlag]
        case .dictate: [timeoutFlag, modeFlag, agtermSocketFlag, controlFlag]
        // `watch` takes only the reaching flags, and that is the whole of its surface: it names no
        // attempt, chooses no mode and pins no session, because it changes nothing (D27). It is
        // exposed on the client at all so a person can see the stream without building the UI —
        // the same reason `last` is there.
        case .abort, .status, .watch: [agtermSocketFlag, controlFlag]
        // The setup verbs take no `--socket`: they reach dicta and nothing of agterm's, and are
        // typed by hand, so there is no agterm notification for that socket to carry either.
        case .configure: [scopeFlag, offerSeenFlag, controlFlag]
        case .accessibility: [promptFlag, controlFlag]
        }
    }

    /// Verbs that begin an attempt, and therefore need the session the chord fired in.
    private static func needsSession(_ command: Command) -> Bool {
        command == .toggle || command == .start
    }

    /// Verbs where the mode selects what gets delivered, and so defaults rather than staying unset.
    private static func carriesMode(_ command: Command) -> Bool {
        command == .toggle || command == .stop || command == .dictate
    }

    /// Verbs whose STDOUT is data rather than a report, so nothing else may be written to it.
    ///
    /// `dictate` is the only one, and it is the reason this exists: its output is spliced straight
    /// into a shell variable and from there into another program's argument. A friendly line like
    /// "nobody dictated anything" printed there does not read as an error — it reads as the thing
    /// the user said.
    public static func writesDataToStdout(_ command: Command) -> Bool {
        command == .dictate
    }

    public static func parse(_ arguments: [String]) -> Result<Invocation, UsageError> {
        guard let verb = arguments.first else { return .failure(.noCommand) }
        guard let command = Command(rawValue: verb) else { return .failure(.unknownCommand(verb)) }

        var values: [String: String] = [:]
        var switches: Set<String> = []
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else { return .failure(.unexpectedArgument(argument)) }
            guard allFlags.contains(argument) else { return .failure(.unknownFlag(argument)) }
            guard acceptedFlags(for: command).contains(argument) else {
                return .failure(.flagNotAccepted(flag: argument, by: command))
            }
            if booleanFlags.contains(argument) {
                switches.insert(argument)
                index += 1
                continue
            }
            // A flag where a value belongs is a missing value, not a value that happens to look
            // like a flag. `dictactl toggle --session --mode clean` used to set the session to
            // "--mode" and then address a pane called that -- silently, which is the one thing
            // this parser exists to prevent.
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                return .failure(.missingValue(flag: argument))
            }
            values[argument] = arguments[index + 1]
            index += 2
        }

        // An unset environment variable expands to an empty string, not to an absent argument, so
        // `--socket ""` reaches us whenever agterm is not exporting $AGT_SOCKET. Treating that as
        // "not given" is the difference between a working chord and one that addresses "".
        func given(_ flag: String) -> String? {
            guard let value = values[flag], !value.isEmpty else { return nil }
            return value
        }

        var mode: Mode?
        if let raw = given(modeFlag) {
            guard let parsed = Mode(rawValue: raw) else { return .failure(.unknownMode(raw)) }
            mode = parsed
        } else if carriesMode(command) {
            mode = .clean
        }

        var timeout: Double?
        if let raw = given(timeoutFlag) {
            // Refused rather than defaulted: a caller who wrote `--timeout 3O` (letter O) meant
            // three seconds and would otherwise wait the default minute with no sign of the typo.
            guard let parsed = Double(raw), parsed > 0, parsed.isFinite else {
                return .failure(.unknownTimeout(raw))
            }
            timeout = parsed
        }

        // Read from `values` rather than through `given`: an empty scope is not a keymap line's
        // unset variable, it is somebody who typed `--scope ""`, and a `configure` that quietly
        // recorded only the rest would claim a choice was saved that was never made.
        var scope: SetupScope?
        if let raw = values[scopeFlag] {
            guard let parsed = SetupScope(rawValue: raw), choosableScopes.contains(parsed) else {
                return .failure(.unchoosableScope(raw))
            }
            scope = parsed
        }
        let offerSeen = switches.contains(offerSeenFlag) ? true : nil
        if command == .configure, scope == nil, offerSeen == nil {
            return .failure(.nothingToConfigure)
        }

        var session: String?
        if needsSession(command) {
            guard let value = given(sessionFlag) else { return .failure(.missingSession(command)) }
            session = value
        }

        return .success(Invocation(
            request: Request(
                cmd: command,
                sessionID: session,
                agtermSocket: given(agtermSocketFlag),
                mode: mode,
                timeout: timeout,
                // `nil` rather than `false` when it was not asked for, so the frame a chord sends
                // carries only what the chord actually said.
                verbatim: switches.contains(recognisedFlag) ? true : nil,
                scope: scope,
                offerSeen: offerSeen,
                prompt: switches.contains(promptFlag) ? true : nil
            ),
            controlSocket: given(controlFlag)
        ))
    }
}
