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
/// Only the two keys F6 actually measured on this user's external keyboard are offered. A third
/// case here would be a guess wearing the same clothes as a measurement, and the right Option key
/// this keyboard does not have is exactly how that guess would have gone wrong.
public enum HoldKey: String, Codable, Sendable, CaseIterable {
    case rightControl
    case rightCommand

    /// The device-dependent bit, from `IOLLEvent.h`'s `NX_DEVICER*KEYMASK`, confirmed against this
    /// keyboard in F6: right Control `0x2000` against left Control `0x1`, right Command `0x10`
    /// against left Command `0x8`.
    public var bit: UInt64 {
        switch self {
        case .rightControl: 0x0000_2000
        case .rightCommand: 0x0000_0010
        }
    }

    /// What the user would call it, for a notification that has to name the key.
    public var describedName: String {
        switch self {
        case .rightControl: "the right Control key"
        case .rightCommand: "the right Command key"
        }
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

    /// D21's floor. Measured against it: an ordinary press of a modifier lasts 90-150 ms (F6), so
    /// 300 ms is twice the longest press observed and a small fraction of any real dictation.
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
        // safe at all: the two populations it separates are 90-150 ms and several seconds (F6), so
        // nothing real lives within a rounding error of the boundary. A floor that needed exact
        // arithmetic would be a floor in the wrong place.
        return held < floor ? .discard(attempt: id) : .deliver(attempt: id)
    }
}
