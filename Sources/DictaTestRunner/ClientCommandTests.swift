import DictaCore
import Foundation
import Testing

/// What a `dictactl` argument vector means — and, at the end, whether the keymap snippet still
/// means what it says it means.
///
/// The keymap is the only caller that matters, it is edited by hand months apart, and a line that
/// has drifted announces itself by a chord doing nothing. So the snippet is parsed here by the very
/// parser the binary uses, rather than by a human reading it.
@Suite("dictactl arguments")
struct ClientCommandTests {
    static func parsed(_ arguments: String...) throws -> ClientCommand.Invocation {
        switch ClientCommand.parse(arguments) {
        case let .success(invocation): invocation
        case let .failure(error): throw error
        }
    }

    static func usageError(_ arguments: [String]) throws -> ClientCommand.UsageError {
        switch ClientCommand.parse(arguments) {
        case let .success(invocation):
            Issue.record("expected a usage error, parsed \(invocation.request)")
            throw ClientCommand.UsageError.noCommand
        case let .failure(error):
            return error
        }
    }

    // MARK: - the verbs

    @Test("every verb on the wire has a verb on the command line", arguments: Command.allCases)
    func everyCommandIsReachable(command: Command) throws {
        // A command the daemon understands and the client cannot spell is a dead branch that will
        // be discovered by someone trying to use it.
        let arguments = switch command {
        case .toggle, .start: [command.rawValue, "--session", "session:1"]
        case .configure: [command.rawValue, "--offer-seen"]
        default: [command.rawValue]
        }
        switch ClientCommand.parse(arguments) {
        case let .success(invocation): #expect(invocation.request.cmd == command)
        case let .failure(error): Issue.record("\(command.rawValue): \(error)")
        }
    }

