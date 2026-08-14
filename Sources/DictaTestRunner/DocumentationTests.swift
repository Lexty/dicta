import DictaCore
import Foundation
import Testing

/// What `README.md` promises, against what the build actually does.
///
/// Documentation rots in a way code does not: nothing runs it, so a wrong path or a stale verb list
/// is discovered by a user following it rather than by a test. The project already parses the two
/// files a user copies -- `docs/keymap.snippet.conf` (`ClientCommandTests`) and
/// `docs/replacements.example.conf` (`ReplacementsTests`) -- and this suite covers the third
/// artefact nobody executes, plus the one fact that lives in three files at once: where `dictactl`
/// is installed. `Scripts/install.sh` puts it somewhere, the keymap snippet invokes it by absolute
/// path (§12), and the README tells the user which path that is. Two of those three agreeing is not
/// enough for a chord to work.
///
/// These assert quotation and paths, never prose. A test that demanded the README explain something
/// would fail on every rewording, which teaches the next person to delete the test.
@Suite("documentation")
struct DocumentationTests {
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Sources/DictaTestRunner
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // the repository root
    }

    static func text(at relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    static let readme: String = (try? text(at: "README.md")) ?? ""

    @Test("the README exists and was read, so an empty file cannot pass the checks below")
    func theReadmeIsReadable() {
        #expect(!Self.readme.isEmpty, "README.md is missing or empty")
    }

    @Test("the README quotes dictactl's own usage text verbatim")
    func theReadmeQuotesTheUsage() {
        // The README shows the usage block so a reader does not have to install first. Copied text
        // is exactly the kind that drifts: a verb added to `ClientCommand` and not to the README
        // leaves the file describing a client that no longer exists.
        let quoted = Self.readme.contains(ClientCommand.usage)
        #expect(quoted, "README.md no longer quotes ClientCommand.usage as it stands")
    }

    @Test("the README names every outcome the record can hold")
    func theReadmeNamesEveryOutcome() {
        // §9's eleven values are what a user reads out of record.jsonl, so a twelfth added to the
        // enum without a line in the table is a value they will meet with no explanation.
        for outcome in AttemptOutcome.allCases {
            let named = Self.readme.contains("`\(outcome.rawValue)`")
            #expect(named, "README.md does not name the outcome \"\(outcome.rawValue)\"")
        }
    }

    @Test("the README names the files dicta actually keeps")
    func theReadmeNamesTheRealPaths() throws {
        let paths = Paths(home: URL(fileURLWithPath: "/tmp/does-not-matter"))
        for file in [paths.record, paths.dictionary] {
            let named = Self.readme.contains(file.lastPathComponent)
            #expect(named, "README.md does not name \(file.lastPathComponent)")
        }
        // The support directory is named by its bundle id, and the README spells the whole path.
        #expect(Self.readme.contains("dev.personal.dicta"))
    }

    // MARK: - the one fact that lives in three files

    /// Where `Scripts/install.sh` puts the client, read off the `install` line itself.
    static func installedClientPath() throws -> String {
        let script = try text(at: "Scripts/install.sh")
        for line in script.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("install "), trimmed.hasSuffix("/dictactl\"") else { continue }
            let closing = trimmed.index(before: trimmed.endIndex)
            guard let opening = trimmed.lastIndex(of: "\"", excluding: closing) else { continue }
            return String(trimmed[trimmed.index(after: opening)..<closing])
        }
        Issue.record("Scripts/install.sh no longer installs dictactl anywhere recognisable")
        return ""
    }

    @Test("the keymap snippet invokes dictactl at the path install.sh puts it")
    func theSnippetMatchesTheInstaller() throws {
        let installed = try Self.installedClientPath()
        #expect(!installed.isEmpty)
        for binding in try ClientCommandTests.bindings() {
            #expect(binding.program == installed,
                    "\(binding.chord) invokes \(binding.program), installed at \(installed)")
        }
    }

    @Test("the README tells the user the same install path")
    func theReadmeMatchesTheInstaller() throws {
        // Written with a tilde in prose and with $HOME in the keymap line; both spell one location,
        // and comparing the tail is what survives that difference without pretending it is not one.
        let installed = try Self.installedClientPath()
        let tail = installed.replacingOccurrences(of: "$HOME", with: "~")
        #expect(Self.readme.contains(tail), "README.md does not name \(tail)")
    }

    @Test("SPEC.md no longer claims that no implementation exists")
    func theSpecStatusIsCurrent() throws {
        // The status line is the first thing a reader believes and the last thing anyone updates.
        let spec = try Self.text(at: "SPEC.md")
        #expect(!spec.contains("No implementation exists"),
                "SPEC.md still opens by saying dicta is unimplemented")
    }
}

private extension String {
    /// The last `"` strictly before `limit`. Written out because `lastIndex(of:)` searches the
    /// whole string, and the closing quote is the one that must not be found here.
    func lastIndex(of character: Character, excluding limit: Index) -> Index? {
        self[startIndex..<limit].lastIndex(of: character)
    }
}
