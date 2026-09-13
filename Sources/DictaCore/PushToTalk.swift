import Foundation

// The pure half of push-to-talk (D5): what a modifier key going down and coming back up MEANS.
//
// Nothing here reads a keyboard, opens a socket or looks at a clock. The caller supplies the
// samples and the time, which is what makes every rule below assertable without pressing anything
// (D19) -- and this is a rule set that would otherwise be testable only by hand, because its whole
// subject is a physical gesture.

/// Which physical modifier the hold trigger watches, as the device-dependent bit a keyboard
/// reports for it.
///
/// The device-dependent bits are the entire reason the key can be a *side*. The ordinary flags say
/// only that some Control is down; `0x2000` says it is the right one. Without that separation the
/// trigger would fire on every `⌃C` and `⌃R` typed with the other hand, which in a terminal is all
/// day long.
///
/// Only keys a probe has actually reported on this user's own hardware are offered. A case here
/// that nobody pressed would be a guess wearing the same clothes as a measurement, which is why
/// this enum grew by exactly one case when a second keyboard was measured and not by three.
///
/// The reason there is more than one at all is F6a: **the built-in keyboard of this laptop has no
/// right Control key.** D5's key exists on the external keyboard and nowhere else, so on the
/// laptop push-to-talk was unreachable — not degraded, absent.
public enum HoldKey: String, Codable, Sendable, CaseIterable {
    case rightControl
    case rightCommand
    case rightOption

    /// The device-dependent bit, from `IOLLEvent.h`'s `NX_DEVICER*KEYMASK`, confirmed against real
    /// keyboards rather than read out of the header: right Control `0x2000` against left Control
    /// `0x1` and right Command `0x10` against left Command `0x8` on the external keyboard (F6),
    /// right Command `0x10` and right Option `0x40` on the built-in one (F6a).
    public var bit: UInt64 {
        switch self {
        case .rightControl: 0x0000_2000
        case .rightCommand: 0x0000_0010
        case .rightOption: 0x0000_0040
        }
    }

    /// What the user would call it, for a notification or a log line that has to name the key.
    public var describedName: String {
        switch self {
        case .rightControl: "the right Control key"
        case .rightCommand: "the right Command key"
        case .rightOption: "the right Option key"
        }
    }

    /// The name `--hold-key` accepts, which is the enum's own raw value spelled in the same case a
    /// user would type it.
    public static func named(_ name: String) -> HoldKey? {
        allCases.first { $0.rawValue.lowercased() == name.lowercased() }
    }

    /// Every name `--hold-key` accepts, for a usage line that cannot drift from the enum.
    public static var everyName: String {
        allCases.map(\.rawValue).joined(separator: "|")
    }
}

/// Turns a stream of modifier-state samples into the two edges that matter.
///
/// A poll loop sees state, not events, so the edges have to be derived — and the first sample
/// is
/// deliberately not one. A daemon that starts while the user happens to be holding the key would
/// otherwise open the microphone for a keypress that began before the daemon existed, aimed at
/// whatever session was active at login. Priming instead of firing costs exactly one press, and
/// only in the case where the key was already down when the loop began.
public struct ModifierWatch: Sendable, Equatable {
    public enum Edge: Sendable, Equatable {
        case down
        case up
        /// The owning key has been held, by sampled time, for the floor (D21, D31). Never produced
        /// by a `ModifierWatch`, which sees state and not time; `HoldWatch` emits it, and only for
        /// a hold the focused-field route armed.
        case threshold
    }

    public let bit: UInt64
    /// `nil` until the first sample. Not a `Bool` defaulting to `false`: "we have not looked yet"
    /// and "we looked and it was up" give different answers for the very first sample.
    private var isDown: Bool?

    public init(key: HoldKey) {
        self.bit = key.bit
    }

    public init(bit: UInt64) {
        self.bit = bit
    }

    /// Whether the watched key is currently believed to be down. `false` before the first sample.
    public var isHeld: Bool { isDown == true }

    /// One sample of the whole modifier word; the edge it produced, if any.
    public mutating func sample(_ flags: UInt64) -> Edge? {
        let down = flags & bit != 0
        defer { isDown = down }
        guard let was = isDown else { return nil }
        if was == down { return nil }
        return down ? .down : .up
    }
}

/// One edge, and which key produced it.
public struct HoldEdge: Sendable, Equatable {
    public var key: HoldKey
    public var edge: ModifierWatch.Edge

    public init(key: HoldKey, edge: ModifierWatch.Edge) {
        self.key = key
        self.edge = edge
    }
}

