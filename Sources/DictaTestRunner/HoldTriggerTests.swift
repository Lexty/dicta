import DictaCore
import DictaIPC
import DictaRuntime
import Foundation
import Testing

// Push-to-talk (D5, D21, D22, D23) and the two invariants it adds, 12 and 13.
//
// Everything here is driven a step at a time through `HoldTrigger.sample()` and `perform(_:)` with
// a `FakeClock`, so a gesture whose whole subject is duration is asserted without waiting a single
// real millisecond. The one rule no assertion in this file can reach is invariant 11 -- that the
// trigger reads modifier state and never a key stream -- because it is a property of which API is
// called rather than of what happens. `Scripts/linkage.sh` reads that one off the built binary.

@Suite("modifier watch")
struct ModifierWatchTests {
    @Test("the first sample primes the watch rather than reporting an edge")
    func firstSamplePrimes() {
        var watch = ModifierWatch(key: .rightControl)
        // The key is already down: a daemon that started while the user happened to be holding it.
        #expect(watch.sample(HoldKey.rightControl.bit) == nil)
        #expect(watch.isHeld)
        // And the release that follows is a real edge, so the state is not merely swallowed.
        #expect(watch.sample(0) == .up)
    }

    @Test("a key pressed and released produces exactly one down and one up")
    func oneDownOneUp() {
        var watch = ModifierWatch(key: .rightControl)
        #expect(watch.sample(0) == nil)
        #expect(watch.sample(HoldKey.rightControl.bit) == .down)
        #expect(watch.sample(HoldKey.rightControl.bit) == nil)
        #expect(watch.sample(HoldKey.rightControl.bit) == nil)
        #expect(watch.sample(0) == .up)
        #expect(watch.sample(0) == nil)
    }

    @Test("left Control moving is never mistaken for the right one")
    func leftIsNotRight() {
        // The measurement this asserts is F6: the device-dependent bits separate the sides, right
        // Control 0x2000 against left Control 0x1. Without it every `⌃C` in a terminal would open
        // the microphone, which is the whole reason the key is a side and not just a modifier.
        let leftControl: UInt64 = 0x0000_0001
        var watch = ModifierWatch(key: .rightControl)
        #expect(watch.sample(0) == nil)
        #expect(watch.sample(leftControl) == nil)
        #expect(watch.sample(leftControl | 0x0004_0000) == nil)
        #expect(watch.sample(0) == nil)
        #expect(!watch.isHeld)
    }

    @Test("another modifier joining the watched key is not a second edge")
    func otherModifiersAreIgnored() {
        let shift: UInt64 = 0x0000_0002
        var watch = ModifierWatch(key: .rightControl)
        #expect(watch.sample(0) == nil)
        #expect(watch.sample(HoldKey.rightControl.bit) == .down)
        #expect(watch.sample(HoldKey.rightControl.bit | shift) == nil)
        #expect(watch.sample(HoldKey.rightControl.bit) == nil)
        #expect(watch.sample(0) == .up)
    }
}

@Suite("hold keys")
struct HoldKeyTests {
    @Test("every key has its own bit, and none of them is a left-hand one")
    func theBitsAreDistinctAndRightHanded() {
        // The left-hand twins, which are what the sides exist to be told from (F6, F6a). A case
        // added with the wrong constant would arm `⌃C` or `⌘V` themselves rather than the key
        // beside them, and nothing else in the suite would notice: every gesture test drives the
        // fake keyboard through `HoldKey.bit`, so it would agree with the mistake.
        let leftHanded: Set<UInt64> = [0x0000_0001, 0x0000_0002, 0x0000_0008, 0x0000_0020]
        var seen: Set<UInt64> = []
        for key in HoldKey.allCases {
            #expect(!leftHanded.contains(key.bit), "\(key) carries a left-hand bit")
            #expect(key.bit != 0, "\(key) carries no bit at all")
            // The ordinary side-blind masks, which say only that SOME Control is down.
            #expect(key.bit < 0x0001_0000, "\(key) is a side-blind mask, not a device bit")
            #expect(seen.insert(key.bit).inserted, "\(key) shares its bit with another key")
        }
    }

