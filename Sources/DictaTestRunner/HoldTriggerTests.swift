import AppKit
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

    @Test("a release and another key's press in one sample report the release, then the press")
    func aReleaseIsNeverOverwrittenByTheNextPress() {
        // One sample reports one edge. Reporting the new `down` would lose the owner's `up`, and
        // the attempt that release should have ended would go on recording until D15's cap.
        for owner in Self.watched {
            let other = Self.watched.first { $0 != owner }!
            var watch = HoldWatch(keys: Self.watched)
            #expect(watch.sample(0) == nil)
            #expect(watch.sample(owner.bit) == HoldEdge(key: owner, edge: .down))
            let generation = watch.generation
            #expect(watch.sample(other.bit) == HoldEdge(key: owner, edge: .up))
            #expect(watch.sample(other.bit) == HoldEdge(key: other, edge: .down))
            #expect(watch.generation == generation + 1)
            #expect(watch.sample(0) == HoldEdge(key: other, edge: .up))
        }
        // A press let go again before the next sample claims nothing.
        var watch = HoldWatch(keys: Self.watched)
        #expect(watch.sample(0) == nil)
        #expect(watch.sample(Self.rightControl) == HoldEdge(key: .rightControl, edge: .down))
        #expect(watch.sample(Self.rightCommand) == HoldEdge(key: .rightControl, edge: .up))
        #expect(watch.sample(0) == nil)
        #expect(watch.owner == nil)
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

    // MARK: the threshold edge (D31)

    static let start = Date(timeIntervalSince1970: 1_766_000_000)

    static func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test("an armed hold emits its threshold once, from sampled time")
    func theThresholdIsEmittedOnce() {
        var watch = HoldWatch(keys: Self.watched, floor: 0.3)
        #expect(watch.sample(0, at: Self.at(0)) == nil)
        #expect(watch.sample(Self.rightControl, at: Self.at(0.01))
            == HoldEdge(key: .rightControl, edge: .down))
        watch.armThreshold()
        // Under the floor by the SAMPLE's time, whenever anything else runs.
        #expect(watch.sample(Self.rightControl, at: Self.at(0.2)) == nil)
        #expect(watch.sample(Self.rightControl, at: Self.at(0.32))
            == HoldEdge(key: .rightControl, edge: .threshold))
        // Once: a hold of minutes is one threshold, not one per sample.
        #expect(watch.sample(Self.rightControl, at: Self.at(0.5)) == nil)
        #expect(watch.sample(Self.rightControl, at: Self.at(90)) == nil)
        #expect(watch.sample(0, at: Self.at(91)) == HoldEdge(key: .rightControl, edge: .up))
    }

    @Test("an unarmed hold never emits a threshold, however long it is held")
    func noThresholdUnlessArmed() {
        // The agterm route never arms, and this is what keeps its edges exactly what they were.
        var watch = HoldWatch(keys: Self.watched, floor: 0.3)
        #expect(watch.sample(0, at: Self.at(0)) == nil)
        #expect(watch.sample(Self.rightControl, at: Self.at(0)) != nil)
        for tick in stride(from: 0.016, through: 5, by: 0.016) {
            #expect(watch.sample(Self.rightControl, at: Self.at(tick)) == nil)
        }
    }

    @Test("no threshold between a sampled down and up shorter than the floor")
    func noThresholdUnderTheFloor() {
        // A right-hand shortcut (F11: 138-162 ms) released before the floor: only the pair.
        var watch = HoldWatch(keys: Self.watched, floor: 0.3)
        #expect(watch.sample(0, at: Self.at(0)) == nil)
        #expect(watch.sample(Self.rightCommand, at: Self.at(0)) != nil)
        watch.armThreshold()
        #expect(watch.sample(Self.rightCommand, at: Self.at(0.15)) == nil)
        #expect(watch.sample(0, at: Self.at(0.16)) == HoldEdge(key: .rightCommand, edge: .up))
        // And a release first seen by a sample past the floor is still the release: the key is
        // no longer down, so there is nothing for a threshold to say.
        #expect(watch.sample(Self.rightCommand, at: Self.at(1)) != nil)
        watch.armThreshold()
        #expect(watch.sample(0, at: Self.at(2)) == HoldEdge(key: .rightCommand, edge: .up))
        #expect(watch.sample(0, at: Self.at(3)) == nil)
    }

    @Test("the threshold carries the owner's generation, and each owning press is a new one")
    func generationsNameTheHold() {
        var watch = HoldWatch(keys: Self.watched, floor: 0.3)
        #expect(watch.sample(0, at: Self.at(0)) == nil)
        #expect(watch.sample(Self.rightControl, at: Self.at(0))?.edge == .down)
        let first = watch.generation
        watch.armThreshold()
        #expect(watch.sample(Self.rightControl, at: Self.at(0.4))?.edge == .threshold)
        #expect(watch.generation == first)
        #expect(watch.sample(0, at: Self.at(1))?.edge == .up)
        #expect(watch.generation == first)
        #expect(watch.sample(Self.rightCommand, at: Self.at(2))?.edge == .down)
        #expect(watch.generation == first + 1)
    }

    @Test("the second armed key neither produces a threshold for the owner's hold nor ends it")
    func theSecondKeyLeavesTheThresholdAlone() {
        var watch = HoldWatch(keys: Self.watched, floor: 0.3)
        #expect(watch.sample(0, at: Self.at(0)) == nil)
        #expect(watch.sample(Self.rightControl, at: Self.at(0))?.edge == .down)
        let owner = watch.generation
        watch.armThreshold()
        // The other key goes down and up under the floor: no edge, no new generation.
        #expect(watch.sample(Self.rightControl | Self.rightCommand, at: Self.at(0.1)) == nil)
        #expect(watch.sample(Self.rightControl, at: Self.at(0.2)) == nil)
        #expect(watch.generation == owner)
        // The owner's threshold is still the owner's, timed from the owner's press.
        #expect(watch.sample(Self.rightControl | Self.rightCommand, at: Self.at(0.31))
            == HoldEdge(key: .rightControl, edge: .threshold))
        // The owner lets go while the other is held: the owner's up, and no threshold for the other
        // key however long it stays down.
        #expect(watch.sample(Self.rightCommand, at: Self.at(0.5))
            == HoldEdge(key: .rightControl, edge: .up))
        watch.armThreshold()
        #expect(watch.sample(Self.rightCommand, at: Self.at(5)) == nil)
    }

    @Test("the agterm route's edges are the same pair, timed or not")
    func theAgtermEdgesAreUnchanged() {
        // Byte for byte: the same samples through the untimed and the timed call give the same
        // edges when nothing arms a threshold.
        let samples: [UInt64] = [0, Self.rightControl, Self.rightControl,
                                 Self.rightControl | Self.rightCommand, Self.rightCommand, 0,
                                 Self.rightCommand, 0]
        var untimed = HoldWatch(keys: Self.watched)
        var timed = HoldWatch(keys: Self.watched, floor: 0.3)
        for (index, flags) in samples.enumerated() {
            #expect(untimed.sample(flags) == timed.sample(flags, at: Self.at(Double(index))))
        }
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

    @Test("with focused fields off, the hold key does nothing at all in another application")
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

    @Test("the press captures bundle id, pid and name as one value from one activation")
    func thePressCapturesOneActivation() {
        // D31's field target is built from these three. Read one at a time, an activation landing
        // between the reads would name an application that was never frontmost: VS Code's bundle
        // id with Safari's pid. So the source hands back one value and the press reads it once.
        let rig = Rig()
        let code = FrontmostFacts(bundleID: "com.microsoft.VSCode", pid: 4_242, name: "Code")
        let safari = FrontmostFacts(bundleID: "com.apple.Safari", pid: 717, name: "Safari")
        rig.frontmost.script([code, safari])
        rig.modifiers.press(.rightControl)
        let down = rig.trigger.sample()
        #expect(down?.edge == .down)
        #expect(down?.frontmost == code)
        #expect(rig.frontmost.reads == 1)
        // The release reads nothing: what was frontmost is a fact about the press (D22).
        rig.modifiers.release(.rightControl)
        let up = rig.trigger.sample()
        #expect(up?.edge == .up)
        #expect(up?.frontmost == nil)
        #expect(rig.frontmost.reads == 1)
        // The next press is the next activation, whole.
        rig.modifiers.press(.rightCommand)
        #expect(rig.trigger.sample()?.frontmost == safari)
        #expect(rig.frontmost.reads == 2)
    }

    @Test("the press in front of agterm captures agterm's facts and still reads frontmost once")
    func agtermPressCapturesItsFacts() {
        let rig = Rig()
        let agterm = FrontmostFacts(bundleID: HoldTrigger.agtermBundleIdentifier, pid: 99,
                                    name: "agterm")
        rig.frontmost.activate(agterm)
        rig.modifiers.press(.rightControl)
        let down = rig.trigger.sample()
        #expect(down?.frontmost == agterm)
        #expect(down?.route == .agterm)
        #expect(rig.frontmost.reads == 1)
    }

    @Test("the system frontmost source keeps all three facts from the activation notification")
    func systemFrontmostKeepsTheNotification() throws {
        // F8a: the value comes from the notification's own `NSRunningApplication`, never from a
        // second read of the workspace's cache. Posted by hand, naming a running application that
        // is neither this process nor the cached frontmost one, so a value read back out of the
        // cache could not pass by accident. (`NSRunningApplication.current` is no use here: a
        // process with no bundle reports pid -1.)
        let source = SystemFrontmost()
        let me = ProcessInfo.processInfo.processIdentifier
        let cached = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let other = try #require(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier > 0 && $0.processIdentifier != me
                && $0.processIdentifier != cached
                && $0.bundleIdentifier != nil && $0.localizedName != nil
        })
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: NSWorkspace.shared,
            userInfo: [NSWorkspace.applicationUserInfoKey: other]
        )
        let facts = source.current
        #expect(facts == FrontmostFacts(bundleID: other.bundleIdentifier,
                                        pid: other.processIdentifier, name: other.localizedName))
        #expect(SystemFrontmost.facts(of: other) == facts)
        #expect(SystemFrontmost.facts(of: nil) == nil)
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

