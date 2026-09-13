import DictaCore
import DictaMenuKit
import Foundation
import Testing

/// `DictaMenuKit` holds the menu's logic and nothing that would put it out of the test runner's
/// reach or the menu's linkage budget (D19, D27).
///
/// Two rules, both read off the source rather than off a build, because both fail silently: an
/// `import SwiftUI` in the library still compiles and still links, and a `DictaRuntime`
/// dependency only shows up as FluidAudio inside `DictaMenu`, which `Scripts/linkage.sh` catches
/// one step later and without naming the edge that caused it.
@Suite("menu kit boundary")
struct MenuKitBoundaryTests {
    /// What the library may import: the menu's three modules, and the two system frameworks with no
    /// window in them.
    static let allowedImports: Set<String> = [
        "Foundation", "Combine", "DictaCore", "DictaIPC", "DictaRecord",
    ]

    /// Every module a Swift source imports, attributes and `import struct M.T` forms included.
    static func imports(in source: String) -> [String] {
        let kinds: Set<Substring> = ["struct", "class", "enum", "protocol", "func", "var", "let",
                                     "typealias"]
        return source.split(separator: "\n").compactMap { line in
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let index = words.firstIndex(of: "import"),
                  words[..<index].allSatisfy({ $0.hasPrefix("@") }),
                  index + 1 < words.count else { return nil }
            var module = words[index + 1]
            if kinds.contains(module), index + 2 < words.count { module = words[index + 2] }
            return String(module.split(separator: ".").first ?? module)
        }
    }

    @Test("the import reader sees plain, attributed and scoped imports, and nothing else")
    func importReader() {
        let source = """
            import Foundation
            @preconcurrency import Combine
            import struct SwiftUI.Color
            // import AppKit
            let text = "import AVFoundation"
            """
        #expect(Self.imports(in: source) == ["Foundation", "Combine", "SwiftUI"])
    }

    @Test("DictaMenuKit imports only Foundation, Combine, DictaCore, DictaIPC and DictaRecord")
    func libraryImportsStayInsideTheBudget() throws {
        let directory = BundleTests.repositoryRoot.appendingPathComponent("Sources/DictaMenuKit")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }.sorted()
        #expect(names.contains("MenuWorld.swift"))
        for name in names {
            let source = try BundleTests.text(at: "Sources/DictaMenuKit/\(name)")
            let outside = Self.imports(in: source).filter { !Self.allowedImports.contains($0) }
            #expect(outside.isEmpty, "\(name) imports \(outside)")
        }
    }

    /// The `.target(...)` declaration in `Package.swift` that names the module.
    static func targetDeclaration(named name: String, in manifest: String) -> Substring? {
        guard let nameRange = manifest.range(of: "name: \"\(name)\"") else { return nil }
        let start = manifest[..<nameRange.lowerBound].range(of: ".target(", options: .backwards)
        guard let start, let end = manifest[nameRange.upperBound...].range(of: "),") else {
            return nil
        }
        return manifest[start.lowerBound..<end.upperBound]
    }

    @Test("Package.swift gives DictaMenuKit the menu's budget and no DictaRuntime")
    func manifestHoldsTheBudget() throws {
        let manifest = try BundleTests.text(at: "Package.swift")
        let target = try #require(Self.targetDeclaration(named: "DictaMenuKit", in: manifest))
        #expect(target.contains("dependencies: [\"DictaCore\", \"DictaIPC\", \"DictaRecord\"]"))
        #expect(target.contains("path: \"Sources/DictaMenuKit\""))
        // The dependency that would put FluidAudio and AVFoundation inside the menu (D27).
        #expect(!target.contains("DictaRuntime"))
        #expect(!target.contains(".product("))
    }
}

/// A `@MainActor` suite runs under `DictaTestRunner`'s own entry point, and waits on the main actor
/// without starving it.
///
/// Every suite that drives the menu's view model is `@MainActor`, and until this one none was. The
/// runner starts at a top-level `await` in `main.swift`, so whether the main actor is served while
/// a test is suspended is a property of that entry point, and a test that is never scheduled
/// reports nothing at all: D18's shape again. Scored under both toolchains, and watched failing,
/// before any of the view model moved (plan Task 1).
@MainActor
@Suite("main-actor probe")
struct MainActorProbeTests {
    /// `Thread.isMainThread`, which Swift 6 refuses to read from an `async` body directly.
    nonisolated static func onMainThread() -> Bool { Thread.isMainThread }

    @Test("a @MainActor test runs on the main thread and resumes after a hop back from a thread")
    func mainActorSuiteRuns() async {
        #expect(Self.onMainThread())
        var cancelled = false
        MenuCancel { cancelled = true }.cancel()
        #expect(cancelled)

        // The shape the view model's completions take: work on a real thread, then back to the main
        // actor. If the main actor were not served while this test is suspended, this would hang.
        let hopped = await withCheckedContinuation { (resume: CheckedContinuation<Bool, Never>) in
            let thread = Thread {
                Task { @MainActor in resume.resume(returning: Self.onMainThread()) }
            }
            thread.start()
        }
        #expect(hopped)
    }
}
