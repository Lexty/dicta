import DictaCore
import DictaIPC
import DictaRuntime
import Foundation
import Testing

/// The gate's own test. Everything else in this suite is worthless if the suite does not actually
/// execute, and under Command Line Tools only that is not a given: `swift test` builds the bundle
/// and exits 0 without running a thing (D18). These assertions fail if the tests are ever hosted
/// somewhere that does not run them.
@Suite("test runner")
struct RunnerTests {
    @Test("the runner executable is what hosts the tests, not an xctest host")
    func hostedByTheRunner() {
        let host = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).lastPathComponent
        #expect(host == "DictaTestRunner")
    }

    @Test("the entry point reaches test bodies, so a failure here would be observable")
    func bodiesExecute() {
        // Trivially true — the point is that it is EVALUATED. A suite that never runs cannot fail,
        // which is exactly the trap D18 describes.
        var executed = false
        executed = true
        #expect(executed)
    }

    @Test("the runner links all three library modules it has to drive")
    func linksTheModulesUnderTest() {
        #expect(!DictaCore.version.isEmpty)
        #expect(DictaIPC.wireVersion >= 1)
        #expect(DictaRuntime.isLibrary)
    }
}
