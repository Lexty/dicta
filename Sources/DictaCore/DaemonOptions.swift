import Foundation

// The daemon's command line, as a value (D19).
//
// It used to be a `while` loop at the top of `Sources/Dicta/main.swift`, calling `exit(2)` from the
// middle of a nested function -- correct, and unreachable from any test, because an executable
// target cannot be imported. `--focused-fields` is the flag that decides whether the daemon may
// touch accessibility at all (D5, D31, invariant 14), which is too much weight for a switch
// statement nobody can assert on. So the parse lives here and `main.swift` only acts on its answer.

/// What `Dicta` was asked to do.
public struct DaemonOptions: Sendable, Equatable {
    /// dicta's own control socket.
    public var controlSocket: String
    /// agterm's control socket, when it is not the default one.
    public var agtermSocket: String?
    /// Download the recognition models, then exit.
    public var fetchModels: Bool
    /// `--no-hold` clears it.
    public var armHoldTrigger: Bool
    /// Empty means "whatever `HoldTrigger.Configuration` defaults to". Not seeded with that
    /// default: the first `--hold-key` has to REPLACE the pair rather than join it, and a list that
    /// starts out full cannot tell the two apart.
    public var holdKeys: [HoldKey]
    /// `--focused-fields` (D31). Off by default, and off means no accessibility call and no posted
    /// event anywhere in the process -- which is how D5 still promises no permission prompt to
    /// anybody who did not ask for this.
    public var focusedFields: Bool

    public init(controlSocket: String = Paths.current.socket.path,
                agtermSocket: String? = nil,
                fetchModels: Bool = false,
                armHoldTrigger: Bool = true,
                holdKeys: [HoldKey] = [],
                focusedFields: Bool = false) {
        self.controlSocket = controlSocket
        self.agtermSocket = agtermSocket
        self.fetchModels = fetchModels
        self.armHoldTrigger = armHoldTrigger
        self.holdKeys = holdKeys
        self.focusedFields = focusedFields
    }

    /// The three things a command line can come to.
    public enum Parsed: Sendable, Equatable {
        case run(DaemonOptions)
        /// `--help`: print `usage` and exit 0.
        case help
        /// Print the line to stderr and exit 2. The line carries its `dicta: ` prefix already.
        case refused(String)
    }

    public static let usage = """
    usage: Dicta [options]

    options:
      --control <path>         dicta's own control socket (defaults to the one under
                               ~/Library/Application Support/dev.personal.dicta)
      --agterm-socket <path>   agterm's control socket, when it is not the default one
      --fetch-models           download the recognition models, then exit
      --no-hold                do not arm push-to-talk; the keymap chords still work
      --hold-key <name>        arm push-to-talk on this key instead of the default pair
                               (\(HoldKey.everyName)); repeat the flag to arm several
      --focused-fields         also dictate into the focused text field of any other application;
                               needs the Accessibility grant, and makes agterm optional
      --help                   print this
    """

    /// `arguments` without the executable's own name. The first refusal wins, as it did when each
    /// one was an `exit(2)`.
    public static func parse(_ arguments: [String],
                             defaultControlSocket: String = Paths.current.socket.path) -> Parsed {
        var options = DaemonOptions(controlSocket: defaultControlSocket)
        var remaining = arguments[...]
        /// An empty value is refused rather than taken, and that is the client's rule arriving
        /// through the other door (`ClientCommand.parse`): an unset environment variable expands to
        /// an empty string, not to an absent argument, so a wrapper passing
        /// `--agterm-socket "$AGT_SOCKET"` with nothing in it would otherwise splice `--socket ""`
        /// into every `agtermctl` call the daemon makes -- every chord refused, for a reason no
        /// message names.
        func value(_ flag: String) throws(Refusal) -> String {
            guard let next = remaining.popFirst() else {
                throw Refusal(line: "dicta: \(flag) needs a value")
            }
            guard !next.isEmpty else {
                throw Refusal(line: "dicta: \(flag) was given an empty value")
            }
            return next
        }
        do throws(Refusal) {
            while let argument = remaining.popFirst() {
                switch argument {
                case "--help", "-h":
                    return .help
                case "--control":
                    options.controlSocket = try value(argument)
                case "--agterm-socket":
                    options.agtermSocket = try value(argument)
                case "--no-hold":
                    options.armHoldTrigger = false
                case "--hold-key":
                    let name = try value(argument)
                    guard let key = HoldKey.named(name) else {
                        throw Refusal(line: "dicta: --hold-key does not know \"\(name)\"; it "
                                      + "accepts \(HoldKey.everyName)")
                    }
                    // A repeat is refused rather than deduplicated. Two watches on one key would
                    // each report its edges and `HoldWatch` would swallow the second -- correct,
                    // and silently different from what the user wrote.
                    guard !options.holdKeys.contains(key) else {
                        throw Refusal(line: "dicta: --hold-key \(name) was given twice")
                    }
                    options.holdKeys.append(key)
                case "--fetch-models":
                    options.fetchModels = true
                case "--focused-fields":
                    options.focusedFields = true
                default:
                    throw Refusal(line: "dicta: unknown option \(argument)")
                }
            }
        } catch {
            return .refused(error.line)
        }
        return .run(options)
    }

    private struct Refusal: Error {
        var line: String
    }

    /// What start-up does when `agtermctl` is, or is not, found.
    public enum AgtermAtStartup: Sendable, Equatable {
        /// Found: the agterm path works as it always has.
        case present
        /// Not found, and nothing else could deliver a word: log the line and exit non-zero.
        case fatal(String)
        /// Not found, and focused fields still can: log the line and carry on (D31).
        case optional(String)
    }

    /// Diagnosed at start-up rather than on the first chord (§7). With `--focused-fields` off a
    /// daemon without agterm has nowhere to put text, so starting it would only move the discovery
    /// to a chord that loses an utterance; with the option on, every other application's field is
    /// still a target.
    public func agtermAtStartup(found: Bool) -> AgtermAtStartup {
        if found { return .present }
        guard focusedFields else {
            return .fatal("agtermctl is not installed -- dicta cannot reach agterm, so nothing "
                          + "would be delivered")
        }
        return .optional("agtermctl is not installed -- agterm chords and a hold in front of "
                         + "agterm will be refused; focused fields still work")
    }
}