@Suite("hold trigger, focused fields")
struct FocusedFieldTriggerTests {
    static let code = FrontmostFacts(bundleID: "com.microsoft.VSCode", pid: 4_242, name: "Code")
    static let safari = FrontmostFacts(bundleID: "com.apple.Safari", pid: 717, name: "Safari")
    static let agterm = FrontmostFacts(bundleID: HoldTrigger.agtermBundleIdentifier, pid: 99,
                                       name: "agterm")
    static let target = FieldTarget(bundleID: "com.microsoft.VSCode", appName: "Code", pid: 4_242)
    static let settle: TimeInterval = 0.25

    /// A trigger with the focused-field path wired to fakes, and VS Code frontmost.
    struct Rig {
        let trigger: HoldTrigger
        let modifiers = FakeModifiers()
        let frontmost = FakeFrontmost()
        let notifier = FakeNotifier()
        let feedback: FakeNotifier
        let access: FakeFocusedFieldAccess
        let daemon = FakeDaemonDoor()
        let clock = FakeClock()
        let pacer: FakePacer

        /// `send` replaces the fake door -- a real `Daemon`, when what is asserted is what the two
        /// halves say together -- and `feedback` is then that daemon's own. `wired: false` hands
        /// the trigger no `FocusedFields` at all.
        init(enabled: Bool = true, trusted: Bool = true, wired: Bool = true,
             feedback: FakeNotifier = FakeNotifier(),
             send: HoldTrigger.Sender? = nil) {
            access = FakeFocusedFieldAccess(trusted: trusted)
            pacer = FakePacer(clock: clock)
            self.feedback = feedback
            frontmost.activate(FocusedFieldTriggerTests.code)
            let daemon = daemon
            trigger = HoldTrigger(
                configuration: HoldTrigger.Configuration(
                    floor: 0.3, focusedFields: enabled,
                    settleWindow: FocusedFieldTriggerTests.settle),
                modifiers: modifiers,
                frontmost: frontmost,
                notifier: notifier,
                clock: clock,
                fields: wired
                    ? HoldTrigger.FocusedFields(access: access, feedback: feedback, pacer: pacer)
                    : nil,
                send: send ?? { try daemon.send($0) }
            )
            _ = trigger.sample()
        }

