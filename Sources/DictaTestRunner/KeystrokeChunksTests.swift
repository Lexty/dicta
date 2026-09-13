import DictaCore
import Foundation
import Testing

/// The planner behind D32's bound: **final** becomes whole-grapheme chunks packed to a soft target,
/// under a hard limit on the chunk count and on every event's payload, and a plan over either limit
/// is refused before a single event is posted.
///
/// Cyrillic and emoji appear as `\u{...}` escapes, as everywhere else in the repository, so that
/// `Scripts/lint.sh`'s Cyrillic grep keeps having nothing legitimate to find.
@Suite("keystroke chunks")
struct KeystrokeChunksTests {
    // MARK: - fixtures

    /// "privet mir" -- ten BMP code points, one UTF-16 unit each.
    static let privetMir = "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} "
        + "\u{043C}\u{0438}\u{0440}"
    /// A family of four joined by U+200D: one `Character`, eleven UTF-16 units.
    static let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
    /// A grinning face: one `Character`, a surrogate pair.
    static let grin = "\u{1F600}"
    /// "e" with a combining acute accent: one `Character`, two UTF-16 units.
    static let accentedE = "e\u{0301}"

    /// "a" followed by `marks` combining acute accents: one `Character` of `marks + 1` units.
    static func stacked(_ marks: Int) -> String {
        "a" + String(repeating: "\u{0301}", count: marks)
    }

    static func planner(target: Int, maxEvent: Int, maxChunks: Int) -> KeystrokeChunks {
        guard let planner = KeystrokeChunks(targetUTF16: target, maxEventUTF16: maxEvent,
                                            maxChunks: maxChunks) else {
            Issue.record("valid constants were rejected")
            return .standard
        }
        return planner
    }

    /// The chunks of an accepted plan, recording an issue when the plan was refused.
    static func chunks(_ plan: DeliveryPlan) -> [String] {
        guard case let .chunks(chunks) = plan else {
            Issue.record("expected chunks, got \(plan)")
            return []
        }
        return chunks
    }

    // MARK: - packing

    @Test("empty text gives no chunks")
    func emptyText() {
        #expect(KeystrokeChunks.standard.plan("") == .chunks([]))
    }

    @Test("ASCII splits at exactly the target")
    func asciiSplitsAtTarget() {
        let text = String(repeating: "a", count: 45)
        let chunks = Self.chunks(Self.planner(target: 20, maxEvent: 200, maxChunks: 10).plan(text))
        #expect(chunks.map(\.utf16.count) == [20, 20, 5])
    }

    @Test("escaped Cyrillic splits on the same unit count")
    func cyrillicSplits() {
        let text = Self.privetMir + Self.privetMir + Self.privetMir
        let chunks = Self.chunks(Self.planner(target: 20, maxEvent: 200, maxChunks: 10).plan(text))
        #expect(chunks == [Self.privetMir + Self.privetMir, Self.privetMir])
    }

    @Test("a surrogate pair at a boundary is never split")
    func surrogatePairAtBoundary() {
        let head = String(repeating: "a", count: 19)
        let chunks = Self.chunks(Self.planner(target: 20, maxEvent: 200, maxChunks: 10)
            .plan(head + Self.grin + "b"))
        // Nineteen units plus a pair would be twenty-one: the pair moves whole into the next chunk.
        #expect(chunks == [head, Self.grin + "b"])
    }

    @Test("a ZWJ family longer than the target is a chunk of its own")
    func familyIsItsOwnChunk() {
        #expect(Self.family.count == 1)
        #expect(Self.family.utf16.count == 11)
        let chunks = Self.chunks(Self.planner(target: 5, maxEvent: 200, maxChunks: 10)
            .plan("ab" + Self.family + "cd"))
        #expect(chunks == ["ab", Self.family, "cd"])
    }

    @Test("a combining accent stays with its base")
    func accentStaysWithBase() {
        let head = String(repeating: "a", count: 19)
        let chunks = Self.chunks(Self.planner(target: 20, maxEvent: 200, maxChunks: 10)
            .plan(head + Self.accentedE))
        #expect(chunks == [head, Self.accentedE])
    }

    @Test("a target under one is clamped to one")
    func targetClamped() {
        let planner = Self.planner(target: 0, maxEvent: 4, maxChunks: 10)
        #expect(planner.targetUTF16 == 1)
        #expect(Self.planner(target: -5, maxEvent: 4, maxChunks: 10).targetUTF16 == 1)
        #expect(planner.plan("abc") == .chunks(["a", "b", "c"]))
    }

