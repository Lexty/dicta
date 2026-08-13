// swift-tools-version:6.0
import PackageDescription
import Foundation

// dicta — voice dictation into agterm's input line.
//
// Target layout (mirrors the split that makes code testable in a Command-Line-Tools-ONLY
// environment, learned in the sibling project `acta`):
//   • DictaCore       — pure logic, NO I/O: the state machine, the injection sanitizer, the wire
//                       types. This is what the tests actually drive.
//   • DictaIPC        — the Unix-socket transport, both halves of it. Split out for ONE concrete
//                       reason: `dictactl` needs the client, and DictaRuntime is where
//                       AVFoundation and CoreML will land in step 2. Without this target the
//                       keypress client would drag the whole capture stack into its cold start.
//                       Keeping both halves in one file is also what stops the two ends' framing
//                       rules from drifting apart.
//   • DictaRuntime    — everything else that touches the world: the agterm client (subprocesses),
//                       capture, transcription, the filter, the history log.
//                       A library rather than part of the executable because SwiftPM CANNOT import
//                       an executable target — while this code lives here, the test runner can
//                       reach it; inside `Dicta` it could not.
//   • Dicta           — the resident daemon executable. Thin: wiring only.
//   • dictactl        — the client agterm's keymap invokes. Deliberately depends on DictaCore ONLY:
//                       it must stay a few milliseconds of cold start, so it links no AVFoundation,
//                       no CoreML, no AppKit — and it must never touch the microphone, because the
//                       TCC grant belongs to the signed daemon bundle alone.
//   • DictaTestRunner — where the tests actually live (swift-testing @Test + the SwiftPM entry
//                       point). The real run is `bash Scripts/test.sh`.
//   • DictaTests      — a stub, so that `swift test` compiles. Never put a real test here.
//
// Why the runner exists at all: under CLT-only `swift test` BUILDS the test bundle but does not
// EXECUTE it (no `xctest` host utility), so a failing test still exits 0 and the command is
// useless as a gate. The runner executes swift-testing through its entry point and exits non-zero.
//
// Note the absence of a separate wire-protocol target. `acta` isolates one because a foreign
// binary decodes its schema; here `dictactl` ships from this repository and is always in lockstep,
// so that isolation would be ceremony. Copy the reasoning, not the layout.

func developerDir() -> String {
    if let dir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !dir.isEmpty {
        return dir
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    proc.arguments = ["-p"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    do {
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let str = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
            return str
        }
    } catch {
        // fall through to the default below
    }
    return "/Library/Developer/CommandLineTools"
}

// Flags that expose swift-testing (Testing.framework, the TestingMacros plugin) in the CLT layout.
// With a full Xcode installed the paths differ and SwiftPM finds everything itself — then we add
// nothing.
func swiftTestingSettings() -> (swift: [SwiftSetting], linker: [LinkerSetting]) {
    let dev = developerDir()
    let frameworks = "\(dev)/Library/Developer/Frameworks"
    let libDir = "\(dev)/Library/Developer/usr/lib"
    let pluginDir = "\(dev)/usr/lib/swift/host/plugins/testing"

    guard FileManager.default.fileExists(atPath: "\(frameworks)/Testing.framework") else {
        return ([], [])
    }
    return (
        [.unsafeFlags(["-F", frameworks, "-plugin-path", pluginDir])],
        [.unsafeFlags([
            "-F", frameworks,
            "-L", libDir,
            "-Xlinker", "-rpath", "-Xlinker", frameworks,
            "-Xlinker", "-rpath", "-Xlinker", libDir,
        ])]
    )
}

let testing = swiftTestingSettings()

let package = Package(
    name: "dicta",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DictaCore", path: "Sources/DictaCore"),
        .target(name: "DictaIPC", dependencies: ["DictaCore"], path: "Sources/DictaIPC"),
        .target(
            name: "DictaRuntime",
            dependencies: ["DictaCore", "DictaIPC"],
            path: "Sources/DictaRuntime"
        ),
        .executableTarget(
            name: "Dicta",
            dependencies: ["DictaRuntime", "DictaIPC"],
            path: "Sources/Dicta"
        ),
        .executableTarget(
            name: "dictactl",
            dependencies: ["DictaCore", "DictaIPC"],
            path: "Sources/dictactl"
        ),
        .executableTarget(
            name: "DictaTestRunner",
            dependencies: ["DictaCore", "DictaIPC", "DictaRuntime"],
            path: "Sources/DictaTestRunner",
            swiftSettings: testing.swift,
            linkerSettings: testing.linker
        ),
        .testTarget(name: "DictaTests", dependencies: ["DictaCore"], path: "Tests/DictaTests"),
    ]
)