        /// Sample the keyboard as it now is, and return the edge without performing it: the queue.
        func sample() -> HoldTrigger.Pending? { trigger.sample() }

        func press(_ key: HoldKey = .rightControl) -> HoldTrigger.Pending? {
            modifiers.press(key)
            return trigger.sample()
        }

        func release(_ key: HoldKey = .rightControl) -> HoldTrigger.Pending? {
            modifiers.release(key)
            return trigger.sample()
        }

        /// Time passes on the poll loop's clock, and the loop samples once.
        func wait(_ seconds: TimeInterval) -> HoldTrigger.Pending? {
            clock.advance(by: seconds)
            return trigger.sample()
        }

        func perform(_ edges: [HoldTrigger.Pending?]) {
            for edge in edges.compactMap({ $0 }) { trigger.perform(edge) }
        }

        /// A whole hold, performed as it is sampled.
        func hold(_ key: HoldKey = .rightControl, for seconds: TimeInterval) {
            perform([press(key)])
            var elapsed = 0.0
            while elapsed + 0.016 < seconds {
                clock.advance(by: 0.016)
                elapsed += 0.016
                perform([trigger.sample()])
            }
            clock.advance(by: seconds - elapsed)
            perform([release(key)])
        }

        var silent: Bool { notifier.signals.isEmpty && feedback.signals.isEmpty }
    }