    @Test("every key name --hold-key accepts round-trips to the key it names")
    func everyNameResolves() {
        for key in HoldKey.allCases {
            #expect(HoldKey.named(key.rawValue) == key)
            // Typed by a person into a LaunchAgent plist, so the case they use is theirs to pick.
            #expect(HoldKey.named(key.rawValue.lowercased()) == key)
            #expect(HoldKey.named(key.rawValue.uppercased()) == key)
            #expect(HoldKey.everyName.contains(key.rawValue))
            // The log line names the key to a person, so it says a side out loud.
            #expect(key.describedName.contains("right"))
        }
    }

    @Test("a key name nobody defined is refused rather than guessed at")
    func anUnknownNameIsRefused() {
        // `--hold-key` exits on nil. Resolving "rightshift" to something near it would arm a key
        // the user did not ask for, which is worse than the typo.
        for name in ["", "right", "rightShif", "leftControl", "fn"] {
            #expect(HoldKey.named(name) == nil, "\"\(name)\" resolved to a key")
        }
    }
}

@Suite("hold watch")
struct HoldWatchTests {
    static let rightControl = HoldKey.rightControl.bit
    static let rightCommand = HoldKey.rightCommand.bit
    static let watched: [HoldKey] = [.rightControl, .rightCommand]

    @Test("either armed key starts a gesture of its own")
    func eitherKeyArms() {
        // F6a's whole point: the external keyboard's right Control and the built-in keyboard's
        // right Command are the same gesture, and neither is the special case.
        for key in Self.watched {
            var watch = HoldWatch(keys: Self.watched)
            #expect(watch.sample(0) == nil)
            #expect(watch.sample(key.bit) == HoldEdge(key: key, edge: .down))
            #expect(watch.owner == key)
            #expect(watch.sample(0) == HoldEdge(key: key, edge: .up))
            #expect(watch.owner == nil)
        }
    }

    @Test("the key that started the gesture is the only one that can end it")
    func theOwnerEndsIt() {
        // The failure this forbids: right Command pressed and released in the middle of a dictation
        // held on right Control would otherwise stop and DELIVER it, while the user goes on
        // speaking into a microphone that closed.
        var watch = HoldWatch(keys: Self.watched)
        #expect(watch.sample(0) == nil)
        #expect(watch.sample(Self.rightControl) == HoldEdge(key: .rightControl, edge: .down))
        // The other key joins and leaves: not one edge is reported for either move.
        #expect(watch.sample(Self.rightControl | Self.rightCommand) == nil)
        #expect(watch.sample(Self.rightControl) == nil)
        #expect(watch.owner == .rightControl)
        // And the owner still ends it, which is what makes the swallowing above a filter and not a
        // watch that has lost track of the world.
        #expect(watch.sample(0) == HoldEdge(key: .rightControl, edge: .up))
    }

    @Test("a key that moved during someone else's hold leaves no edge behind for later")
    func theSwallowedKeyIsStillSampled() {
        // The trap in filtering by owner: a watch that is not sampled keeps the state it had, so a
        // key pressed during a hold and still down when the hold ends would report a stale `down`
        // the next time anything looked -- opening the microphone for a key the user pressed
        // minutes ago. Every watch is sampled on every call; only the reporting is filtered.
        var watch = HoldWatch(keys: Self.watched)
        #expect(watch.sample(0) == nil)
        #expect(watch.sample(Self.rightControl) == HoldEdge(key: .rightControl, edge: .down))
        // The second key goes down mid-hold and stays down THROUGH the release of the first.
        #expect(watch.sample(Self.rightControl | Self.rightCommand) == nil)
        #expect(watch.sample(Self.rightCommand) == HoldEdge(key: .rightControl, edge: .up))
        // It is held, and it is not a gesture: it went down while another key owned the watch.
        #expect(watch.owner == nil)
        #expect(watch.sample(Self.rightCommand) == nil)
        // Releasing it says nothing either -- there is no attempt for it to end.
        #expect(watch.sample(0) == nil)
        // And the next real press of it is an ordinary gesture again.
        #expect(watch.sample(Self.rightCommand) == HoldEdge(key: .rightCommand, edge: .down))
    }

    @Test("the second key starts the next gesture once the first has let go")
    func ownershipIsHandedOn() {
        var watch = HoldWatch(keys: Self.watched)
        #expect(watch.sample(0) == nil)
        #expect(watch.sample(Self.rightControl) == HoldEdge(key: .rightControl, edge: .down))
        #expect(watch.sample(0) == HoldEdge(key: .rightControl, edge: .up))
        #expect(watch.sample(Self.rightCommand) == HoldEdge(key: .rightCommand, edge: .down))
        #expect(watch.sample(0) == HoldEdge(key: .rightCommand, edge: .up))
    }