    @Test("toggle carries the session, agterm's socket and the mode")
    func togglePassesEverything() throws {
        let invocation = try Self.parsed(
            "toggle", "--mode", "raw", "--session", "session:9", "--socket", "/tmp/agterm.sock"
        )
        #expect(invocation.request == Request(cmd: .toggle, sessionID: "session:9",
                                              agtermSocket: "/tmp/agterm.sock", mode: .raw))
    }

    @Test("the mode defaults to clean on the verbs that deliver text")
    func modeDefaults() throws {
        #expect(try Self.parsed("toggle", "--session", "s").request.mode == .clean)
        #expect(try Self.parsed("stop").request.mode == .clean)
    }

    @Test("the mode is absent on the verbs that deliver nothing")
    func modeIsAbsentWhereItWouldBeMeaningless() throws {
        // raw and clean select whether the filter runs (§2). A verb that injects nothing has no
        // filter stage to select, and carrying a mode there would invite the daemon to read one.
        for verb in ["abort", "status", "last"] {
            #expect(try Self.parsed(verb).request.mode == nil, "\(verb) carried a mode")
        }
        #expect(try Self.parsed("start", "--session", "s").request.mode == nil)
    }

    @Test("dicta's own socket is addressed separately from agterm's")
    func controlSocketIsNotTheAgtermSocket() throws {
        // Conflating the two would send dictations to whichever agterm answered first.
        let invocation = try Self.parsed(
            "status", "--control", "/tmp/dicta.sock", "--socket", "/tmp/agterm.sock"
        )
        #expect(invocation.controlSocket == "/tmp/dicta.sock")
        #expect(invocation.request.agtermSocket == "/tmp/agterm.sock")
    }

    @Test("the control socket never travels on the wire")
    func controlSocketIsNotAWireField() throws {
        let invocation = try Self.parsed("status", "--control", "/tmp/dicta.sock")
        let json = try #require(String(data: Wire.encode(invocation.request), encoding: .utf8))
        #expect(!json.contains("/tmp/dicta.sock"))
    }

    // MARK: - what the environment actually hands us

    @Test("an unset environment variable expands to an empty string, not to an absent flag")
    func emptyFlagValuesAreTreatedAsAbsent() throws {
        // `--socket "$AGT_SOCKET"` with AGT_SOCKET unset arrives as `--socket ""`. Carrying that
        // through would have the daemon address the empty path.
        let invocation = try Self.parsed("status", "--socket", "", "--control", "")
        #expect(invocation.request.agtermSocket == nil)
        #expect(invocation.controlSocket == nil)
    }

    @Test("an empty session is a usage error rather than an attempt with no target")
    func emptySessionIsRefused() throws {
        #expect(try Self.usageError(["toggle", "--session", ""]) == .missingSession(.toggle))
        #expect(try Self.usageError(["start", "--session", ""]) == .missingSession(.start))
    }

    @Test("the verbs that begin an attempt require the session the chord fired in")
    func startingVerbsRequireASession() throws {
        // The session id is the keypress-accurate half of the target (§5). Without it there is
        // nothing to pin the attempt to, and guessing from focus is D4's forbidden substitution.
        #expect(try Self.usageError(["toggle"]) == .missingSession(.toggle))
        #expect(try Self.usageError(["start"]) == .missingSession(.start))
    }

    // MARK: - refusing what it does not understand

    @Test("no arguments at all is a usage error")
    func noVerb() throws {
        #expect(try Self.usageError([]) == .noCommand)
    }

    @Test("an unknown verb is named in the error")
    func unknownVerb() throws {
        // Deliberately a verb this build does not have and is unlikely to grow. "dictate" used to
        // stand here and then became real (D29), which is exactly how a test like this rots.
        #expect(try Self.usageError(["transcribe"]) == .unknownCommand("transcribe"))
    }

    @Test("an unknown option is refused rather than ignored")
    func unknownFlag() throws {
        // Silently dropping it is how a chord starts a dictation that ignores the mode asked for.
        #expect(try Self.usageError(["status", "--verbose"]) == .unknownFlag("--verbose"))
    }

    @Test("an option the verb does not take is refused, and the error says which verb")
    func flagNotAcceptedByVerb() throws {
        #expect(try Self.usageError(["stop", "--session", "s"])
            == .flagNotAccepted(flag: "--session", by: .stop))
        #expect(try Self.usageError(["abort", "--mode", "raw"])
            == .flagNotAccepted(flag: "--mode", by: .abort))
    }

    @Test("an option with no value is refused rather than swallowing the next verb")
    func missingValue() throws {
        #expect(try Self.usageError(["toggle", "--session"]) == .missingValue(flag: "--session"))
    }

    @Test("an unknown mode is refused rather than falling back to clean")
    func unknownMode() throws {
        // Falling back would deliver filtered text to someone who asked for verbatim.
        #expect(try Self.usageError(["stop", "--mode", "verbatim"]) == .unknownMode("verbatim"))
    }

    @Test("a stray positional argument is refused")
    func unexpectedArgument() throws {
        #expect(try Self.usageError(["status", "please"]) == .unexpectedArgument("please"))
    }

    // MARK: - the setup verbs (D31)

    @Test("configure carries the scope, the answered offer, or both",
          arguments: [(["configure", "--scope", "other-apps"],
                       Request(cmd: .configure, scope: .otherApps)),
                      (["configure", "--scope", "agterm-only"],
                       Request(cmd: .configure, scope: .agtermOnly)),
                      (["configure", "--offer-seen"],
                       Request(cmd: .configure, offerSeen: true)),
                      (["configure", "--offer-seen", "--scope", "other-apps"],
                       Request(cmd: .configure, scope: .otherApps, offerSeen: true))])
    func configureParses(arguments: [String], request: Request) {
        #expect(ClientCommand.parse(arguments)
            == .success(ClientCommand.Invocation(request: request)))
    }

    @Test("configure with nothing to record is refused")
    func configureNeedsAnOption() throws {
        #expect(try Self.usageError(["configure"]) == .nothingToConfigure)
        #expect(try Self.usageError(["configure", "--control", "/tmp/dicta.sock"])
            == .nothingToConfigure)
    }

    @Test("a scope nobody can choose is refused: undecided, unknown or empty",
          arguments: ["undecided", "everywhere", "other_apps", ""])
    func unchoosableScopeIsRefused(scope: String) throws {
        #expect(try Self.usageError(["configure", "--scope", scope]) == .unchoosableScope(scope))
        // Not rescued by another option: a choice that was typed and cannot be made is refused
        // whole, never recorded as the half that could.
        #expect(try Self.usageError(["configure", "--offer-seen", "--scope", scope])
            == .unchoosableScope(scope))
    }

    @Test("configure takes no attempt, mode, session or prompt")
    func configureRefusesOtherOptions() throws {
        for flag in ["--mode", "--session", "--socket", "--prompt", "--recognised", "--timeout"] {
            #expect(try Self.usageError(["configure", flag, "x"])
                == .flagNotAccepted(flag: flag, by: .configure))
        }
        #expect(try Self.usageError(["configure", "--scope"]) == .missingValue(flag: "--scope"))
    }

    @Test("accessibility reads the grant, and asks for it only with --prompt")
    func accessibilityParses() throws {
        #expect(try Self.parsed("accessibility").request == Request(cmd: .accessibility))
        #expect(try Self.parsed("accessibility", "--prompt").request
            == Request(cmd: .accessibility, prompt: true))
        #expect(try Self.parsed("accessibility", "--control", "/tmp/d.sock").controlSocket
            == "/tmp/d.sock")
    }

    @Test("accessibility refuses every other option")
    func accessibilityRefusesOtherOptions() throws {
        for flag in ["--scope", "--offer-seen", "--mode", "--session", "--socket", "--recognised",
                     "--timeout"] {
            #expect(try Self.usageError(["accessibility", flag, "x"])
                == .flagNotAccepted(flag: flag, by: .accessibility))
        }
        #expect(try Self.usageError(["accessibility", "--prompt", "yes"])
            == .unexpectedArgument("yes"))
    }

    @Test("no other verb takes the setup options")
    func setupOptionsBelongToTheSetupVerbs() throws {
        for command in Command.allCases where command != .configure && command != .accessibility {
            for flag in ["--scope", "--offer-seen", "--prompt"] {
                #expect(try Self.usageError([command.rawValue, flag, "x"])
                    == .flagNotAccepted(flag: flag, by: command))
            }
        }
    }

    @Test("the exit codes are four distinct values")
    func exitCodes() {
        let codes = [ClientCommand.ExitCode.ok, ClientCommand.ExitCode.rejected,
                     ClientCommand.ExitCode.usage, ClientCommand.ExitCode.unreachable]
        #expect(Set(codes).count == 4)
        #expect(ClientCommand.ExitCode.ok == 0)
    }

    // MARK: - the keymap snippet

    static var keymapSnippet: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Sources/DictaTestRunner
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // the repository root
            .appendingPathComponent("docs/keymap.snippet.conf")
    }

    /// agterm's keymap is `command "<name>" <chord> <shell...>`, quoted names included.
    static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var started = false
        for character in line {
            if character == "\"" {
                inQuotes.toggle()
                started = true
            } else if character == " ", !inQuotes {
                if started { tokens.append(current) }
                current = ""
                started = false
            } else {
                current.append(character)
                started = true
            }
        }
        if started { tokens.append(current) }
        return tokens
    }

    struct Binding {
        let chord: String
        let program: String
        let arguments: [String]
    }

    static func bindings() throws -> [Binding] {
        let text = try String(contentsOf: keymapSnippet, encoding: .utf8)
        return text.split(separator: "\n").filter { $0.hasPrefix("command ") }.map { line in
            let tokens = tokenize(String(line))
            return Binding(chord: tokens[2], program: tokens[3],
                           arguments: Array(tokens.dropFirst(4)))
        }
    }

    @Test("the snippet binds exactly the three chords §6 defines")
    func snippetChords() throws {
        let bindings = try Self.bindings()
        #expect(bindings.map(\.chord) == ["ctrl+opt+d", "ctrl+opt+shift+d", "ctrl+opt+x"])
    }

    @Test("every line in the snippet parses with the parser the binary uses")
    func snippetParses() throws {
        // This is the whole point of the file: a snippet that no longer matches the build fails
        // here, not by a chord doing nothing three months from now.
        for binding in try Self.bindings() {
            switch ClientCommand.parse(binding.arguments) {
            case .success: break
            case let .failure(error):
                Issue.record("\(binding.chord): \(error)")
            }
        }
    }

    @Test("the snippet invokes dictactl by absolute path and not through a login shell")
    func snippetInvokesTheBinaryDirectly() throws {
        // §12: agterm runs the line through `/bin/sh -c`, so a bare name costs a PATH search on
        // every keypress and a login shell would add tens of milliseconds of profile loading.
        for binding in try Self.bindings() {
            #expect(binding.program.hasSuffix("/dictactl"), "\(binding.chord): \(binding.program)")
            #expect(binding.program.hasPrefix("/") || binding.program.hasPrefix("$HOME/"),
                    "\(binding.chord) does not name dictactl by absolute path")
            for shell in ["sh", "bash", "zsh", "fish", "env"] {
                #expect(!binding.program.hasSuffix("/\(shell)"),
                        "\(binding.chord) goes through \(shell)")
            }
        }
    }

    @Test("both start chords call the same verb and differ in exactly one thing")
    func bothStartChordsAreTheSameCommand() throws {
        // D3, D5, D7: the mode is chosen by the chord that STOPS the recording, so nothing has to
        // be decided before speaking, and start-or-stop resolves inside the daemon.
        let bindings = try Self.bindings()
        let clean = try #require(try? Self.invocation(bindings[0]))
        let raw = try #require(try? Self.invocation(bindings[1]))

        #expect(clean.request.cmd == .toggle)
        #expect(raw.request.cmd == .toggle)
        #expect(clean.request.mode == .clean)
        #expect(raw.request.mode == .raw)

        var normalised = raw.request
        normalised.mode = .clean
        #expect(normalised == clean.request, "the two start chords differ in more than the mode")
    }

    @Test("the start chords pass the session and agterm's socket, and never a pane")
    func startChordsPassTheTarget() throws {
        // F3: the installed agterm does not export $AGT_PANE, so the daemon resolves the pane from
        // the live tree. A pane on the keypress would only invite a guess (D6, §5).
        for binding in try Self.bindings().prefix(2) {
            #expect(binding.arguments.contains("$AGT_SESSION_ID"))
            #expect(binding.arguments.contains("$AGT_SOCKET"))
            #expect(!binding.arguments.contains { $0.contains("PANE") })
        }
    }

    @Test("the abort chord names no session, because abandoning needs no target")
    func abortChordNeedsNoSession() throws {
        let abort = try #require(try? Self.invocation(try Self.bindings()[2]))
        #expect(abort.request.cmd == .abort)
        #expect(abort.request.sessionID == nil)
    }

    @Test("a flag where a value belongs is a missing value, not a value spelled like a flag")
    func aFlagIsNeverSwallowedAsAValue() {
        // `--session` used to take "--mode" as its value and address a pane called that. Silent
        // nonsense from the one component whose whole purpose is catching a keymap line that has
        // drifted away from this build.
        #expect(ClientCommand.parse(["toggle", "--session", "--mode", "clean"])
            == .failure(.missingValue(flag: "--session")))
        #expect(ClientCommand.parse(["stop", "--mode", "--control"])
            == .failure(.missingValue(flag: "--mode")))
        // The boolean flag is unaffected: it consumes nothing, so what follows still parses.
        #expect(ClientCommand.parse(["last", "--recognised"])
            == .success(ClientCommand.Invocation(request: Request(cmd: .last, verbatim: true))))
    }

    @Test("every usage error says which flag, verb or mode it is about")
    func everyUsageErrorNamesItsSubject() {
        // These sentences are not decoration: `dictactl` writes each one to stderr AND pushes it as
        // a desktop notification, and they are all the user gets when a chord silently stops
        // working. A message that named no subject would leave them nothing to edit.
        let cases: [(ClientCommand.UsageError, String)] = [
            (.noCommand, "verb"),
            (.unknownCommand("wobble"), "wobble"),
            (.unknownFlag("--wobble"), "--wobble"),
            (.flagNotAccepted(flag: "--session", by: .abort), "--session"),
            (.missingValue(flag: "--mode"), "--mode"),
            (.missingSession(.toggle), "--session"),
            (.unknownMode("shouty"), "shouty"),
            (.unexpectedArgument("stray"), "stray"),
            (.unknownTimeout("3O"), "3O"),
            (.nothingToConfigure, "--scope"),
            (.unchoosableScope("undecided"), "undecided"),
        ]
        for (error, subject) in cases {
            #expect(error.description.contains(subject),
                    "\(error) must name \(subject): \(error.description)")
        }
        // The one that has to name an environment variable rather than a flag, because that is what
        // the user has to put in the keymap.
        #expect(ClientCommand.UsageError.missingSession(.start).description
            .contains("$AGT_SESSION_ID"))
        #expect(ClientCommand.UsageError.flagNotAccepted(flag: "--session", by: .abort).description
            .contains("abort"))
    }

    static func invocation(_ binding: Binding) throws -> ClientCommand.Invocation {
        switch ClientCommand.parse(binding.arguments) {
        case let .success(invocation): invocation
        case let .failure(error): throw error
        }
    }
}
