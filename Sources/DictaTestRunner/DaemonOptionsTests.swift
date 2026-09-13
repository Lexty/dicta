import DictaCore
import DictaRuntime
import Foundation
import Testing

// The daemon's command line, which used to be top-level code in `Sources/Dicta/main.swift` that no
// test could reach. The focused-field path's composition is `FocusedFieldSwitchTests`.
//
// The parser is held to what `main.swift` did before it moved, refusal text included: a wrapper
// script or a LaunchAgent that worked yesterday must not start failing for a reason that reads
// differently today.

@Suite("daemon options")
struct DaemonOptionsTests {
    static let socket = "/tmp/dicta-default.sock"

    static func parse(_ arguments: [String]) -> DaemonOptions.Parsed {
        DaemonOptions.parse(arguments, defaultControlSocket: socket)
    }

    // MARK: - flags

    @Test("no arguments is the daemon as it has always started, with focused fields off")
    func defaults() {
        #expect(Self.parse([]) == .run(DaemonOptions(controlSocket: Self.socket)))
        guard case let .run(options) = Self.parse([]) else { return }
        #expect(options.agtermSocket == nil)
        #expect(!options.fetchModels)
        #expect(options.armHoldTrigger)
        #expect(options.holdKeys.isEmpty)
        #expect(!options.focusedFields)
    }