    @Test("two keys going down inside one sample produce one gesture, not two")
    func aTieIsBrokenByOrder() {
        // 16 ms is long enough for both to arrive in one poll (F7's interval), and two `down`s out
        // of one sample would be two attempts, the second started over the top of the first.
        var watch = HoldWatch(keys: Self.watched)
        #expect(watch.sample(0) == nil)
        let edge = watch.sample(Self.rightControl | Self.rightCommand)
        #expect(edge == HoldEdge(key: .rightControl, edge: .down))
        #expect(watch.owner == .rightControl)
        // The one that lost the tie is held and silent, and the winner still ends the gesture.
        #expect(watch.sample(Self.rightCommand) == HoldEdge(key: .rightControl, edge: .up))
    }

    @Test("the first sample primes every watch rather than reporting an edge")
    func theFirstSamplePrimesAll() {
        // A daemon that started while the user happened to be holding a key. Priming is per watch,
        // and the release of a key that was never a gesture says nothing at all: `HoldToTalk` would
        // ignore it, but an `up` reported with no owner is a claim about an attempt that never was.
        var watch = HoldWatch(keys: Self.watched)
        #expect(watch.sample(Self.rightCommand) == nil)
        #expect(watch.isHeld)
        #expect(watch.owner == nil)
        #expect(watch.sample(0) == nil)
    }

    @Test("the left-hand twin of an armed key never arms anything")
    func leftHandTwinsAreNotArmed() {
        // F6 for right Control, F6a for right Command: `0x1` against `0x2000`, `0x8` against
        // `0x10`. Without the sides every `⌃C` and every `⌘V` in a terminal would open the
        // microphone, which is the reason the key is a side and not merely a modifier.
        let leftControl: UInt64 = 0x0000_0001
        let leftCommand: UInt64 = 0x0000_0008
        let anyControl: UInt64 = 0x0004_0000
        let anyCommand: UInt64 = 0x0010_0000
        var watch = HoldWatch(keys: Self.watched)
        #expect(watch.sample(0) == nil)
        #expect(watch.sample(leftControl | anyControl) == nil)
        #expect(watch.sample(leftCommand | anyCommand) == nil)
        #expect(watch.sample(leftControl | leftCommand | anyControl | anyCommand) == nil)
        #expect(watch.sample(0) == nil)
        #expect(!watch.isHeld)
    }

    @Test("the non-coalesced bit the real keyboard sets is not mistaken for a key")
    func theNoiseBitIsIgnored() {
        // Measured in F6a and worth an assertion because it is exactly the shape of thing that
        // looks like a key: every sample after the first press carried `0x100`
        // (`NX_NONCOALSESCEDMASK`) whether or not anything was down.
        let noise: UInt64 = 0x0000_0100
        var watch = HoldWatch(keys: Self.watched)
        #expect(watch.sample(0) == nil)
        #expect(watch.sample(noise) == nil)
        let pressed = watch.sample(noise | Self.rightCommand)
        #expect(pressed == HoldEdge(key: .rightCommand, edge: .down))
        #expect(watch.sample(noise) == HoldEdge(key: .rightCommand, edge: .up))
    }
}

@Suite("hold gesture")
struct HoldToTalkTests {
    static let start = Date(timeIntervalSince1970: 1_766_000_000)

    @Test("a hold past the floor delivers, naming the attempt it started")
    func longHoldDelivers() {
        var gesture = HoldToTalk(floor: 0.3)
        #expect(gesture.down(at: Self.start) == .start)
        gesture.started(attempt: 7)
        #expect(gesture.up(at: Self.start.addingTimeInterval(1.4)) == .deliver(attempt: 7))
        #expect(!gesture.isHolding)
    }

    @Test("a hold under the floor discards rather than delivering")
    func shortHoldDiscards() {
        // Invariant 12, and D21's reason for existing: 150 ms is the longest ordinary press F6
        // measured (F6a has since seen 195 on the other keyboard, still under the floor), so a
        // combination the user typed with an armed key lands here and not in a pane.
        var gesture = HoldToTalk(floor: 0.3)
        #expect(gesture.down(at: Self.start) == .start)
        gesture.started(attempt: 3)
        #expect(gesture.up(at: Self.start.addingTimeInterval(0.15)) == .discard(attempt: 3))
    }