    @Test("a hold elsewhere starts at the threshold, into its field, and stops on release")
    func theFieldGesture() throws {
        let rig = Rig()
        let down = try #require(rig.press())
        #expect(down.route == .focusedFieldAfterFloor(Self.target))
        rig.perform([down])
        // Nothing at the press: no request, and no accessibility call.
        #expect(rig.daemon.requests.isEmpty)
        #expect(rig.access.callLog.isEmpty)
        #expect(rig.wait(0.2) == nil)
        let threshold = try #require(rig.wait(0.12))
        #expect(threshold.edge == .threshold)
        #expect(threshold.generation == down.generation)
        rig.perform([threshold])
        #expect(rig.daemon.verbs == [.start])
        let start = rig.daemon.requests[0]
        #expect(start.field == Self.target)
        #expect(start.focus == nil)
        #expect(start.sessionID == nil)
        #expect(start.conflict == nil)
        #expect(rig.access.callLog == [.isTrusted])
        rig.clock.advance(by: 2)
        rig.perform([rig.release()])
        #expect(rig.daemon.verbs == [.start, .stop])
        #expect(rig.daemon.requests[1].mode == .clean)
        #expect(rig.daemon.requests[1].attempt == 1)
        #expect(rig.pacer.pauses == [Self.settle])
        #expect(rig.silent)
    }

    @Test("a short hold queued behind a blocked sender costs nothing on the focused-field path")
    func aShortQueuedHoldCostsNothing() {
        // The sender is busy with a previous request, so the edges pile up; what it finds when it
        // unblocks is a `down` and an `up` 150 ms apart by the poll loop's clock -- a right-hand
        // shortcut (F11: 138-162 ms) -- however late it reads them.
        let rig = Rig()
        let queued = [rig.press(.rightCommand), rig.wait(0.15), rig.release(.rightCommand)]
        #expect(queued.compactMap { $0?.edge } == [.down, .up])
        rig.clock.advance(by: 5)
        rig.perform(queued)
        #expect(rig.access.callLog.isEmpty)
        #expect(rig.daemon.requests.isEmpty)
        #expect(rig.silent)
    }

