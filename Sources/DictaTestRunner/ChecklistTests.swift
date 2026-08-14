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

    /// The first column of the checklist's own §7 table.
    static var checklistFailureRows: [String] {
        checklist.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") else { return nil }
            let cells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count > 1 else { return nil }
            return cells[1]
        }
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

    @Test("SPEC.md still has the ten invariants the checklist audits")
    func theInvariantsAreStillTen() {
        let numbers = Self.invariants.map(\.number)
        #expect(numbers == Array(1...10), "§8's numbering moved: \(numbers)")
    }

    @Test("every invariant in §8 has a row naming what checks it")
    func everyInvariantIsAudited() {
        for invariant in Self.invariants {
            // The bold title, verbatim except for a trailing full stop, which two of §8's items
            // carry inside the bold and which reads badly in a table cell.
            let title = invariant.title.hasSuffix(".")
                ? String(invariant.title.dropLast())
                : invariant.title
            let named = Self.checklist.contains(title)
            #expect(
                named,
                "invariant \(invariant.number) is not named in the checklist: \"\(title)\""
            )
        }
    }

    @Test("every row of §7 has a line in the checklist, quoting the event verbatim")
    func everyFailureRowIsAudited() {
        let audited = Set(Self.checklistFailureRows)
        for event in Self.failureMatrixEvents {
            let covered = audited.contains(event)
            #expect(covered, "§7's row \"\(event)\" has no line in docs/manual-checklist.md")
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
}