    @Test("the floor separates the two populations it was measured against, and only those")
    func theFloorSeparatesTheMeasuredPopulations() {
        // Deliberately NOT an assertion about the exact boundary. `Date` arithmetic is binary
        // floating point: `start + 0.3` less `start` is 0.29999999999999993, so "exactly the floor"
        // is not a value a test can hand to the type, and a test that pretended otherwise would be
        // asserting about Double rather than about D21. What is asserted is the claim D21 actually
        // makes -- that the longest press F6 measured discards and the shortest plausible dictation
        // delivers, with a factor of two of clear air on each side.
        for pressed in [0.09, 0.15, 0.2] {
            var gesture = HoldToTalk(floor: 0.3)
            _ = gesture.down(at: Self.start)
            gesture.started(attempt: 1)
            #expect(gesture.up(at: Self.start.addingTimeInterval(pressed))
                == .discard(attempt: 1), "a \(pressed) s press is not a dictation")
        }
        for held in [0.6, 1.5, 600] {
            var gesture = HoldToTalk(floor: 0.3)
            _ = gesture.down(at: Self.start)
            gesture.started(attempt: 2)
            #expect(gesture.up(at: Self.start.addingTimeInterval(held))
                == .deliver(attempt: 2), "a \(held) s hold is a dictation")
        }
    }

    @Test("a release with no gesture in flight says nothing")
    func releaseWithoutPress() {
        var gesture = HoldToTalk()
        #expect(gesture.up(at: Self.start) == .ignore)
    }

    @Test("an abandoned gesture is silent when the key finally comes up")
    func abandonedGestureIsSilent() {
        var gesture = HoldToTalk(floor: 0.3)
        #expect(gesture.down(at: Self.start) == .start)
        gesture.abandon()
        #expect(gesture.up(at: Self.start.addingTimeInterval(2)) == .ignore)
    }

    @Test("a gesture that never received an attempt id can never end one")
    func noAttemptMeansNoCommand() {
        // The structural half of D23. `deliver` and `discard` carry a non-optional id, so the only
        // way to end an attempt is to have been told which one -- and an `abort` carrying no id
        // ends whatever is live, which during a refused start is somebody else's dictation.
        var gesture = HoldToTalk(floor: 0.3)
        #expect(gesture.down(at: Self.start) == .start)
        #expect(gesture.up(at: Self.start.addingTimeInterval(5)) == .ignore)
    }

    @Test("a second press with no release between them starts nothing new")
    func doubleDownIsIgnored() {
        var gesture = HoldToTalk(floor: 0.3)
        #expect(gesture.down(at: Self.start) == .start)
        gesture.started(attempt: 1)
        #expect(gesture.down(at: Self.start.addingTimeInterval(0.1)) == .ignore)
        #expect(gesture.up(at: Self.start.addingTimeInterval(2)) == .deliver(attempt: 1))
    }
}

@Suite("active session")
struct ActiveSessionTests {
    /// A tree in the shape `agtermctl tree --json` actually answers with, trimmed to the fields
    /// this lookup reads.
    static func tree(_ workspaces: String) -> String {
        #"{"ok":true,"result":{"tree":{"workspaces":[\#(workspaces)]}}}"#
    }

    /// The same tree, with agterm's native picker awaiting an answer in this window.
    static func treeWithPicker(_ workspaces: String, picker: String) -> String {
        #"{"ok":true,"result":{"tree":{"pickPending":"\#(picker)","workspaces":[\#(workspaces)]}}}"#
    }

    static func workspace(active: Bool, sessions: String) -> String {
        #"{"active":\#(active),"sessions":[\#(sessions)]}"#
    }

    static func session(_ id: String, active: Bool) -> String {
        #"{"id":"\#(id)","active":\#(active),"surfaces":[{"kind":"left","active":true}]}"#
    }

