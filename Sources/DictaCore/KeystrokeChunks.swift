// D32's bound, as a pure planner. **final** is not bounded upstream -- the dictionary can expand
// recognised text and the filter can return anything -- and delivery into a focused field runs
// inline under the daemon's handler lock, one key-down and key-up per chunk. So the text is planned
// into chunks BEFORE the final validation and before any event is posted, and a plan over either
// hard limit is refused whole: a delivery that says nothing was inserted, with **final** in the
// record, rather than a delivery that stops somewhere in the middle.
//
// Two properties the rest of the path leans on:
//   • **A grapheme is never split.** A chunk boundary inside a surrogate pair, a ZWJ sequence or a
//     base and its combining mark would post half a character. So the soft target can be exceeded
//     by one grapheme, and one grapheme over the per-event limit is refused rather than cut.
//   • **The planner's own work is bounded.** It is handed text of any length, so it never takes a
//     full `utf16.count` of it: the pre-count stops one unit past the limit, and packing stops at
//     the first limit exceeded rather than building a plan it will refuse.

/// The planner's answer. A refusal carries no count, because the planner stops at the bound rather
/// than counting the rest.
public enum DeliveryPlan: Equatable, Sendable {
    /// Whole graphemes, in order; joined, they are the input. Empty for empty text.
    case chunks([String])
    /// More chunks than one delivery may post, judged on the packed plan.
    case tooManyChunks
    /// One grapheme longer than a single event may carry.
    case graphemeTooLong
}

public struct KeystrokeChunks: Equatable, Sendable {
    /// The soft packing target per chunk, in UTF-16 units. At least 1.
    public let targetUTF16: Int
    /// The hard limit on one event's payload, in UTF-16 units. At least `targetUTF16`.
    public let maxEventUTF16: Int
    /// The hard limit on the number of chunks, and so on the number of events, in one delivery.
    public let maxChunks: Int
    /// `maxChunks × maxEventUTF16`: no text longer than this can fit any plan.
    public let limitUTF16: Int

    /// `nil` for constants that could plan nothing, or whose limit overflows. A `targetUTF16` under
    /// 1 is clamped to 1 rather than refused, because it still describes a working planner.
    public init?(targetUTF16: Int, maxEventUTF16: Int, maxChunks: Int) {
        let target = max(targetUTF16, 1)
        guard maxChunks >= 1, maxEventUTF16 >= target else { return nil }
        let (limit, overflow) = maxChunks.multipliedReportingOverflow(by: maxEventUTF16)
        guard !overflow else { return nil }
        self.targetUTF16 = target
        self.maxEventUTF16 = maxEventUTF16
        self.maxChunks = maxChunks
        self.limitUTF16 = limit
    }

    /// F11's values (SPEC.md §4):
    ///   • a target of 20 units, delivered with no gap and no loss in all six applications
    ///     measured;
    ///   • an event limit of 200 units, accepted whole by VS Code and confirmed elsewhere only by a
    ///     human item (H25-H27);
    ///   • 4 000 chunks, which F11 did not fix: enough that the largest recognised text the wire
    ///     carries (`RecognisedText.maxBytes`, all ASCII) plans with room to spare, so the limit
    ///     only ever refuses what the dictionary or the filter grew.
    public static let standard = KeystrokeChunks(targetUTF16: 20, maxEventUTF16: 200,
                                                 maxChunks: 4_000)!

    public func plan(_ text: String) -> DeliveryPlan {
        guard Self.boundedUTF16Count(text.utf16, limit: limitUTF16) <= limitUTF16 else {
            return .tooManyChunks
        }
        var chunks: [String] = []
        var current = ""
        var currentUTF16 = 0
        for character in text {
            let units = character.utf16.count
            guard units <= maxEventUTF16 else { return .graphemeTooLong }
            if currentUTF16 > 0, currentUTF16 + units > targetUTF16 {
                guard chunks.count < maxChunks else { return .tooManyChunks }
                chunks.append(current)
                current = ""
                currentUTF16 = 0
            }
            current.append(character)
            currentUTF16 += units
        }
        if currentUTF16 > 0 {
            guard chunks.count < maxChunks else { return .tooManyChunks }
            chunks.append(current)
        }
        return .chunks(chunks)
    }

    /// The number of units in `units`, counted up to at most `limit + 1`: it draws exactly
    /// `min(count, limit + 1)` elements and never the rest. Public for its test, which is the
    /// only way to observe that an oversized input is not scanned whole.
    public static func boundedUTF16Count<Units: Sequence>(_ units: Units, limit: Int) -> Int
    where Units.Element == UInt16 {
        var count = 0
        var iterator = units.makeIterator()
        while count <= limit, iterator.next() != nil {
            count += 1
        }
        return count
    }
}
