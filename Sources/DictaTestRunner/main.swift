import Foundation
import Testing

// Test-runner entry point. Under Command-Line-Tools-only, `swift test` COMPILES the test bundle but
// does not EXECUTE it — there is no `xctest` host utility, so a failing test still exits 0 and the
// command is worthless as a gate. The real run goes through swift-testing's own entry point here,
// and exits non-zero on the first failure. Run it with `bash Scripts/test.sh`.

await Testing.__swiftPMEntryPoint() as Never
