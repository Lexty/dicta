// swift-tools-version:6.0
import PackageDescription
import Foundation

// dicta — voice dictation into agterm's input line.
//
// Target layout. The split exists to make decisions testable in a Command-Line-Tools-ONLY
// environment, and to keep the keypress client's cold start a budgeted property (D12).
//
//   • DictaCore       — pure logic, NO I/O: the lifecycle state machine, the injection sanitiser,
//                       the replacement engine, the record schema, the wire types. This is what
//                       the tests actually drive (D19).
//   • DictaIPC        — the Unix-socket transport, BOTH halves in one module. Split out for one
//                       concrete reason: `dictactl` needs the client half, and DictaRuntime is
//                       where AVFoundation and CoreML land. Without the split every keypress would
//                       drag the capture stack through dyld. Keeping both halves together is also
//                       what stops the two ends' framing rules from drifting apart.
//   • DictaRuntime    — everything that touches the world: the agterm adapter (subprocesses),
//                       capture, recognition, the filter seam, the record writer.
//                       A library rather than part of the executable because SwiftPM CANNOT import
//                       an executable target — here the test runner can reach it; inside `Dicta`
//                       it could not.
//   • Dicta           — the resident daemon executable. Wiring only.
//   • dictactl        — the client agterm's keymap invokes on every chord. Depends on DictaCore and
//                       DictaIPC and NOTHING else: it links no AVFoundation, no CoreML, no AppKit,
//                       and it never opens the microphone, because the TCC grant belongs to the
//                       signed daemon bundle alone (D11, D12, invariant 8).
//   • DictaTestRunner — where the tests actually live (swift-testing @Test plus the SwiftPM entry
//                       point). The real run is `bash Scripts/test.sh`.
//   • DictaTests      — a compile-only stub, so `swift test` still builds. Never put an assertion
//                       here: under CLT-only it would report as passing while never having run.
//
// Why the runner exists at all (D18): under Command Line Tools only, `swift test` BUILDS the test
// bundle but does not EXECUTE it — there is no `xctest` host utility — so a failing test still
// exits 0 and the command is worthless as a gate. The runner drives swift-testing through its own
// entry point and exits non-zero. This was verified by observation, not assumed; see AGENTS.md.
//
// Note the absence of a separate wire-protocol target. The sibling project `acta` isolates one
// because a foreign binary decodes its schema; here `dictactl` ships from this repository and is
// always in lockstep, so that isolation would be ceremony. Copy the reasoning, not the layout.

/// The active developer directory, which decides where swift-testing's framework and macro plugin
/// live. `DEVELOPER_DIR` wins when set, so a CI or a full-Xcode machine can redirect us.
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

/// Flags that expose swift-testing (Testing.framework, its interop dylib, the TestingMacros
/// plugin) to the runner. The same three pieces ship in two layouts under different roots, and
/// which one is live is whatever `xcode-select` points at -- so this probes for the framework
/// rather than deciding by platform, and lists both rather than assuming the machine it was
/// written on.
///
/// Observed 2026-08-25, when a full Xcode appeared on a machine that had only ever had the Tools:
/// the Tools-only guard fell through, the runner still COMPILED and LINKED, and every test then
/// died in dyld on `@rpath/Testing.framework` before reaching a single assertion. A miss here is
/// silent at build time and fatal at run time, which is the same shape of trap as D18 -- a gate
/// that looks like it ran and did not.
func swiftTestingSettings() -> (swift: [SwiftSetting], linker: [LinkerSetting]) {
    let dev = developerDir()
    // First layout whose Testing.framework is really on disk wins. Neither root exists under the
    // other's developer directory, so the order is documentation rather than precedence.
    let layouts = [
        // Command Line Tools: everything hangs off `Library/Developer`, plugin in the Tools' own
        // swift host directory.
        (
            frameworks: "\(dev)/Library/Developer/Frameworks",
            lib: "\(dev)/Library/Developer/usr/lib",
            plugin: "\(dev)/usr/lib/swift/host/plugins/testing"
        ),
        // Full Xcode: the framework and the dylib move inside the macOS platform, and the macro
        // plugin into the toolchain -- which is why one `dev` substitution is not enough.
        (
            frameworks: "\(dev)/Platforms/MacOSX.platform/Developer/Library/Frameworks",
            lib: "\(dev)/Platforms/MacOSX.platform/Developer/usr/lib",
            plugin: "\(dev)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing"
        ),
    ]

    guard let layout = layouts.first(where: {
        FileManager.default.fileExists(atPath: "\($0.frameworks)/Testing.framework")
    }) else {
        return ([], [])
    }
    return (
        [.unsafeFlags(["-F", layout.frameworks, "-plugin-path", layout.plugin])],
        [.unsafeFlags([
            "-F", layout.frameworks,
            "-L", layout.lib,
            "-Xlinker", "-rpath", "-Xlinker", layout.frameworks,
            "-Xlinker", "-rpath", "-Xlinker", layout.lib,
        ])]
    )
}