    @Test("joining the chunks reproduces the input", arguments: [1, 2, 5, 20, 40])
    func joiningReproduces(target: Int) {
        let text = "Hello, " + Self.privetMir + " (\"quoted\") [x] {y} <z> " + Self.grin
            + Self.family + " caf" + Self.accentedE + ". "
            + String(repeating: Self.privetMir, count: 7)
        let chunks = Self.chunks(Self.planner(target: target, maxEvent: 200, maxChunks: 1000)
            .plan(text))
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { !$0.isEmpty })
        #expect(chunks.allSatisfy { $0.utf16.count <= max(target, 11) })
    }

    @Test("the F11 defaults")
    func standardConstants() {
        #expect(KeystrokeChunks.standard.targetUTF16 == 20)
        #expect(KeystrokeChunks.standard.maxEventUTF16 == 200)
        // The largest recognised text the wire carries, all ASCII, packs under the chunk limit.
        let largest = String(repeating: "a", count: RecognisedText.maxBytes)
        #expect(Self.chunks(KeystrokeChunks.standard.plan(largest)).count
            <= KeystrokeChunks.standard.maxChunks)
    }

    // MARK: - the chunk limit

    @Test("a text packing into more chunks than the limit is refused")
    func tooManyChunks() {
        let planner = Self.planner(target: 20, maxEvent: 200, maxChunks: 2)
        #expect(planner.plan(String(repeating: "a", count: 40)) == .chunks([
            String(repeating: "a", count: 20), String(repeating: "a", count: 20),
        ]))
        #expect(planner.plan(String(repeating: "a", count: 41)) == .tooManyChunks)
    }

    @Test("the limit is judged on the packed plan, not on length over target")
    func packingSlackCounts() {
        // Four graphemes of eleven units: 44 units is three chunks by division, but no two of them
        // fit one twenty-unit chunk, so the packed plan is four.
        let text = String(repeating: Self.stacked(10), count: 4)
        #expect(text.utf16.count == 44)
        #expect(Self.planner(target: 20, maxEvent: 200, maxChunks: 4).plan(text).chunkCount == 4)
        #expect(Self.planner(target: 20, maxEvent: 200, maxChunks: 3).plan(text) == .tooManyChunks)
    }

    @Test("dictionary-expanded text over the bound is refused")
    func dictionaryExpansionRefused() {
        let book = Replacements.parse("expand | go | \(String(repeating: "a", count: 1000))")
        let spoken = Array(repeating: "go", count: 100).joined(separator: " ")
        #expect(Self.chunks(KeystrokeChunks.standard.plan(spoken)).count == 15)
        let expanded = Replacements.apply(book, to: spoken).text
        #expect(expanded.utf16.count > KeystrokeChunks.standard.maxChunks
            * KeystrokeChunks.standard.targetUTF16)
        #expect(KeystrokeChunks.standard.plan(expanded) == .tooManyChunks)
    }

    // MARK: - the event limit

    @Test("one grapheme over the event limit is refused, never split")
    func graphemeTooLong() {
        let planner = Self.planner(target: 20, maxEvent: 200, maxChunks: 1000)
        let tower = Self.stacked(10_000)
        #expect(tower.count == 1)
        #expect(planner.plan(tower) == .graphemeTooLong)
        #expect(planner.plan("hello " + tower + " world") == .graphemeTooLong)
    }

    @Test("a grapheme of exactly the event limit is its own chunk")
    func graphemeAtTheLimit() {
        let planner = Self.planner(target: 20, maxEvent: 200, maxChunks: 10)
        #expect(planner.plan("a" + Self.stacked(199) + "b")
            == .chunks(["a", Self.stacked(199), "b"]))
        #expect(planner.plan(Self.stacked(200)) == .graphemeTooLong)
    }

    // MARK: - the planner's own work

    /// A UTF-16 sequence that counts how many units anything drew from it.
    final class CountingUnits: Sequence {
        let units: String.UTF16View
        var drawn = 0

        init(_ text: String) { units = text.utf16 }

        func makeIterator() -> AnyIterator<UInt16> {
            var inner = units.makeIterator()
            return AnyIterator {
                guard let unit = inner.next() else { return nil }
                self.drawn += 1
                return unit
            }
        }
    }

    @Test("the pre-count inspects exactly one unit past the limit on an oversized input")
    func preCountIsBounded() {
        let oversized = CountingUnits(String(repeating: "a", count: 100_000))
        #expect(KeystrokeChunks.boundedUTF16Count(oversized, limit: 12) == 13)
        #expect(oversized.drawn == 13)

        let exact = CountingUnits(String(repeating: "a", count: 12))
        #expect(KeystrokeChunks.boundedUTF16Count(exact, limit: 12) == 12)
        #expect(exact.drawn == 12)
    }

    @Test("text over chunks times event limit is refused; exactly that limit passes the pre-count")
    func preCountBoundary() {
        // 3 x 4 = 12 units. At a target of 4 the twelve-unit text is exactly three full chunks.
        let planner = Self.planner(target: 4, maxEvent: 4, maxChunks: 3)
        #expect(planner.plan(String(repeating: "a", count: 12)).chunkCount == 3)
        #expect(planner.plan(String(repeating: "a", count: 13)) == .tooManyChunks)
        // A single grapheme longer than the whole limit is refused by the pre-count, before any
        // grapheme is iterated.
        #expect(planner.plan(Self.stacked(12)) == .tooManyChunks)
    }

    // MARK: - construction

    @Test("constants whose product would overflow are rejected")
    func overflowRejected() {
        #expect(KeystrokeChunks(targetUTF16: 20, maxEventUTF16: Int.max, maxChunks: 2) == nil)
        #expect(KeystrokeChunks(targetUTF16: 20, maxEventUTF16: Int.max / 2, maxChunks: 2) != nil)
    }

    @Test("constants that cannot plan anything are rejected")
    func nonsenseRejected() {
        #expect(KeystrokeChunks(targetUTF16: 20, maxEventUTF16: 200, maxChunks: 0) == nil)
        #expect(KeystrokeChunks(targetUTF16: 20, maxEventUTF16: 19, maxChunks: 10) == nil)
        #expect(KeystrokeChunks(targetUTF16: 0, maxEventUTF16: 0, maxChunks: 10) == nil)
    }
}

extension DeliveryPlan {
    /// The number of chunks in an accepted plan, nil for a refusal.
    var chunkCount: Int? {
        guard case let .chunks(chunks) = self else { return nil }
        return chunks.count
    }
}
