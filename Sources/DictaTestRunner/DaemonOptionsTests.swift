import DictaCore
import DictaRuntime
import Foundation
import Testing

// The daemon's command line and the focused-field path's composition (D31), both of which used to
// be top-level code in `Sources/Dicta/main.swift` that no test could reach.
//
// The parser is held to what `main.swift` did before it moved, refusal text included: a wrapper
// script or a LaunchAgent that worked yesterday must not start failing for a reason that reads
// differently today. The wiring is held to invariant 14's "only when on": with the option off, not
// one system adapter is constructed.

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
        // be built (`FocusedFieldWiring`).
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

    // MARK: - the wiring

    /// Adapters that count, and hand out fakes.
    final class CountingAdapters: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [String] = []
        let frontmost = FakeFrontmost(bundleIdentifier: "com.microsoft.VSCode")
        let access = FakeFocusedFieldAccess()
        let poster = FakeEventPoster()

        var constructions: [String] { lock.withLock { made } }

        var adapters: FocusedFieldWiring.Adapters {
            FocusedFieldWiring.Adapters(
                frontmost: { self.note("frontmost"); return self.frontmost },
                access: { self.note("access"); return self.access },
                poster: { self.note("poster"); return self.poster })
        }

        private func note(_ name: String) { lock.withLock { made.append(name) } }
    }

    @Test("with focused fields off, the wiring is nil and constructs no system adapter",
          arguments: [true, false])
    func wiringOff(armHold: Bool) {
        let counting = CountingAdapters()
        let options = DaemonOptions(controlSocket: Self.socket, armHoldTrigger: armHold)

        let wired = FocusedFieldWiring.make(options: options, feedback: FakeNotifier(),
                                            adapters: counting.adapters)

        #expect(wired == nil)
        #expect(counting.constructions.isEmpty)
        #expect(counting.access.callLog.isEmpty)
        #expect(counting.frontmost.reads == 0)
    }

    @Test("with focused fields on, one frontmost source is built and shared, even with --no-hold",
          arguments: [true, false])
    func wiringOn(armHold: Bool) throws {
        let counting = CountingAdapters()
        let options = DaemonOptions(controlSocket: Self.socket, armHoldTrigger: armHold,
                                    focusedFields: true)

        let wired = try #require(FocusedFieldWiring.make(options: options,
                                                         feedback: FakeNotifier(),
                                                         adapters: counting.adapters))

        #expect(counting.constructions.filter { $0 == "frontmost" }.count == 1)
        #expect(counting.constructions.filter { $0 == "access" }.count == 1)
        #expect(wired.frontmost as? FakeFrontmost === counting.frontmost)
        #expect(wired.access as? FakeFocusedFieldAccess === counting.access)
        #expect(wired.trigger.access as? FakeFocusedFieldAccess === counting.access)
        #expect(wired.daemon.access as? FakeFocusedFieldAccess === counting.access)

        // The injector re-validates against the SAME source: with the shared one naming another
        // application, delivery is refused having read it, and nothing is posted.
        let field = FieldTarget(bundleID: "com.apple.Safari", appName: "Safari", pid: 777)
        #expect(throws: DeliveryFailure.self) {
            try wired.daemon.injector.inject("hello", into: field,
                                             handle: FakeFocusedFieldAccess.textArea().handle)
        }
        #expect(counting.frontmost.reads > 0)
        #expect(counting.poster.posts.isEmpty)
    }

    @Test("the start-up line names the option and, only when it is on, the grant")
    func startupLine() {
        #expect(FocusedFieldWiring.startupLine(nil)
            == "focused fields: off, accessibility: not checked")

        for trusted in [true, false] {
            let counting = CountingAdapters()
            counting.access.setTrusted(trusted)
            let wired = FocusedFieldWiring.make(
                options: DaemonOptions(controlSocket: Self.socket, focusedFields: true),
                feedback: FakeNotifier(), adapters: counting.adapters)
            #expect(FocusedFieldWiring.startupLine(wired)
                == "focused fields: on, accessibility: \(trusted ? "granted" : "not granted")")
        }
    }
}