    @Test("a long hold released while the sender was blocked starts nothing")
    func aLongQueuedHoldStartsNothing() {
        let rig = Rig()
        let queued = [rig.press(), rig.wait(0.35), rig.wait(1), rig.release()]
        #expect(queued.compactMap { $0?.edge } == [.down, .threshold, .up])
        rig.perform(queued)
        #expect(rig.access.callLog.isEmpty)
        #expect(rig.daemon.requests.isEmpty)
        #expect(rig.silent)
    }

    @Test("a stale threshold is dropped, and only the held generation's threshold starts")
    func aStaleThresholdIsDropped() throws {
        let rig = Rig()
        var queued = [rig.press(), rig.wait(0.35), rig.release()]
        let next = try #require(rig.press(.rightCommand))
        queued.append(next)
        #expect(queued.compactMap { $0?.edge } == [.down, .threshold, .up, .down])
        #expect(queued[1]?.generation != next.generation)
        rig.perform(queued)
        #expect(rig.access.callLog.isEmpty)
        #expect(rig.daemon.requests.isEmpty)
        let threshold = try #require(rig.wait(0.35))
        #expect(threshold.edge == .threshold)
        #expect(threshold.generation == next.generation)
        rig.perform([threshold])
        #expect(rig.daemon.verbs == [.start])
        #expect(rig.silent)
    }

    @Test("a release the poller records before the sender's liveness check discards the threshold")
    func releaseBeforeTheLivenessCheck() {
        let rig = Rig()
        rig.perform([rig.press()])
        let threshold = rig.wait(0.35)
        // The key comes up and the poll loop sees it before the sender reaches the threshold.
        let up = rig.release()
        rig.perform([threshold, up])
        #expect(rig.access.callLog.isEmpty)
        #expect(rig.daemon.requests.isEmpty)
        #expect(rig.silent)
    }

    @Test("a release landing after the liveness check stops the start rather than aborting it")
    func releaseAfterTheLivenessCheck() {
        let rig = Rig()
        rig.perform([rig.press()])
        let threshold = rig.wait(0.35)
        // The start is on the wire when the key comes up: the poll loop queues the `up` while the
        // sender is still waiting for the answer.
        let released = Box<HoldTrigger.Pending>()
        let modifiers = rig.modifiers
        let trigger = rig.trigger
        rig.daemon.duringSend { request in
            guard request.cmd == .start else { return }
            modifiers.release(.rightControl)
            released.value = trigger.sample()
        }
        rig.perform([threshold])
        rig.daemon.duringSend(nil)
        #expect(released.value?.edge == .up)
        // Released a few milliseconds after the threshold: D21's floor was already passed, and is
        // not applied again, so this is a stop.
        rig.perform([released.value])
        #expect(rig.daemon.verbs == [.start, .stop])
        #expect(rig.silent)
    }

    @Test("a field attempt whose application switched during the hold is aborted silently")
    func aSwitchDuringTheHoldAborts() {
        let rig = Rig()
        rig.perform([rig.press(), rig.wait(0.35)])
        rig.clock.advance(by: 1)
        rig.frontmost.activate(Self.safari)
        rig.perform([rig.release()])
        #expect(rig.daemon.verbs == [.start, .abort])
        #expect(rig.daemon.requests[1].attempt == 1)
        // Silent is asked for, since the daemon is the one that would otherwise play `Basso`.
        #expect(rig.daemon.requests[1].silent == true)
        // Already switched at the release: nothing to wait for.
        #expect(rig.pacer.pauses.isEmpty)
        #expect(rig.silent)
    }

