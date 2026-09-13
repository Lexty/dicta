import DictaCore
import DictaRuntime
import Foundation
import Testing

// The focused-field path behind its gate (D31, invariant 14): built at most once, admitted by
// generation, and told the grant only by checks somebody asked for.
//
// Every adapter is made through factories that count, so "never opened calls no adapter" is an
// assertion about an empty list, and every grant check lands in the fake's call log, so "no timer"
// is an assertion that the log holds exactly the checks the test made happen.

@Suite("focused-field switch")
struct FocusedFieldSwitchTests {
    /// Adapters that count, and hand out fakes.
    final class CountingAdapters: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [String] = []
        let access = FakeFocusedFieldAccess()
        let poster = FakeEventPoster()

        var constructions: [String] { lock.withLock { made } }

        var adapters: FocusedFieldWiring.Adapters {
            FocusedFieldWiring.Adapters(
                access: { self.note("access"); return self.access },
                poster: { self.note("poster"); return self.poster })
        }

        private func note(_ name: String) { lock.withLock { made.append(name) } }
    }

    /// Every grant the switch passed on, in order.
    final class Grants: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool] = []

        var told: [Bool] { lock.withLock { values } }

        func note(_ value: Bool) { lock.withLock { values.append(value) } }
    }

    struct Rig {
        let counting = CountingAdapters()
        let frontmost = FakeFrontmost(bundleIdentifier: "com.microsoft.VSCode")
        let grants = Grants()
        let fieldSwitch: FocusedFieldSwitch

        init(trusted: Bool = true) {
            counting.access.setTrusted(trusted)
            let grants = grants
            fieldSwitch = FocusedFieldSwitch(frontmost: frontmost, feedback: FakeNotifier(),
                                             adapters: counting.adapters,
                                             onAccessibility: { grants.note($0) })
        }
    }

    // MARK: - never opened

    @Test("a switch never opened constructs no system adapter and makes no accessibility call")
    func neverOpened() {
        let rig = Rig()

        #expect(rig.fieldSwitch.current == nil)
        #expect(rig.fieldSwitch.built == nil)
        #expect(rig.fieldSwitch.grant == nil)
        #expect(rig.fieldSwitch.startupLine == "focused fields: off, accessibility: not checked")
        // A report nobody was admitted to make is discarded like any stale one.
        #expect(!rig.fieldSwitch.report(trusted: true, generation: 0))

        #expect(rig.counting.constructions.isEmpty)
        #expect(rig.counting.access.callLog.isEmpty)
        #expect(rig.frontmost.reads == 0)
        #expect(rig.grants.told.isEmpty)
    }

    @Test("closing a switch that was never opened still builds nothing")
    func closedFirst() {
        let rig = Rig()

        rig.fieldSwitch.setOpen(false)

        #expect(rig.fieldSwitch.current == nil)
        #expect(rig.fieldSwitch.built == nil)
        #expect(rig.counting.constructions.isEmpty)
        #expect(rig.counting.access.callLog.isEmpty)
    }

    // MARK: - opening

    @Test("opening builds one wiring from the given frontmost source and checks the grant once")
    func opening() throws {
        let rig = Rig()

        rig.fieldSwitch.setOpen(true)

        let admitted = try #require(rig.fieldSwitch.current)
        #expect(rig.counting.constructions == ["access", "poster"])
        #expect(rig.counting.access.callLog == [.isTrusted])
        #expect(rig.fieldSwitch.grant == true)
        #expect(rig.grants.told == [true])

        let wired = admitted.wiring
        #expect(wired.frontmost as? FakeFrontmost === rig.frontmost)
        #expect(wired.access as? FakeFocusedFieldAccess === rig.counting.access)
        #expect(wired.trigger.access as? FakeFocusedFieldAccess === rig.counting.access)
        #expect(wired.daemon.access as? FakeFocusedFieldAccess === rig.counting.access)
        #expect(rig.fieldSwitch.built?.access as? FakeFocusedFieldAccess === rig.counting.access)

        // The injector re-validates against the SAME source it was given: with that source naming
        // another application, delivery is refused having read it, and nothing is posted.
        let field = FieldTarget(bundleID: "com.apple.Safari", appName: "Safari", pid: 777)
        #expect(throws: DeliveryFailure.self) {
            try wired.daemon.injector.inject("hello", into: field,
                                             handle: FakeFocusedFieldAccess.textArea().handle)
        }
        #expect(rig.frontmost.reads > 0)
        #expect(rig.counting.poster.posts.isEmpty)
    }

    @Test("closing and reopening builds nothing, and the built wiring survives the close")
    func reopening() throws {
        let rig = Rig()
        rig.fieldSwitch.setOpen(true)
        let first = try #require(rig.fieldSwitch.built)

        rig.fieldSwitch.setOpen(false)
        #expect(rig.fieldSwitch.current == nil)
        #expect(rig.fieldSwitch.grant == nil)
        let survived = try #require(rig.fieldSwitch.built)
        #expect(survived.access as? FakeFocusedFieldAccess
            === first.access as? FakeFocusedFieldAccess)

        rig.fieldSwitch.setOpen(true)
        let again = try #require(rig.fieldSwitch.current)
        #expect(again.wiring.access as? FakeFocusedFieldAccess
            === first.access as? FakeFocusedFieldAccess)
        #expect(rig.counting.constructions == ["access", "poster"])
        // One check per opening, and none for the close.
        #expect(rig.counting.access.callLog == [.isTrusted, .isTrusted])
    }

    @Test("every setOpen bumps the generation current returns")
    func generations() throws {
        let rig = Rig()
        var seen: [UInt64] = []

        rig.fieldSwitch.setOpen(true)
        seen.append(try #require(rig.fieldSwitch.current).generation)
        rig.fieldSwitch.setOpen(true)
        seen.append(try #require(rig.fieldSwitch.current).generation)
        rig.fieldSwitch.setOpen(false)
        #expect(rig.fieldSwitch.current == nil)
        rig.fieldSwitch.setOpen(false)
        rig.fieldSwitch.setOpen(true)
        seen.append(try #require(rig.fieldSwitch.current).generation)

        #expect(seen == [1, 2, 5])
    }

    // MARK: - reports

    @Test("a report under the current generation updates the grant and is passed on")
    func currentReport() throws {
        let rig = Rig(trusted: false)
        rig.fieldSwitch.setOpen(true)
        let admitted = try #require(rig.fieldSwitch.current)
        #expect(rig.fieldSwitch.grant == false)

        #expect(rig.fieldSwitch.report(trusted: true, generation: admitted.generation))
        #expect(rig.fieldSwitch.grant == true)
        #expect(rig.fieldSwitch.report(trusted: false, generation: admitted.generation))
        #expect(rig.fieldSwitch.grant == false)

        #expect(rig.grants.told == [false, true, false])
        // Reports carry a check the reader made; the switch makes none of its own for them.
        #expect(rig.counting.access.callLog == [.isTrusted])
    }

    @Test("a report from a closed switch is discarded and passed on to nobody")
    func closedReport() throws {
        let rig = Rig()
        rig.fieldSwitch.setOpen(true)
        let admitted = try #require(rig.fieldSwitch.current)
        rig.fieldSwitch.setOpen(false)

        #expect(!rig.fieldSwitch.report(trusted: false, generation: admitted.generation))
        #expect(!rig.fieldSwitch.report(trusted: false, generation: admitted.generation + 1))

        #expect(rig.fieldSwitch.grant == nil)
        #expect(rig.grants.told == [true])
    }

    @Test("a report from before a close-and-reopen does not overwrite the new generation's grant")
    func staleReport() throws {
        let rig = Rig(trusted: true)
        rig.fieldSwitch.setOpen(true)
        let before = try #require(rig.fieldSwitch.current)

        rig.fieldSwitch.setOpen(false)
        rig.counting.access.setTrusted(false)
        rig.fieldSwitch.setOpen(true)
        let after = try #require(rig.fieldSwitch.current)
        #expect(after.generation != before.generation)
        #expect(rig.fieldSwitch.grant == false)

        // The earlier reader's check comes back late, saying the grant was there.
        #expect(!rig.fieldSwitch.report(trusted: true, generation: before.generation))

        #expect(rig.fieldSwitch.grant == false)
        #expect(rig.grants.told == [true, false])
    }

    // MARK: - no poll

    @Test("no timer checks the grant: the log holds exactly the checks that were asked for")
    func noTimer() async throws {
        let rig = Rig()

        rig.fieldSwitch.setOpen(true)
        let first = try #require(rig.fieldSwitch.current)
        rig.fieldSwitch.report(trusted: true, generation: first.generation)
        rig.fieldSwitch.setOpen(false)
        rig.fieldSwitch.report(trusted: false, generation: first.generation)
        rig.fieldSwitch.setOpen(true)
        rig.fieldSwitch.setOpen(false)
        rig.fieldSwitch.setOpen(true)
        rig.fieldSwitch.report(trusted: true,
                               generation: try #require(rig.fieldSwitch.current).generation)

        // Three openings, three checks; then long enough for any sub-second ticker to have fired.
        #expect(rig.counting.access.callLog == [.isTrusted, .isTrusted, .isTrusted])
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.counting.access.callLog == [.isTrusted, .isTrusted, .isTrusted])
        #expect(rig.grants.told == [true, true, true, true, true])
    }

    // MARK: - the start-up line

    @Test("the start-up line names the gate and, only when open, the grant it already checked")
    func startupLine() {
        for trusted in [true, false] {
            let rig = Rig(trusted: trusted)
            #expect(rig.fieldSwitch.startupLine
                == "focused fields: off, accessibility: not checked")

            rig.fieldSwitch.setOpen(true)
            #expect(rig.fieldSwitch.startupLine
                == "focused fields: on, accessibility: \(trusted ? "granted" : "not granted")")
            // The line is read from the opening's check, not a second one.
            #expect(rig.counting.access.callLog == [.isTrusted])
        }
    }
}
