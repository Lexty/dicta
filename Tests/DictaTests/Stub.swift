// A stub, on purpose. Never put an assertion in this target.
//
// Under Command Line Tools only, `swift test` COMPILES this bundle but does not EXECUTE it — there
// is no `xctest` host utility — so a failing test here still exits 0 (D18). That is not folklore:
// it was measured in Task 1, and the observed exit codes are in CLAUDE.md.
//
// Two guards, because the comment alone is not one:
//   • this target is denied the swift-testing flags in Package.swift, so `import Testing` does not
//     compile here;
//   • `import XCTest` does not compile either — XCTest ships with Xcode, not with the Command Line
//     Tools.
//
// The real tests live in Sources/DictaTestRunner and run via `bash Scripts/test.sh`.
//
// This file exists only so the target has a source file and `swift test` keeps building, which is
// still worth having: it type-checks DictaCore against a second consumer.

import DictaCore

enum StubCompileCheck {
    static let coreIsImportable = !DictaCore.version.isEmpty
}