/// Several watched keys, presented to the gesture as if there were one.
///
/// Two keys arm push-to-talk because one keyboard does not have the other's key (F6a), and the
/// whole difficulty is what happens when both are involved in the same gesture. The rule is
/// **first key wins, and owns the gesture until it is released**: every other key is furniture
/// while it holds.
///
/// The failure that rule exists to prevent is not hypothetical arithmetic. Hold right Control,
/// begin dictating, and idly press right Command in the middle of it -- with two independent
/// watches feeding one `HoldToTalk`, the release of right Command is an `up` like any other, so it
/// would stop and DELIVER the dictation while the key the user is still holding says otherwise.
/// The user then goes on speaking into a microphone that closed, and the words already spoken land
/// in a pane they were not finished aiming.
///
/// Every watch is sampled on every call even when its edge is discarded, and that is the load-
/// bearing half. A watch that is not sampled keeps the state it had, so the press it slept through
/// becomes an edge later -- the second key, pressed during a hold and released long after it, would
/// report a `down` the next time anything looked. Sampling all and choosing one keeps every watch
/// honest about the world; only the reporting is filtered.
///
/// **The threshold edge (D31).** On the focused-field path nothing may be sent until the hold has
/// outlasted the floor, and the sender cannot find that out for itself: it handles edges serially
/// and can be seconds behind, so sleeping there could not see a release already queued behind it,
/// and timing the hold when the edge is finally handled would turn a short, queued shortcut into a
/// long hold. So the poll loop emits a third edge, `.threshold`, from **sampled** time, once, while
/// the owning key is still down -- and only for a hold the caller armed with `armThreshold()`. An
/// unarmed hold, which is every agterm hold, produces exactly the edges it always did.
///
/// **Generations.** Every owning `down` bumps `generation`, and every edge of that hold belongs to
/// it. Queue order is history, not liveness: a threshold handled after its hold ended must be told
/// apart from the next hold's, and the generation is what names which hold an edge was.
public struct HoldWatch: Sendable, Equatable {
    /// In the order given, which is the order a tie is broken in when two keys go down inside one
    /// poll interval. Not a `Set`: "first" has to mean something.
    public let keys: [HoldKey]
    /// D21's floor, which the threshold edge measures against.
    public let floor: TimeInterval
    private var watches: [ModifierWatch]
    /// The index of the key that owns the gesture in flight, if one does.
    private var owning: Int?
    /// The generation of the hold in flight, or of the last one: bumped on every owning `down`,
    /// and never by a key whose edges are being swallowed.
    public private(set) var generation: UInt64 = 0
    /// When the owning `down` was sampled, if `sample(_:at:)` was the one that saw it.
    private var ownedSince: Date?
    /// Whether the hold in flight still has a threshold edge to emit.
    private var thresholdArmed = false
    /// A key that went down in the same sample its owner came up in. That sample can report only
    /// one edge, and it must be the `up`: overwriting it with the new `down` would lose the release
    /// of an attempt that is still recording. The press is claimed on the next sample instead, if
    /// the key is still down by then.
    private var deferredClaim: Int?

    public init(keys: [HoldKey], floor: TimeInterval = HoldToTalk.defaultFloor) {
        self.keys = keys
        self.floor = floor
        self.watches = keys.map { ModifierWatch(key: $0) }
    }

    /// The key that owns the gesture in flight, if any.
    public var owner: HoldKey? {
        guard let owning else { return nil }
        return keys[owning]
    }

    /// Whether any watched key is currently believed to be down. `false` before the first sample.
    public var isHeld: Bool { watches.contains { $0.isHeld } }

    /// One sample of the whole modifier word; the one edge it is allowed to produce.
    public mutating func sample(_ flags: UInt64) -> HoldEdge? {
        let edges = watches.indices.map { watches[$0].sample(flags) }
        if let owning {
            // Only the owner may end the gesture. Anything else that moved is swallowed --
            // including its `down`, which is what stops a second attempt being started over the
            // top of the first.
            guard edges[owning] == .up else { return nil }
            self.owning = nil
            ownedSince = nil
            thresholdArmed = false
            // Unless it went down in this very sample: it is claimed on the next one.
            deferredClaim = edges.firstIndex(of: .down)
            return HoldEdge(key: keys[owning], edge: .up)
        }
        if let deferred = deferredClaim {
            deferredClaim = nil
            if edges[deferred] == nil, watches[deferred].isHeld { return claim(deferred) }
        }
        // No gesture in flight. A `down` claims it; an `up` with no owner belongs to a gesture
        // that never was -- the key was already held when the watch was primed -- and saying so
        // would ask the daemon to end an attempt nobody started.
        guard let index = edges.firstIndex(of: .down) else { return nil }
        return claim(index)
    }

    private mutating func claim(_ index: Int) -> HoldEdge {
        owning = index
        generation &+= 1
        ownedSince = nil
        thresholdArmed = false
        return HoldEdge(key: keys[index], edge: .down)
    }

