import Foundation
import Testing

/// `docs/manual-checklist.md` claims two things: that every invariant in SPEC.md §8 has a test that
/// fails if it stops holding, and that every row of SPEC.md §7 owned by steps 1-3 has a test or a
/// named human check. Task 12 of the plan is that audit.
///
/// An audit written once and never re-run is a document that quietly turns into fiction. Three ways
/// it rots, all of them silent:
///
///   • a row is added to §7 and nobody adds a line to the checklist;
///   • an invariant is reworded in the spec and the checklist keeps describing the old one;
///   • a test is renamed or deleted and the checklist goes on citing it.
///
/// This suite closes all three by parsing the three files against each other. It asserts nothing
/// about behaviour — the tests it names do that. What it asserts is that the map still matches the
/// territory, which is the same reason `ClientCommandTests` parses the keymap snippet and
/// `BundleTests` parses `Info.plist`: the artefact that is not code is the one nothing else checks.
///
/// The citation convention is `` `test: <name>` `` in the checklist, so a test name is
/// distinguishable from the many other backticked things in that file (paths, scripts, spec
/// symbols). A test whose own name contains a backtick therefore cannot be cited; the checklist
/// says so where that happens rather than mangling the name.
@Suite("checklist")
struct ChecklistTests {
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Sources/DictaTestRunner
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // the repository root
    }

    static func text(at relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    static let checklist: String = (try? text(at: "docs/manual-checklist.md")) ?? ""
    static let spec: String = (try? text(at: "SPEC.md")) ?? ""

    // MARK: - Reading the spec

    /// The lines of a `## N. Title` section, up to the next `## ` heading.
    static func specSection(_ heading: String) -> [String] {
        var inside = false
        var lines: [String] = []
        for line in spec.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                if inside { break }
                inside = line.hasPrefix("## \(heading)")
                continue
            }
            if inside { lines.append(line) }
        }
        return lines
    }

    /// §7's first column: the event each row describes, verbatim, header and rule excluded.
    static var failureMatrixEvents: [String] {
        specSection("7.").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") else { return nil }
            let cells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count > 1 else { return nil }
            let event = cells[1]
            guard !event.isEmpty, event != "event", !event.hasPrefix("---") else { return nil }
            return event
        }
    }

    /// §8's numbered items, as (number, the bolded title that opens the item).
    static var invariants: [(number: Int, title: String)] {
        var found: [(Int, String)] = []
        for line in specSection("8.") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let dot = trimmed.firstIndex(of: "."),
                  let number = Int(trimmed[trimmed.startIndex..<dot]) else { continue }
            let rest = trimmed[trimmed.index(after: dot)...]
            let parts = rest.components(separatedBy: "**")
            guard parts.count >= 3 else { continue }
            found.append((number, parts[1]))
        }
        return found
    }

    // MARK: - Reading the checklist

    /// Everything cited as `` `test: <name>` ``.
    static var citedTestNames: [String] {
        var names: [String] = []
        for chunk in checklist.components(separatedBy: "`").enumerated()
        where chunk.offset % 2 == 1 {
            let inside = chunk.element
            guard inside.hasPrefix("test: ") else { continue }
            let name = String(inside.dropFirst("test: ".count))
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, name != "<name>" { names.append(name) }
        }
        return names
    }

    /// Every table row of the checklist, as its cells, with the rule rows excluded. The leading and
    /// trailing empty cells of a pipe table survive, so cell 1 is the first column.
    static var checklistRows: [[String]] {
        checklist.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") else { return nil }
            let cells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count > 2, !cells[1].hasPrefix("---") else { return nil }
            return cells
        }
    }

    /// The invariant table's rows: `| # | invariant | checked by |`. Told from the other table by
    /// the first column being a number, which is also what excludes its header.
    static var invariantRows: [(number: Int, invariant: String, checkedBy: String)] {
        checklistRows.compactMap { cells in
            guard cells.count > 3, let number = Int(cells[1]) else { return nil }
            return (number, cells[2], cells[3])
        }
    }

    /// The §7 table's rows: `| event | checked by |`, header excluded.
    static var failureRows: [(event: String, checkedBy: String)] {
        checklistRows.compactMap { cells in
            guard Int(cells[1]) == nil else { return nil }
            let event = cells[1]
            guard !event.isEmpty, event != "event", event != "#" else { return nil }
            return (event, cells[2])
        }
    }

    /// The first column of the checklist's own §7 table.
    static var checklistFailureRows: [String] { failureRows.map(\.event) }

    /// Whether a "checked by" cell names anything at all that could go red.
    ///
    /// This is the audit's whole point and it was for a while unasserted: the two audits compared
    /// only the FIRST column, so blanking a "checked by" cell — or leaving one empty for a row
    /// added in a hurry — kept the suite green while the mapping the file exists to hold quietly
    /// stopped existing. Three things count, and nothing else does: a cited test, a script that
    /// stands in for one where no assertion can reach (invariant 8), and a numbered human item
    /// from this file's own list, which is the honest answer for the rows a machine cannot score.
    static func namesEvidence(_ cell: String) -> Bool {
        if cell.contains("`test: ") { return true }
        if cell.contains("Scripts/") { return true }
        var rest = Substring(cell)
        while let marker = rest.range(of: "**H") {
            let after = rest[marker.upperBound...]
            if after.first?.isNumber == true { return true }
            rest = after
        }
        return false
    }

    // MARK: - Reading the suite itself

    /// Every `@Test("...")` name declared under `Sources/DictaTestRunner`. Parsed off the sources
    /// rather than asked of swift-testing, which offers no such enumeration from inside a run.
    static let declaredTestNames: Set<String> = {
        let directory = repositoryRoot.appendingPathComponent("Sources/DictaTestRunner")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var names: Set<String> = []
        for file in files where file.hasSuffix(".swift") {
            let path = directory.appendingPathComponent(file)
            guard let source = try? String(contentsOf: path, encoding: .utf8) else { continue }
            for line in source.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("@Test(\"") else { continue }
                let afterQuote = trimmed.dropFirst("@Test(\"".count)
                // The name ends at the first unescaped quote. No test name here contains one.
                guard let end = afterQuote.firstIndex(of: "\"") else { continue }
                names.insert(String(afterQuote[afterQuote.startIndex..<end]))
            }
        }
        return names
    }()

    // MARK: - The audits

    @Test("the checklist exists and was parsed, so an empty file cannot pass every check below")
    func theChecklistIsReadable() throws {
        #expect(!Self.checklist.isEmpty, "docs/manual-checklist.md is missing or empty")
        #expect(!Self.spec.isEmpty, "SPEC.md is missing or empty")
        #expect(Self.declaredTestNames.count > 300, "the suite's own names did not parse")
        #expect(Self.citedTestNames.count > 50, "no test citations were found in the checklist")
    }

    @Test("every test the checklist cites is a test this build actually has")
    func everyCitationResolves() {
        for name in Self.citedTestNames {
            // The membership is computed before `#expect` sees it on purpose: handed the
            // expression, swift-testing prints all 350-odd declared names into the failure, and the
            // one useful sentence scrolls away.
            let known = Self.declaredTestNames.contains(name)
            #expect(known, "the checklist cites a test that does not exist: \"\(name)\"")
        }
    }

    @Test("SPEC.md still has the fourteen invariants the checklist audits")
    func theInvariantsAreStillFourteen() {
        let numbers = Self.invariants.map(\.number)
        #expect(numbers == Array(1...14), "§8's numbering moved: \(numbers)")
    }

    @Test("every invariant in §8 has a row naming what checks it")
    func everyInvariantIsAudited() {
        let rows = Self.invariantRows
        for invariant in Self.invariants {
            // The bold title, verbatim except for a trailing full stop, which two of §8's items
            // carry inside the bold and which reads badly in a table cell.
            let title = invariant.title.hasSuffix(".")
                ? String(invariant.title.dropLast())
                : invariant.title
            // Its OWN row, and not merely somewhere in the file: a global substring search passes
            // an invariant whose title happens to appear in a paragraph, and passes two invariants
            // whose rows have swapped their citations.
            guard let row = rows.first(where: { $0.number == invariant.number }) else {
                #expect(Bool(false), "invariant \(invariant.number) has no row in the checklist")
                continue
            }
            #expect(
                row.invariant.contains(title),
                "the checklist's row \(invariant.number) does not name \"\(title)\""
            )
            #expect(
                Self.namesEvidence(row.checkedBy),
                """
                invariant \(invariant.number) is audited by nothing: its "checked by" cell names \
                no test, no script and no human item
                """
            )
        }
    }

    @Test("every row of §7 has a line in the checklist, quoting the event verbatim")
    func everyFailureRowIsAudited() {
        let audited = Self.failureRows
        for event in Self.failureMatrixEvents {
            guard let row = audited.first(where: { $0.event == event }) else {
                #expect(Bool(false), "§7's row \"\(event)\" has no line in the checklist")
                continue
            }
            // The second column is the audit; a row that quotes the event and then says nothing is
            // a row that documents the gap it was written to close.
            #expect(
                Self.namesEvidence(row.checkedBy),
                """
                §7's row "\(event)" is audited by nothing: its "checked by" cell names no test, \
                no script and no human item
                """
            )
        }
    }

    @Test("the checklist audits no row §7 does not have, so a stale line cannot linger")
    func noInventedFailureRows() {
        let real = Set(Self.failureMatrixEvents)
        // The checklist holds two tables; the invariant table's first cell is a number, and the
        // rows of §7's table are the rest. Anything left over that §7 does not name is stale.
        let suspects = Self.checklistFailureRows.filter { cell in
            !cell.isEmpty && cell != "event" && cell != "#" && !cell.hasPrefix("---")
                && Int(cell) == nil && cell != "invariant"
        }
        for cell in suspects {
            let stillInTheSpec = real.contains(cell)
            #expect(
                stillInTheSpec,
                "the checklist audits a §7 row that no longer exists: \"\(cell)\""
            )
        }
    }

    @Test("the human items the audits defer to are actually written out")
    func theDeferredHumanItemsExist() {
        // Audit 2 sends two rows to a human by name. A dangling reference is exactly the kind of
        // gap this file exists to make impossible.
        for item in ["**H1", "**H2", "**H3"] {
            let defined = Self.checklist.contains(item)
            #expect(defined, "the checklist refers to \(item) but never defines it")
        }
    }

    @Test("every human item has a number of its own, and the numbers have no holes")
    func humanItemNumbersAreUnique() {
        // Written after two items were both called H14 — push-to-talk's laptop-keyboard gesture and
        // the menu-bar glyph, added on the same day by two sessions that could not see each other's
        // files. Nothing caught it: the citations above only spot-check H1–H3, and a duplicate
        // reads perfectly well on the page. The cost is not cosmetic. The numbers are how a person
        // reports what they scored, and "H14 passed" against two different items is a pass recorded
        // for whichever one the reader had in mind.
        var numbers: [Int] = []
        for line in Self.checklist.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- **H") else { continue }
            let digits = trimmed.dropFirst("- **H".count).prefix { $0.isNumber }
            guard let number = Int(digits) else { continue }
            numbers.append(number)
        }
        #expect(numbers.count >= 20, "the human items could not be parsed off the checklist")
        let duplicates = Set(numbers.filter { number in numbers.filter { $0 == number }.count > 1 })
        #expect(duplicates.isEmpty,
                "two human items share a number: \(duplicates.sorted().map { "H\($0)" })")
        // Contiguous from 1, so an item cannot be quietly dropped and leave a number nobody can
        // look up in a report written before it went.
        #expect(Set(numbers) == Set(1 ... (numbers.max() ?? 0)),
                "the human items skip a number: \(numbers.sorted())")
    }
}