let testing = swiftTestingSettings()

let package = Package(
    name: "dicta",
    platforms: [.macOS(.v14)],
    dependencies: [
        // D10 and §12: linked as a library rather than shelled out to. `fluidaudiocli` pays model
        // load per invocation, and "no model load on the hot path" is the normative half of D10 --
        // a CLI would spend seconds of ANE compilation inside every dictation.
        //
        // Pinned EXACTLY, not `from:`. The API this rests on is not the documented one: v0.15.5's
        // `AsrManager.transcribe` takes an `inout TdtDecoderState` the README does not mention, and
        // `AsrModels.load` wants the staged HuggingFace repo folder rather than its parent. A minor
        // bump that rearranged either would be a compile error at best and a silently different
        // model at worst, so the version moves when somebody reads the diff.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
    ],
    targets: [
        .target(name: "DictaCore", path: "Sources/DictaCore"),
        .target(name: "DictaIPC", dependencies: ["DictaCore"], path: "Sources/DictaIPC"),
        // Reading §9's record off disk. Split out for the SAME concrete reason `DictaIPC` was, in
        // its second instance rather than as a new principle: the menu-bar UI needs the reader, and
        // `DictaRuntime` is where FluidAudio and CoreML land (D27, invariant 8). The other half of
        // the reason is that the reader here is BOUNDED — the record is append-only and grows for
        // ever, and a panel that opens many times a day cannot parse all of it each time.
        .target(name: "DictaRecord", dependencies: ["DictaCore"], path: "Sources/DictaRecord"),
        // FluidAudio lands HERE and nowhere else. It is the whole of the CoreML weight D12 keeps
        // off the keypress path: `dictactl` depends on DictaCore + DictaIPC, so it cannot reach
        // this even by accident.
        .target(
            name: "DictaRuntime",
            dependencies: [
                "DictaCore",
                "DictaIPC",
                "DictaRecord",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/DictaRuntime"
        ),
        .executableTarget(
            name: "Dicta",
            dependencies: ["DictaCore", "DictaIPC", "DictaRuntime"],
            path: "Sources/Dicta"
        ),
        // D12: DictaCore + DictaIPC only. Adding DictaRuntime here would be the regression.
        .executableTarget(
            name: "dictactl",
            dependencies: ["DictaCore", "DictaIPC"],
            path: "Sources/dictactl"
        ),
        // The menu-bar UI (D27). The SAME dependency budget as `dictactl`, and for the same reason
        // one step further out: this binary must not be able to open the microphone (invariant 8),
        // because the TCC grant belongs to the daemon's signed bundle alone (D11). It links SwiftUI
        // on top, which `dictactl` may not — that is the one difference between their two rows in
        // `Scripts/linkage.sh`, and it is written down there rather than left to be inferred.
        //
        // Note what putting the menu HERE rather than in `Dicta` buys, since the alternative is the
        // obvious one and `acta` takes it: the daemon's binary keeps failing invariant 11's gate on
        // `_OBJC_CLASS_$_NSEvent`, which a SwiftUI status item would drag in; and F6/F8a stay
        // measurements of the process they were taken in, which has no `NSApplication` (D27).
        .executableTarget(
            name: "DictaMenu",
            dependencies: ["DictaCore", "DictaIPC", "DictaRecord"],
            path: "Sources/DictaMenu"
        ),
        // TEMPORARY: plan 20260912-dicta-focused-fields, Task 1 (F11). Deleted once F11 is written.
        .executableTarget(name: "FieldProbe", path: "Sources/FieldProbe"),
        .executableTarget(
            name: "DictaTestRunner",
            dependencies: ["DictaCore", "DictaIPC", "DictaRecord", "DictaRuntime"],
            path: "Sources/DictaTestRunner",
            swiftSettings: testing.swift,
            linkerSettings: testing.linker
        ),
        // Compile-only, and deliberately WITHOUT `testing.swift` / `testing.linker`. Denying this
        // target the swift-testing flags means `import Testing` here does not compile, so the trap
        // D18 describes — an assertion that reports as passing while never having run — cannot be
        // walked into by accident. Verified both ways during Task 1; see AGENTS.md.
        .testTarget(
            name: "DictaTests",
            dependencies: ["DictaCore"],
            path: "Tests/DictaTests"
        ),
    ]
)