    @Test("a field attempt whose application switched within the settle window is aborted silently")
    func aSwitchInsideTheSettleWindowAborts() {
        // `⌘Tab` activates the chosen application when `⌘` comes up, just after the release.
        let rig = Rig()
        rig.perform([rig.press(.rightCommand), rig.wait(0.6)])
        rig.frontmost.script([Self.code, Self.safari])
        rig.daemon.queue(Response(kind: .rejected, state: .idle, message: "nothing to abort"))
        rig.perform([rig.release(.rightCommand)])
        #expect(rig.daemon.verbs == [.start, .abort])
        #expect(rig.pacer.pauses == [Self.settle])
        // Even a refused abort is not said: the gesture meant nothing.
        #expect(rig.silent)
    }

    @Test("a field attempt whose application never changed is stopped after the settle window")
    func noSwitchStops() {
        let rig = Rig()
        rig.perform([rig.press(), rig.wait(0.35)])
        let up = rig.release()
        // The sender reaches the release 100 ms after it was sampled.
        rig.clock.advance(by: 0.1)
        rig.perform([up])
        #expect(rig.daemon.verbs == [.start, .stop])
        #expect(rig.pacer.pauses.count == 1)
        #expect(abs((rig.pacer.pauses.first ?? 0) - (Self.settle - 0.1)) < 0.000_1)
        // A sender already behind by more than the window waits no longer at all.
        let late = Rig()
        late.perform([late.press(), late.wait(0.35)])
        let lateUp = late.release()
        late.clock.advance(by: 3)
        late.perform([lateUp])
        #expect(late.daemon.verbs == [.start, .stop])
        #expect(late.pacer.pauses.isEmpty)
    }

    @Test("with the grant missing, a threshold refuses once, audibly, and sends nothing")
    func noGrantRefusesAtTheThreshold() {
        let rig = Rig(trusted: false)
        rig.hold(for: 3)
        #expect(rig.daemon.requests.isEmpty)
        #expect(rig.access.callLog == [.isTrusted])
        #expect(rig.feedback.announcements == [.blocked])
        #expect(rig.feedback.messages.count == 1)
        #expect(rig.feedback.messages.first?.contains("Accessibility") == true)
        #expect(rig.notifier.signals.isEmpty)
    }

    @Test("a threshold after the user switched away sends nothing and says nothing")
    func switchedAwayBeforeTheThreshold() {
        let rig = Rig()
        rig.perform([rig.press()])
        rig.frontmost.activate(Self.safari)
        rig.perform([rig.wait(0.35)])
        rig.clock.advance(by: 1)
        rig.perform([rig.release()])
        #expect(rig.daemon.requests.isEmpty)
        #expect(rig.silent)
    }

    @Test("a refused field start is left to the daemon to say, and the release is silent")
    func aRefusedFieldStart() {
        // The daemon said it when it refused; the trigger repeating it was every refusal twice.
        let rig = Rig()
        rig.daemon.queue(Response(kind: .rejected, state: .idle,
                                  message: "Secure Input is on, so dicta will not type"))
        rig.hold(for: 2)
        #expect(rig.daemon.verbs == [.start])
        #expect(rig.silent)
    }

    @Test("a refused field start is said exactly once when the trigger meets the real daemon")
    func aRefusalThroughTheRealDaemonIsSaidOnce() throws {
        let harness = DaemonTests.Harness(focusedFields: true)
        harness.access.setSecureInput(true)
        let daemon = harness.daemon
        let rig = Rig(feedback: harness.feedback, send: { daemon.handle(.request($0)) })

        rig.hold(for: 2)

        #expect(harness.feedback.announcements == [.blocked])
        #expect(harness.feedback.messages.count == 1)
        #expect(harness.feedback.messages.first?.contains("Secure Input") == true)
        #expect(harness.capture.callLog.isEmpty)
        #expect(rig.notifier.signals.isEmpty)
    }