    @Test("every existing flag is parsed as main.swift parsed it")
    func everyFlag() {
        let parsed = Self.parse([
            "--control", "/tmp/c.sock", "--agterm-socket", "/tmp/a.sock", "--fetch-models",
            "--no-hold", "--hold-key", "rightOption", "--hold-key", "RIGHTCONTROL",
        ])
        #expect(parsed == .run(DaemonOptions(
            controlSocket: "/tmp/c.sock", agtermSocket: "/tmp/a.sock", fetchModels: true,
            armHoldTrigger: false, holdKeys: [.rightOption, .rightControl])))
    }

    @Test("--focused-fields turns the option on and changes nothing else")
    func focusedFields() {
        #expect(Self.parse(["--focused-fields"])
            == .run(DaemonOptions(controlSocket: Self.socket, focusedFields: true)))
        // Beside `--no-hold`, which is exactly the combination whose frontmost source must still
        // be built (`FocusedFieldSwitch`).
        #expect(Self.parse(["--no-hold", "--focused-fields"])
            == .run(DaemonOptions(controlSocket: Self.socket, armHoldTrigger: false,
                                  focusedFields: true)))
    }

    @Test("--help and -h ask for the usage, wherever they appear")
    func help() {
        #expect(Self.parse(["--help"]) == .help)
        #expect(Self.parse(["-h"]) == .help)
        #expect(Self.parse(["--no-hold", "--help", "--bogus"]) == .help)
    }

    @Test("the usage names every flag the parser takes, and every hold key")
    func usage() {
        for flag in ["--control", "--agterm-socket", "--fetch-models", "--no-hold", "--hold-key",
                     "--focused-fields", "--help"] {
            #expect(DaemonOptions.usage.contains(flag), "usage does not mention \(flag)")
        }
        #expect(DaemonOptions.usage.contains(HoldKey.everyName))
    }

    // MARK: - refusals, word for word

    @Test("a refusal carries the line main.swift printed", arguments: [
        (["--bogus"], "dicta: unknown option --bogus"),
        (["--control"], "dicta: --control needs a value"),
        (["--agterm-socket"], "dicta: --agterm-socket needs a value"),
        (["--hold-key"], "dicta: --hold-key needs a value"),
        (["--control", ""], "dicta: --control was given an empty value"),
        (["--agterm-socket", ""], "dicta: --agterm-socket was given an empty value"),
        (["--hold-key", ""], "dicta: --hold-key was given an empty value"),
        (["--hold-key", "leftShift"],
         "dicta: --hold-key does not know \"leftShift\"; it accepts \(HoldKey.everyName)"),
        (["--hold-key", "rightCommand", "--hold-key", "rightcommand"],
         "dicta: --hold-key rightcommand was given twice"),
        // The first refusal wins, as it did when each was an `exit(2)`.
        (["--focused-field", "--bogus"], "dicta: unknown option --focused-field"),
    ])
    func refusals(arguments: [String], line: String) {
        #expect(Self.parse(arguments) == .refused(line))
    }

    @Test("--focused-fields is described as the initial choice, not as a switch")
    func focusedFieldsUsage() {
        #expect(DaemonOptions.usage.contains("the initial choice when setup has not been done"))
        #expect(!DaemonOptions.usage.contains("makes agterm optional"))
    }

    @Test("the trigger's default keys are the pair the hold snapshot names")
    func defaultHoldKeys() {
        #expect(HoldTrigger.Configuration().keys == HoldKey.defaultPair)
    }

    // MARK: - agterm at start-up

    @Test("a missing agtermctl is survived under every scope, and fatal only under --no-hold")
    func agtermAtStartup() {
        // The scope is not an input: it is read after this decision, and a flag that only seeds it
        // cannot change whether the daemon stays up.
        for flag in [false, true] {
            let armed = DaemonOptions(controlSocket: Self.socket, focusedFields: flag)
            #expect(armed.agtermAtStartup(found: true) == .present)
            guard case let .optional(notice) = armed.agtermAtStartup(found: false) else {
                Issue.record("a missing agtermctl with a key armed must not stop (flag: \(flag))")
                continue
            }
            #expect(notice.contains("agtermctl"))
            #expect(!notice.contains("--focused-fields"))
        }
    }

    @Test("a missing agtermctl is fatal under --no-hold, whatever the flag")
    func agtermAtStartupWithoutTrigger() {
        for flag in [false, true] {
            let unarmed = DaemonOptions(controlSocket: Self.socket, armHoldTrigger: false,
                                        focusedFields: flag)
            #expect(unarmed.agtermAtStartup(found: true) == .present)
            guard case let .fatal(fatal) = unarmed.agtermAtStartup(found: false) else {
                Issue.record("--no-hold without agterm must stop the daemon (flag: \(flag))")
                continue
            }
            #expect(fatal.contains("agtermctl"))
            #expect(fatal.contains("--no-hold"))
        }
    }

    // MARK: - the start-up lines about the choice

    static func bootstrap(_ scope: SetupScope, _ source: SetupBootstrap.Source,
                          flagIgnored: Bool = false, saveError: String? = nil) -> SetupBootstrap {
        SetupBootstrap(state: SetupState(scope: scope, offerSeen: scope == .otherApps),
                       source: source, flagIgnored: flagIgnored, saveError: saveError)
    }

    static let written = "; written to setup.json"
    static let origins: [(SetupBootstrap, String)] = [
        (bootstrap(.otherApps, .file), "setup: other-apps, from setup.json"),
        (bootstrap(.agtermOnly, .file), "setup: agterm-only, from setup.json"),
        (bootstrap(.otherApps, .migrated(flag: true, record: .lines(0))),
         "setup: other-apps, seeded from --focused-fields" + written),
        (bootstrap(.agtermOnly, .migrated(flag: false, record: .lines(1))),
         "setup: agterm-only, migrated: the record holds 1 entry, so this is an update"
            + written),
        (bootstrap(.agtermOnly, .migrated(flag: false, record: .lines(12))),
         "setup: agterm-only, migrated: the record holds 12 entries, so this is an update"
            + written),
        (bootstrap(.agtermOnly, .migrated(flag: false, record: .unreadable)),
         "setup: agterm-only, migrated: the record could not be read, so this is taken as an "
            + "update" + written),
        (bootstrap(.undecided, .migrated(flag: false, record: .lines(0))),
         "setup: undecided, migrated: the record holds nothing, so this is a fresh install"
            + written),
    ]

    @Test("the start-up lines name the scope and where it came from", arguments: origins)
    func startupOrigin(bootstrap: SetupBootstrap, line: String) {
        let lines = StartupLines.describe(bootstrap, agtermFound: true)
        #expect(lines.first == line)
        #expect(!lines.contains { $0.contains("ignored") })
        #expect(!lines.contains { $0.contains("setup problem") })
    }

    @Test("the start-up lines say the flag was ignored only when a file decided")
    func startupFlagIgnored() {
        let ignored = "setup: --focused-fields was ignored, because setup.json exists and decides"
        #expect(StartupLines.describe(Self.bootstrap(.agtermOnly, .file, flagIgnored: true),
                                      agtermFound: true)
            == ["setup: agterm-only, from setup.json", ignored])
        let unreadable = StartupLines.describe(
            Self.bootstrap(.agtermOnly, .unreadable(.newerSchema(found: 2)), flagIgnored: true),
            agtermFound: true)
        #expect(unreadable.last == ignored)
        #expect(!StartupLines.describe(Self.bootstrap(.otherApps, .file), agtermFound: true)
            .contains(ignored))
    }

    @Test("the start-up lines say a daemon without agterm and without a choice is not configured")
    func startupNotConfigured() {
        let fresh = Self.bootstrap(.undecided, .migrated(flag: false, record: .lines(0)))
        let alone = StartupLines.describe(fresh, agtermFound: false)
        #expect(alone.count == 2)
        #expect(alone.last?.hasPrefix("not configured: waiting for setup") == true)
        #expect(alone.last?.contains("dictactl configure") == true)
        // With agterm, undecided still dictates into agterm: waiting, but not "not configured".
        let beside = StartupLines.describe(fresh, agtermFound: true)
        #expect(beside.last?.hasPrefix("setup: waiting for setup") == true)
        #expect(!beside.contains { $0.contains("not configured") })
        // A choice already made waits for nothing, with or without agterm.
        for scope in [SetupScope.agtermOnly, .otherApps] {
            for found in [false, true] {
                #expect(!StartupLines.describe(Self.bootstrap(scope, .file), agtermFound: found)
                    .contains { $0.contains("waiting for setup") })
            }
        }
    }

    @Test("the start-up lines name a setup problem: an unusable file, or a first write that failed")
    func startupProblem() {
        let problem = SetupLoadProblem.unreadable(reason: "not a setup file: invalid JSON")
        let unreadable = StartupLines.describe(
            SetupBootstrap(state: SetupStore.whileUnreadable, source: .unreadable(problem),
                           flagIgnored: false, saveError: nil),
            agtermFound: false)
        #expect(unreadable == [
            "setup problem: setup.json is unreadable: not a setup file: invalid JSON; dicta "
                + "behaves as agterm-only and keeps the file as it is until a choice replaces it",
        ])
        let newer = StartupLines.describe(
            Self.bootstrap(.agtermOnly, .unreadable(.newerSchema(found: 3))), agtermFound: true)
        #expect(newer.first?.contains("schema 3") == true)

        // The migrated state still applies for the run, and the log says it was not kept.
        let unsaved = StartupLines.describe(
            Self.bootstrap(.undecided, .migrated(flag: false, record: .lines(0)),
                           saveError: "setup.json could not be saved: renaming over /x failed"),
            agtermFound: false)
        #expect(unsaved.count == 3)
        #expect(unsaved[0].hasSuffix("; in force for this run only"))
        #expect(unsaved[1]
            == "setup problem: setup.json could not be saved: renaming over /x failed")
        #expect(unsaved[2].hasPrefix("not configured"))
    }

    @Test("the start-up lines describe what bootstrap really returns")
    func startupFromStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dicta startup \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("setup.json")

        let first = SetupStore(url: url).bootstrap(flag: true, record: .lines(0), owner: .scratch())
        #expect(StartupLines.describe(first, agtermFound: false)
            == ["setup: other-apps, seeded from --focused-fields; written to setup.json"])
        let second = SetupStore(url: url).bootstrap(flag: true, record: .lines(0),
                                                    owner: .scratch())
        #expect(StartupLines.describe(second, agtermFound: false) == [
            "setup: other-apps, from setup.json",
            "setup: --focused-fields was ignored, because setup.json exists and decides",
        ])
    }
}
