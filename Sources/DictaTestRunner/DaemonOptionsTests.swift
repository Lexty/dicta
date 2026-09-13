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

    // MARK: - agterm at start-up

    @Test("a missing agtermctl is fatal with focused fields off, and survived with them on")
    func agtermAtStartup() {
        let off = DaemonOptions(controlSocket: Self.socket)
        let on = DaemonOptions(controlSocket: Self.socket, focusedFields: true)
        #expect(off.agtermAtStartup(found: true) == .present)
        #expect(on.agtermAtStartup(found: true) == .present)
        guard case let .fatal(fatal) = off.agtermAtStartup(found: false) else {
            Issue.record("a missing agtermctl with the option off must stop the daemon")
            return
        }
        #expect(fatal.contains("agtermctl"))
        guard case let .optional(notice) = on.agtermAtStartup(found: false) else {
            Issue.record("a missing agtermctl with the option on must not stop the daemon")
            return
        }
        #expect(notice.contains("agtermctl"))
        #expect(notice.contains("focused fields"))
    }

    @Test("a missing agtermctl is fatal under --no-hold even with focused fields on")
    func agtermAtStartupWithoutTrigger() {
        let unarmed = DaemonOptions(controlSocket: Self.socket, armHoldTrigger: false,
                                    focusedFields: true)
        #expect(unarmed.agtermAtStartup(found: true) == .present)
        guard case let .fatal(fatal) = unarmed.agtermAtStartup(found: false) else {
            Issue.record("--no-hold without agterm must stop the daemon")
            return
        }
        #expect(fatal.contains("agtermctl"))
        #expect(fatal.contains("--no-hold"))
    }
}