    @Test("the active session is read from the active workspace and not from every workspace")
    func activeWorkspaceWins() throws {
        // The tree agterm answers with today marks exactly one session active across the whole
        // thing, so this shape is not one that has been observed -- it is the shape that would make
        // the lookup pick a session from a workspace the user is not looking at, if agterm ever
        // started marking the last-used session of every workspace. The filter and this test are
        // what keep that from being silent.
        let json = Self.tree([
            Self.workspace(active: false, sessions: Self.session("stale", active: true)),
            Self.workspace(active: true, sessions: Self.session("live", active: true)),
        ].joined(separator: ","))
        #expect(try Agterm.activeSession(inTree: json) == "live")
    }

    @Test("a tree with no active workspace refuses rather than picking one")
    func noActiveWorkspace() {
        let json = Self.tree(Self.workspace(active: false,
                                            sessions: Self.session("a", active: true)))
        #expect(throws: AgtermError.noActiveSession) {
            try Agterm.activeSession(inTree: json)
        }
    }

    @Test("a workspace whose sessions are all inactive refuses rather than picking one")
    func noActiveSessionInIt() {
        let json = Self.tree(Self.workspace(active: true,
                                            sessions: Self.session("a", active: false)))
        #expect(throws: AgtermError.noActiveSession) {
            try Agterm.activeSession(inTree: json)
        }
    }

    @Test("two sessions claiming to be active is a refusal, never a choice")
    func ambiguousActiveSession() {
        let json = Self.tree(Self.workspace(active: true, sessions: [
            Self.session("a", active: true),
            Self.session("b", active: true),
        ].joined(separator: ",")))
        #expect(throws: AgtermError.ambiguousActiveSession(sessions: ["a", "b"])) {
            try Agterm.activeSession(inTree: json)
        }
    }

    @Test("the focused target carries the active session's own active pane, from one read")
    func focusedTargetIsWhole() throws {
        let json = Self.tree(Self.workspace(active: true, sessions: [
            Self.session("other", active: false),
            Self.session("live", active: true),
        ].joined(separator: ",")))
        #expect(try Agterm.focusedTarget(inTree: json) == Target(sessionID: "live", pane: .left))
    }

    @Test("a focused target whose pane cannot be named is refused, exactly as a chord's would be")
    func focusedTargetFailsClosed() {
        // A held key must not be able to reach a pane a chord could not (D6). The pane rule is
        // literally the same code path; this asserts it is still reached from here.
        let surfaces = #"{"kind":"left","active":true},{"kind":"right","active":true}"#
        let twoActivePanes = #"{"id":"live","active":true,"surfaces":[\#(surfaces)]}"#
        let json = Self.tree(Self.workspace(active: true, sessions: twoActivePanes))
        #expect(throws: AgtermError.ambiguousPane(session: "live", panes: ["left", "right"])) {
            try Agterm.focusedTarget(inTree: json)
        }
    }

    @Test("a picker open in the window refuses the dictation rather than typing behind it")
    func pickerOpenRefuses() {
        // D24. agterm's picker is agterm's OWN window, so D22's frontmost check passes and the
        // dictation would land in the terminal behind the dialog -- not where the user is looking,
        // and with no sign that it went anywhere else. The tree names the picker, so the refusal
        // costs nothing that was not already being read.
        let json = Self.treeWithPicker(
            Self.workspace(active: true, sessions: Self.session("live", active: true)),
            picker: "pick-7"
        )
        #expect(throws: AgtermError.pickerOpen("pick-7")) {
            try Agterm.focusedTarget(inTree: json)
        }
        // And the same tree WITHOUT the picker resolves, so the refusal is the picker's doing and
        // not something else about the shape.
        let sessions = Self.session("live", active: true)
        let open = Self.tree(Self.workspace(active: true, sessions: sessions))
        let resolved = try? Agterm.focusedTarget(inTree: open)
        #expect(resolved == Target(sessionID: "live", pane: .left))
    }

    @Test("a refusal from agterm is a refusal here, not an empty tree")
    func agtermRefusal() {
        #expect(throws: (any Error).self) {
            try Agterm.activeSession(inTree: #"{"ok":false,"error":"no window"}"#)
        }
    }
}

@Suite("hold trigger")
struct HoldTriggerTests {
    /// Everything one gesture needs, and the handles to interfere with it.
    struct Rig {
        let trigger: HoldTrigger
        let modifiers: FakeModifiers
        let frontmost: FakeFrontmost
        let notifier: FakeNotifier
        let daemon: FakeDaemonDoor
        let clock: FakeClock