    /// One sample, timed: the edge `sample(_:)` would report, or else the armed hold's threshold.
    ///
    /// The time is the SAMPLE's, taken by the poll loop, so a hold is measured by when the keyboard
    /// was looked at and never by when a queued edge was handled. A sample that sees the owner come
    /// up reports the `up` and never a threshold, however long the hold: the key is no longer down.
    public mutating func sample(_ flags: UInt64, at now: Date) -> HoldEdge? {
        if let edge = sample(flags) {
            if edge.edge == .down { ownedSince = now }
            return edge
        }
        guard thresholdArmed, let owner, let since = ownedSince,
              now.timeIntervalSince(since) >= floor else { return nil }
        thresholdArmed = false
        return HoldEdge(key: owner, edge: .threshold)
    }

    /// The hold in flight is on the focused-field route: emit its threshold, once. Does nothing
    /// with no hold in flight, so a late call cannot arm the next one.
    public mutating func armThreshold() {
        guard owning != nil else { return }
        thresholdArmed = true
    }
}

/// The gesture itself: press, hold, release, and what each of those is worth.
///
/// The type owns one piece of state a caller would otherwise have to keep by hand and get wrong --
/// **whether the attempt this release belongs to actually started**. `deliver` and `discard` carry
/// a non-optional attempt id for that reason: the listener is structurally incapable of ending an
/// attempt it did not begin, which matters because `abort` carrying no id ends whatever is live,
/// and "whatever is live" during a refused start is somebody else's dictation.
public struct HoldToTalk: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        /// The key went down and the attempt may begin. The caller reports back with `started` or
        /// `abandon`.
        case start
        /// Held past the floor: stop and deliver, in `clean` (D3).
        case deliver(attempt: AttemptID)
        /// Held under the floor (D21): abort. No text, no injection, no sound.
        case discard(attempt: AttemptID)
        /// Nothing to do, and nothing to say about it.
        case ignore
    }

    /// D21's floor. Measured against it: an ordinary press of a modifier lasts 90-150 ms on the
    /// external keyboard (F6) and 86-195 ms on the built-in one (F6a). It is no longer twice the
    /// longest press observed -- F6a's 195 ms took that margin -- but 105 ms clear of the worst
    /// press yet seen, and a small fraction of any real dictation.
    public static let defaultFloor: TimeInterval = 0.3

    public let floor: TimeInterval
    private var pressedAt: Date?
    private var attempt: AttemptID?

    public init(floor: TimeInterval = HoldToTalk.defaultFloor) {
        self.floor = floor
    }

    /// Whether a gesture is in flight and has a live attempt behind it.
    public var isHolding: Bool { pressedAt != nil }

    /// The key went down.
    public mutating func down(at now: Date) -> Decision {
        // A second `down` with no `up` between them cannot come from `ModifierWatch`, which only
        // reports transitions. It can come from a caller that mixed sources, and starting a second
        // attempt over the top of the first is the one thing that must not happen quietly.
        guard pressedAt == nil else { return .ignore }
        pressedAt = now
        attempt = nil
        return .start
    }

    /// The attempt began and this is its id: the release will name it (D23).
    public mutating func started(attempt id: AttemptID) {
        guard pressedAt != nil else { return }
        attempt = id
    }

    /// Nothing began -- agterm was not frontmost (D22), the session could not be resolved, or the
    /// daemon refused. The key is still physically down; its release must say nothing.
    public mutating func abandon() {
        pressedAt = nil
        attempt = nil
    }

    /// The key came back up.
    public mutating func up(at now: Date) -> Decision {
        guard let since = pressedAt, let id = attempt else {
            // Either no gesture is in flight, or one is but it never became an attempt. Both are
            // silent: the second is `abandon`'s whole purpose.
            abandon()
            return .ignore
        }
        let held = now.timeIntervalSince(since)
        abandon()
        // Under the floor discards; at or over it delivers -- with the caveat that "at" is not a
        // case anything can rely on. `Date` arithmetic is binary floating point, so a press timed
        // at exactly 300 ms comes back as 0.29999999999999993 and lands on the discard side. That
        // is not worth defending against, and the reason it is not is the same reason the floor is
        // safe at all: the two populations it separates are 86-195 ms and several seconds (F6,
        // F6a), so
        // nothing real lives within a rounding error of the boundary. A floor that needed exact
        // arithmetic would be a floor in the wrong place.
        return held < floor ? .discard(attempt: id) : .deliver(attempt: id)
    }
}

/// The frontmost application, as one activation reported it (D22, D31).
///
/// One value rather than three reads, and that is the point of the type: a bundle identifier read
/// from one activation and a pid read from the next would name an application that was never
/// frontmost. The poll loop captures this at the press, and the focused-field route builds its
/// `FieldTarget` from it.
public struct FrontmostFacts: Sendable, Equatable {
    /// `nil` for an application that has none, carried as absent rather than invented.
    public var bundleID: String?
    public var pid: Int32
    /// The localized name, `nil` when the application reports none.
    public var name: String?

    public init(bundleID: String?, pid: Int32, name: String?) {
        self.bundleID = bundleID
        self.pid = pid
        self.name = name
    }
}