    @Test("a hold that switched the application ends the real daemon's attempt with no sound")
    func aSwitchThroughTheRealDaemonIsSilent() throws {
        // What H32 (b) scores: a right-hand `⌘Tab` held past the floor opens the microphone, and
        // then must cost no `Basso` and no "aborted" notification -- only the record's line.
        let harness = DaemonTests.Harness(focusedFields: true)
        let daemon = harness.daemon
        let rig = Rig(feedback: harness.feedback, send: { daemon.handle(.request($0)) })

        rig.perform([rig.press(.rightCommand), rig.wait(0.35)])
        let id = try #require(harness.daemon.currentAttempt?.id)
        harness.capture.reportReady(id)
        rig.frontmost.activate(Self.safari)
        rig.clock.advance(by: 1)
        rig.perform([rig.release(.rightCommand)])

        #expect(harness.daemon.state == .idle)
        #expect(harness.feedback.announcements == [.listening])
        #expect(harness.feedback.messages.isEmpty)
        #expect(harness.fieldInjector.delivered.isEmpty)
        #expect(harness.history.appended.last?.outcome == .aborted)
    }

    @Test("a start that cannot reach the daemon is said once, and its release is silent")
    func aSendErrorAtTheThreshold() {
        struct Unreachable: Error, CustomStringConvertible {
            var description: String { "no socket" }
        }
        let rig = Rig()
        rig.daemon.setError(Unreachable())
        rig.hold(for: 2)
        #expect(rig.daemon.verbs == [.start])
        #expect(rig.feedback.announcements == [.blocked])
        #expect(rig.feedback.messages.count == 1)
        #expect(rig.notifier.signals.isEmpty)
    }

    @Test("a refused stop of a field attempt is said through system feedback")
    func aRefusedFieldStop() {
        let rig = Rig()
        rig.perform([rig.press(), rig.wait(0.35)])
        rig.daemon.queue(Response(kind: .rejected, state: .idle, message: "nothing to stop"))
        rig.clock.advance(by: 1)
        rig.perform([rig.release()])
        #expect(rig.daemon.verbs == [.start, .stop])
        #expect(rig.feedback.messages == ["nothing to stop"])
        #expect(rig.notifier.signals.isEmpty)
    }

    @Test("the option on with no focused-field wiring routes nothing into the field path")
    func theOptionWithoutWiringIsIgnored() throws {
        let rig = Rig(wired: false)
        let down = try #require(rig.press())
        #expect(down.route == .ignore)
        rig.perform([down, rig.wait(2), rig.release()])
        #expect(rig.daemon.requests.isEmpty)
        #expect(rig.access.callLog.isEmpty)
        #expect(rig.silent)
    }

    @Test("agterm frontmost with focused fields on still starts on key-down")
    func agtermKeepsItsPath() {
        let rig = Rig()
        rig.frontmost.activate(Self.agterm)
        rig.perform([rig.press()])
        #expect(rig.daemon.verbs == [.start])
        #expect(rig.daemon.requests[0].focus == true)
        #expect(rig.daemon.requests[0].field == nil)
        rig.clock.advance(by: 0.12)
        rig.perform([rig.release()])
        // D21 on the agterm path is unchanged: under the floor it is an abort.
        #expect(rig.daemon.verbs == [.start, .abort])
        #expect(rig.access.callLog.isEmpty)
        #expect(rig.pacer.pauses.isEmpty)
    }

    @Test("with focused fields off, the accessibility fake records zero calls in every scenario")
    func optionOffMakesNoAccessibilityCall() {
        let rig = Rig(enabled: false)
        // Another application: long, short, and both keys.
        rig.hold(for: 3)
        rig.hold(.rightCommand, for: 0.15)
        rig.perform([rig.press(), rig.wait(0.5), rig.press(.rightCommand), rig.wait(1),
                     rig.release(.rightCommand), rig.release()])
        #expect(rig.daemon.requests.isEmpty)
        // And agterm, whose path the option never touched.
        rig.frontmost.activate(Self.agterm)
        rig.hold(for: 2)
        rig.hold(.rightCommand, for: 0.1)
        #expect(rig.daemon.verbs == [.start, .stop, .start, .abort])
        #expect(rig.access.callLog.isEmpty)
        #expect(rig.pacer.pauses.isEmpty)
        #expect(rig.silent)
    }
}

/// A value a `@Sendable` hook can hand back to the test that installed it.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