        init(floor: TimeInterval = 0.3) {
            let modifiers = FakeModifiers()
            let frontmost = FakeFrontmost()
            let notifier = FakeNotifier()
            let daemon = FakeDaemonDoor()
            let clock = FakeClock()
            self.modifiers = modifiers
            self.frontmost = frontmost
            self.notifier = notifier
            self.daemon = daemon
            self.clock = clock
            trigger = HoldTrigger(
                configuration: HoldTrigger.Configuration(floor: floor),
                modifiers: modifiers,
                frontmost: frontmost,
                notifier: notifier,
                clock: clock,
                send: { try daemon.send($0) }
            )
            // The priming sample, with the key up -- exactly what the real loop does on its first
            // turn, and what makes every `press` below a real edge.
            _ = trigger.sample()
        }

        /// One whole gesture: press, wait, release. The key defaults to D5's own, so every test
        /// written before a second one was armed still says what it said.
        func hold(_ key: HoldKey = .rightControl, for seconds: TimeInterval) {
            modifiers.press(key)
            if let down = trigger.sample() { trigger.perform(down) }
            clock.advance(by: seconds)
            modifiers.release(key)
            if let up = trigger.sample() { trigger.perform(up) }
        }

        /// One sample of whatever the fake keyboard now says, performed if it produced an edge.
        @discardableResult
        func step() -> HoldTrigger.Pending? {
            guard let edge = trigger.sample() else { return nil }
            trigger.perform(edge)
            return edge
        }
    }

    @Test("a hold inside agterm starts a dictation and stops it in clean on release")
    func theOrdinaryGesture() {
        let rig = Rig()
        rig.hold(for: 2)
        #expect(rig.daemon.verbs == [.start, .stop])
        // No session, and `focus: true` instead: the daemon reads both halves of the target from
        // one tree, so the hold path spends no `agtermctl` subprocess of its own (§5).
        #expect(rig.daemon.requests[0].sessionID == nil)
        #expect(rig.daemon.requests[0].focus == true)
        #expect(rig.daemon.requests[1].mode == .clean)
        #expect(rig.notifier.signals.isEmpty)
    }

    @Test("the command that ends a hold names the attempt the start returned")
    func theReleaseNamesItsAttempt() {
        // D23. The id is what makes a release landing on an already-finished attempt a silent
        // no-op rather than an audible "nothing to stop".
        let rig = Rig()
        rig.daemon.queue(Response(kind: .accepted, state: .warming, attempt: 42))
        rig.hold(for: 2)
        #expect(rig.daemon.requests[1].attempt == 42)
    }

    @Test("a hold under the floor aborts and never stops")
    func theShortHoldAborts() {
        // Invariant 12 end to end: a right-Control combination typed at ordinary speed reaches the
        // daemon as an abort, so no text is produced and nothing is injected.
        let rig = Rig()
        rig.hold(for: 0.12)
        #expect(rig.daemon.verbs == [.start, .abort])
        #expect(rig.notifier.signals.isEmpty)
    }

    @Test("the hold key does nothing at all while another application is frontmost")
    func notFrontmostIsSilent() {
        // Invariant 13 and D22. Silent is the assertion, not merely "does not dictate": a
        // notification here would fire on every right-Control combination typed in a browser.
        let rig = Rig()
        rig.frontmost.set("com.apple.Safari")
        rig.hold(for: 2)
        #expect(rig.daemon.requests.isEmpty)
        #expect(rig.notifier.signals.isEmpty)
    }

    @Test("focus moving to another application mid-hold does not stop the delivery")
    func frontmostIsReadAtThePress() {
        // D4's shape, applied to the new trigger: the target is captured when the key goes down and
        // is never re-decided. Looking away while speaking must not lose the dictation.
        let rig = Rig()
        rig.modifiers.press(.rightControl)
        if let down = rig.trigger.sample() { rig.trigger.perform(down) }
        rig.frontmost.set("com.apple.Safari")
        rig.clock.advance(by: 2)
        rig.modifiers.release(.rightControl)
        if let up = rig.trigger.sample() { rig.trigger.perform(up) }
        #expect(rig.daemon.verbs == [.start, .stop])
    }

    @Test("a session that cannot be resolved starts nothing and is said out loud")
    func unresolvableSessionIsLoud() {
        // The other side of D22's silence: here the key DID mean something and produced nothing,
        // so §7 asks for a visible reason. The refusal now comes back from the daemon, which is
        // where the tree is read -- and its wording is the daemon's, because it is the half that
        // knows whether no session was active, two were, or the pane could not be named.
        let rig = Rig()
        rig.daemon.queue(Response(kind: .rejected, state: .idle,
                                  message: "agterm's tree names no active session"))
        rig.hold(for: 2)
        #expect(rig.daemon.verbs == [.start])
        #expect(rig.notifier.messages == ["agterm's tree names no active session"])
    }

    @Test("a start the daemon refused makes the release silent")
    func refusedStartMakesTheReleaseSilent() {
        // Without `abandon`, the release would send a bare stop or abort into a daemon that is
        // busy with somebody else's attempt.
        let rig = Rig()
        rig.daemon.queue(Response(kind: .rejected, state: .recording,
                                  message: "already recording"))
        rig.hold(for: 2)
        #expect(rig.daemon.verbs == [.start])
        #expect(rig.notifier.messages == ["already recording"])
    }

    @Test("a start that was accepted without an attempt id ends nothing")
    func acceptedWithoutAnIDEndsNothing() {
        let rig = Rig()
        rig.daemon.queue(Response(kind: .accepted, state: .warming, attempt: nil))
        rig.hold(for: 2)
        #expect(rig.daemon.verbs == [.start])
    }

    @Test("a dictation held on right Command is the same dictation held on right Control")
    func theSecondKeyIsNotASecondPath() {
        // F6a: the built-in keyboard has no right Control key, so this is the ONLY gesture
        // available on the laptop. It has to produce the identical pair of verbs, in `clean`, with
        // no notification -- not "something that also works".
        let rig = Rig()
        rig.hold(.rightCommand, for: 2)
        #expect(rig.daemon.verbs == [.start, .stop])
        #expect(rig.daemon.requests[0].focus == true)
        #expect(rig.daemon.requests[1].mode == .clean)
        #expect(rig.notifier.signals.isEmpty)
    }

    @Test("an ordinary Command combination is under the floor and delivers nothing")
    func theSecondKeyHasTheSameFloor() {
        // D21 for the key that was added second, and the reason it could be added at all: `⌘V`
        // measured 126 ms on this keyboard (F6a) against a 300 ms floor, so the paste the user
        // typed reaches the daemon as an abort and no text is produced.
        let rig = Rig()
        rig.hold(.rightCommand, for: 0.126)
        #expect(rig.daemon.verbs == [.start, .abort])
    }

    @Test("the second key pressed during a hold neither starts nor ends a dictation")
    func theSecondKeyDoesNotInterruptTheFirst() {
        // The whole reason `HoldWatch` exists, asserted where it would do its damage: one gesture
        // in, one start and one stop out, however many armed keys were touched in between.
        let rig = Rig()
        rig.modifiers.press(.rightControl)
        rig.step()
        rig.clock.advance(by: 1)
        // The other armed key is pressed and released in the middle of the dictation.
        rig.modifiers.press(.rightCommand)
        rig.step()
        rig.modifiers.release(.rightCommand)
        rig.step()
        #expect(rig.daemon.verbs == [.start])
        rig.clock.advance(by: 1)
        rig.modifiers.release(.rightControl)
        rig.step()
        #expect(rig.daemon.verbs == [.start, .stop])
        #expect(rig.daemon.requests[1].mode == .clean)
        #expect(rig.notifier.signals.isEmpty)
    }

    @Test("a left-Control combination never reaches the daemon")
    func leftControlIsNotTheHoldKey() {
        let rig = Rig()
        rig.modifiers.set(0x0000_0001 | 0x0004_0000)
        if let edge = rig.trigger.sample() { rig.trigger.perform(edge) }
        rig.clock.advance(by: 2)
        rig.modifiers.set(0)
        if let edge = rig.trigger.sample() { rig.trigger.perform(edge) }
        #expect(rig.daemon.requests.isEmpty)
        #expect(rig.notifier.signals.isEmpty)
    }

    @Test("a daemon that cannot be reached is reported rather than swallowed")
    func unreachableDaemonIsReported() {
        struct Unreachable: Error, CustomStringConvertible {
            var description: String { "no socket" }
        }
        let rig = Rig()
        rig.daemon.setError(Unreachable())
        rig.hold(for: 2)
        #expect(rig.notifier.messages.count == 1)
    }
}
