import DictaCore
import Foundation
import Testing

/// The bundle is the anchor the microphone TCC grant attaches to (D11), and every key here is load
/// bearing for that: the identifier the grant is recorded against, the entitlement that permits the
/// device, the sentence the prompt shows, and the flag keeping the daemon out of the dock.
///
/// None of it is code, so nothing else would notice an edit that dropped one. The symptom of that
/// edit is not a failing build — it is a TCC prompt reappearing weeks later, or a dock icon
/// stealing focus from the terminal dicta is about to type into. Hence this suite: it reads the
/// files `Scripts/bundle.sh` actually ships and asserts the exact keys.
///
/// What it deliberately does NOT do is run `codesign`. Signing touches a keychain and takes
/// seconds; its own check lives in `bundle.sh`, which fails if the requirement it produced is
/// pinned to a cdhash rather than to the certificate leaf.
@Suite("bundle")
struct BundleTests {
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Sources/DictaTestRunner
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // the repository root
    }

    static func plist(at relativePath: String) throws -> [String: Any] {
        let url = repositoryRoot.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(parsed as? [String: Any], "\(relativePath) is not a plist dictionary")
    }

    static func text(at relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - Info.plist

    @Test("Info.plist is a well-formed plist")
    func infoPlistParses() throws {
        let info = try Self.plist(at: "Resources/Info.plist")
        #expect(!info.isEmpty)
    }

    @Test("the bundle id is the one identity the grant, the socket and the record all share")
    func bundleIdentifierMatchesPaths() throws {
        let info = try Self.plist(at: "Resources/Info.plist")
        // If these two ever diverge, the daemon would take its grant under one identity and write
        // its files under another — and the second one would look, from the outside, unsigned.
        #expect(info["CFBundleIdentifier"] as? String == Paths.bundleID)
    }

    @Test("the executable key names the SwiftPM product bundle.sh copies in")
    func executableName() throws {
        let info = try Self.plist(at: "Resources/Info.plist")
        let executable = try #require(info["CFBundleExecutable"] as? String)
        #expect(executable == "Dicta")
        // The bundle would launch nothing at all if bundle.sh copied the binary under another name.
        // Since D27 the layout is done by one `assemble` function for both bundles, so the claim is
        // in two halves: the function puts the binary where the plist says, and the daemon's call
        // hands it the daemon's name.
        let bundleScript = try Self.text(at: "Scripts/bundle.sh")
        #expect(bundleScript.contains("cp \"$binary\" \"$app_dir/Contents/MacOS/$exe\""))
        #expect(bundleScript.contains(
            "assemble \"$APP_DIR\" \"$APP_NAME\" \"$BIN\" \"$ROOT/Resources/Info.plist\""))
        #expect(bundleScript.contains("APP_NAME=\"Dicta\""))
    }

    @Test("LSUIElement keeps the daemon out of the dock, the menu bar and cmd-tab")
    func isAnAgent() throws {
        let info = try Self.plist(at: "Resources/Info.plist")
        // §13 lists a dock icon and a menu bar as deliberately out of scope. Without this key the
        // bundle is an ordinary app, and a stray click on it takes focus away from the terminal.
        #expect(info["LSUIElement"] as? Bool == true)
    }

    @Test("both bundles name one icon, and the file they name is really there")
    func iconIsPresentAndShared() throws {
        // The artwork is not a contradiction of the key above. §13 rules out a DOCK icon — a tile
        // that can be clicked and take focus from the terminal dicta is about to type into — and
        // LSUIElement still forbids exactly that. What this names is what macOS draws where the
        // bundle is listed anyway: System Settings → Privacy & Security → Microphone, the one
        // screen a user of dicta has to visit, where the alternative is a blank sheet of paper
        // beside a request for their microphone.
        let daemon = try Self.plist(at: "Resources/Info.plist")
        let menu = try Self.plist(at: "Resources/DictaMenu-Info.plist")
        #expect(daemon["CFBundleIconFile"] as? String == "AppIcon")
        #expect(menu["CFBundleIconFile"] as? String == daemon["CFBundleIconFile"] as? String)

        // A CFBundleIconFile pointing at a file that is not in the bundle does not fail to build
        // and does not warn — it renders as a blank sheet of paper, which looks exactly like having
        // no icon at all. So the file is asserted to exist, to be an icns rather than whatever was
        // dropped there under that name, and to be copied in by the one function that lays out both
        // bundles.
        let icon = Self.repositoryRoot.appendingPathComponent("Resources/AppIcon.icns")
        let data = try Data(contentsOf: icon)
        #expect(data.count > 1024, "AppIcon.icns is too small to hold ten representations")
        #expect(data.prefix(4) == Data("icns".utf8), "AppIcon.icns is not an icns file")

        let script = try Self.text(at: "Scripts/bundle.sh")
        #expect(script.contains("cp \"$ICON\" \"$app_dir/Contents/Resources/AppIcon.icns\""))
        // The build must not depend on an image toolchain: the icns is committed, and make-icon.sh
        // regenerates it from the source image only when the artwork itself changes. What is
        // forbidden is the CALL — bundle.sh names the script in the sentence it prints when the
        // icon is missing, which is the whole point of naming it.
        #expect(!script.contains("bash \"$ROOT/Scripts/make-icon.sh\""),
                "bundle.sh must not regenerate the icon")
        #expect(script.contains("run Scripts/make-icon.sh"),
                "a missing icon must name the script that rebuilds it")
    }

    @Test("the microphone usage description says what it is for and where the audio goes")
    func usageDescription() throws {
        let info = try Self.plist(at: "Resources/Info.plist")
        let description = try #require(info["NSMicrophoneUsageDescription"] as? String)
        // This sentence is the entire TCC prompt below the title, shown once (step 2, criterion d).
        // An empty or placeholder string is a prompt people deny.
        #expect(description.count > 40)
        #expect(description.lowercased().contains("dicta"))
        #expect(description.lowercased().contains("microphone"))
        // English only, no exceptions — SPEC.md names this key explicitly. Scripts/lint.sh greps
        // the repository for Cyrillic; this asserts it for the string most likely to acquire some.
        #expect(!description.contains { ("\u{0400}"..."\u{04FF}").contains(String($0)) })
    }

    @Test("the bundle declares the minimum system it is built against")
    func minimumSystem() throws {
        let info = try Self.plist(at: "Resources/Info.plist")
        #expect(info["LSMinimumSystemVersion"] as? String == "14.0")
        #expect(info["CFBundlePackageType"] as? String == "APPL")
    }

    // MARK: - the entitlements

    @Test("the entitlements grant the microphone and nothing else")
    func entitlements() throws {
        let entitlements = try Self.plist(at: "Resources/Dicta.entitlements")
        #expect(entitlements["com.apple.security.device.audio-input"] as? Bool == true)
        // Sandboxed, the daemon could neither spawn agtermctl nor reach agterm's socket.
        #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == false)
        #expect(entitlements.count == 2,
                "an entitlement was added without a reason: \(entitlements)")
    }

    @Test("bundle.sh signs with the entitlements file and the bundle id, never ad hoc")
    func signingArguments() throws {
        let bundleScript = try Self.text(at: "Scripts/bundle.sh")
        // Since D27 both bundles are signed by one `sign_and_check`, so the entitlements path and
        // the identifier are named at the CALL SITE rather than inline. The property is unchanged
        // and is now two assertions: the daemon is signed with its entitlements and its id, and the
        // function really passes what it was given. `MenuBundleTests` asserts the other call, whose
        // third argument is empty — the UI may not claim audio-input.
        #expect(bundleScript.contains(
            "sign_and_check \"$APP_DIR\" \"$BUNDLE_ID\" \"$ROOT/Resources/Dicta.entitlements\""))
        #expect(bundleScript.contains("--entitlements \"$entitlements\""))
        #expect(bundleScript.contains("--identifier \"$identifier\""))
        #expect(bundleScript.contains("BUNDLE_ID=\"\(Paths.bundleID)\""))
        // `codesign -s -` is the ad-hoc signature whose requirement is a cdhash: it would revoke
        // the microphone grant on every rebuild — the failure this whole task exists to avoid.
        #expect(!bundleScript.contains("--sign -"))
        // And the check that the produced requirement really is identity-based.
        #expect(bundleScript.contains("cdhash"))
        #expect(bundleScript.contains("certificate leaf"))
    }

    @Test("bundle.sh and setup-signing.sh agree on the identity and the keychain")
    func signingIdentityDoesNotDrift() throws {
        // Two files naming the same certificate: if one is renamed, bundle.sh would silently run
        // the one-time setup on every build and then fail to resolve an identity.
        let bundleScript = try Self.text(at: "Scripts/bundle.sh")
        let setupScript = try Self.text(at: "Scripts/setup-signing.sh")
        for line in ["IDENTITY_CN=\"Dicta Local Signing\"",
                     "KEYCHAIN=\"$HOME/Library/Keychains/dicta-codesign.keychain-db\""] {
            #expect(bundleScript.contains(line), "bundle.sh is missing \(line)")
            #expect(setupScript.contains(line), "setup-signing.sh is missing \(line)")
        }
    }

    // MARK: - the LaunchAgent

    @Test("the LaunchAgent template is a well-formed plist with the label the installer boots out")
    func launchAgentPlist() throws {
        let agent = try Self.plist(at: "Scripts/launchagent.plist")
        #expect(agent["Label"] as? String == Paths.bundleID)
        #expect(agent["RunAtLoad"] as? Bool == true)
        #expect(agent["KeepAlive"] as? Bool == true)
    }

    @Test("the LaunchAgent runs the binary inside the signed bundle, not a bare executable")
    func launchAgentRunsTheBundle() throws {
        let agent = try Self.plist(at: "Scripts/launchagent.plist")
        let arguments = try #require(agent["ProgramArguments"] as? [String])
        // A bare .build/release/Dicta would have its microphone grant attributed to whatever
        // launched it (D11) — the bundle would then exist and be bypassed, which is worse than not
        // having built one.
        #expect(arguments == ["__DICTA_APP__/Contents/MacOS/Dicta", "__DICTA_FOCUSED_FIELDS__"])
    }

    @Test("every placeholder in the template is one install.sh substitutes")
    func placeholdersAreSubstituted() throws {
        // launchd expands neither ~ nor $HOME in these keys, so the template ships placeholders. A
        // placeholder nobody replaces would be a literal path in the user's home directory, and
        // the daemon's stderr would vanish into it.
        let template = try Self.text(at: "Scripts/launchagent.plist")
        let renderer = try Self.text(at: "Scripts/render-agent.sh")
        var found: Set<String> = []
        var scanner = template[...]
        while let start = scanner.range(of: "__") {
            let rest = scanner[start.upperBound...]
            guard let end = rest.range(of: "__") else { break }
            found.insert("__" + rest[..<end.lowerBound] + "__")
            scanner = rest[end.upperBound...]
        }
        #expect(found == ["__DICTA_APP__", "__DICTA_LOG__", "__DICTA_FOCUSED_FIELDS__"])
        for placeholder in ["__DICTA_APP__", "__DICTA_LOG__"] {
            #expect(renderer.contains("s|\(placeholder)|"),
                    "render-agent.sh never replaces \(placeholder)")
        }
        // The option's line is replaced WHOLE or deleted, never substituted inside: a value spliced
        // into the string would leave `<string></string>` behind when the option is off.
        #expect(renderer.contains(
            "s|<string>__DICTA_FOCUSED_FIELDS__</string>|<string>--focused-fields</string>|"))
        #expect(renderer.contains("/<string>__DICTA_FOCUSED_FIELDS__<\\/string>/d"))
    }

    /// Runs `executable` with `arguments` from the repository root, and answers its exit status and
    /// standard output.
    static func run(_ executable: String, _ arguments: [String]) throws -> (Int32, Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = repositoryRoot
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    @Test("the agent rendered for both focused-field settings lints, with no empty argument",
          arguments: [false, true])
    func renderedAgentLints(focusedFields: Bool) throws {
        // A home directory with a space, a `|` and a backslash: the characters sed's replacement
        // side and a shell would each mangle differently.
        let app = #"/Users/some one|x\y/Applications/Dicta.app"#
        let log = "/Users/some one/Library/Logs/dicta.log"
        let script = Self.repositoryRoot.appendingPathComponent("Scripts/render-agent.sh").path
        let (status, rendered) = try Self.run(
            "/bin/bash", [script, app, log] + (focusedFields ? ["--focused-fields"] : []))
        #expect(status == 0)

        let file = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("dicta-agent-\(UUID().uuidString.prefix(8)).plist")
        try rendered.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let (lint, _) = try Self.run("/usr/bin/plutil", ["-lint", file.path])
        #expect(lint == 0, "plutil -lint rejected the agent with focusedFields=\(focusedFields)")

        let text = try #require(String(data: rendered, encoding: .utf8))
        #expect(!text.contains("<string></string>"))
        #expect(!text.contains("__DICTA_"))
        let parsed = try PropertyListSerialization.propertyList(from: rendered, format: nil)
        let agent = try #require(parsed as? [String: Any])
        let arguments = try #require(agent["ProgramArguments"] as? [String])
        #expect(arguments == ["\(app)/Contents/MacOS/Dicta"]
            + (focusedFields ? ["--focused-fields"] : []))
        #expect(agent["StandardErrorPath"] as? String == log)
    }

    /// What `agent-seed.sh` is run over: whether the agent being replaced carried the flag (`nil`:
    /// there is no old agent, a first install), and what stands at `setup.json`.
    enum SetupFile: String, CaseIterable, Sendable {
        case absent, readable, unreadable, danglingSymlink
    }

    struct SeedCase: Sendable, CustomTestStringConvertible {
        let oldAgentHadFlag: Bool?
        let setup: SetupFile
        var seeds: Bool { oldAgentHadFlag == true && setup == .absent }
        var testDescription: String {
            let agent = oldAgentHadFlag.map { $0 ? "old agent with the flag" : "old agent without" }
                ?? "no old agent"
            return "\(agent), setup.json \(setup.rawValue)"
        }
    }

    static let seedCases: [SeedCase] = [true, false, nil].flatMap { flag in
        SetupFile.allCases.map { SeedCase(oldAgentHadFlag: flag, setup: $0) }
    }

    @Test("agent-seed.sh keeps --focused-fields only from an old agent with it, and no setup.json",
          arguments: seedCases)
    func agentSeed(_ seedCase: SeedCase) throws {
        let directory = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("dicta seed \(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let agent = directory.appendingPathComponent("old agent.plist")
        let setup = directory.appendingPathComponent("Application Support/setup.json")
        try FileManager.default.createDirectory(
            at: setup.deletingLastPathComponent(), withIntermediateDirectories: false)

        if let hadFlag = seedCase.oldAgentHadFlag {
            // The old agent as the installer really rendered it, not a hand-written imitation.
            let renderer = Self.repositoryRoot
                .appendingPathComponent("Scripts/render-agent.sh").path
            let (status, rendered) = try Self.run(
                "/bin/bash", [renderer, "/Users/some one/Applications/Dicta.app", "/tmp/dicta.log"]
                    + (hadFlag ? ["--focused-fields"] : []))
            try #require(status == 0)
            try rendered.write(to: agent)
        }
        switch seedCase.setup {
        case .absent:
            break
        case .readable:
            let json = #"{"schema": 1, "scope": "agterm-only", "offerSeen": true}"#
            try Data(json.utf8).write(to: setup)
        case .unreadable:
            // Not JSON, and not readable by its owner either: present is present.
            try Data("{not json".utf8).write(to: setup)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: setup.path)
        case .danglingSymlink:
            let gone = directory.appendingPathComponent("gone").path
            try FileManager.default.createSymbolicLink(
                atPath: setup.path, withDestinationPath: gone)
        }

        let script = Self.repositoryRoot.appendingPathComponent("Scripts/agent-seed.sh").path
        let (status, output) = try Self.run("/bin/bash", [script, agent.path, setup.path])
        #expect(status == 0)
        let expected = seedCase.seeds ? "--focused-fields\n" : ""
        #expect(String(decoding: output, as: UTF8.self) == expected)
    }

    @Test("install.sh refuses --focused-fields, names Set Up… and dictactl configure, and seeds")
    func installerRefusesTheFlagAndSeeds() throws {
        let installer = try Self.text(at: "Scripts/install.sh")
        // The refusal is asserted by text, never by running the installer: a refusal that had
        // stopped working would build, sign and replace the live agent from inside a test.
        let arguments = try #require(installer.range(of: #"for argument in "$@"; do"#))
        let refusal = try #require(installer.range(of: "        --focused-fields)\n"))
        let exit = try #require(installer.range(
            of: "exit 2", range: refusal.upperBound..<installer.endIndex))
        let branch = installer[refusal.upperBound..<exit.lowerBound]
        #expect(arguments.upperBound <= refusal.lowerBound)
        #expect(branch.contains("Set Up…"))
        #expect(branch.contains("dictactl configure --scope other-apps"))
        #expect(!installer.contains("FOCUSED_FIELDS"))
        // Unrecognised arguments are refused rather than ignored.
        #expect(installer.contains("install: unknown option $argument"))

        // The seed is decided over the OLD agent, before the new one is written over it, and an
        // empty answer passes no argument at all.
        let setupPath = #"SETUP="$HOME/Library/Application Support/$LABEL/setup.json""#
        #expect(installer.contains(setupPath))
        #expect(installer.contains(#"LABEL="\#(Paths.bundleID)""#))
        #expect(Paths(home: URL(fileURLWithPath: "/h")).setup.path
            == "/h/Library/Application Support/\(Paths.bundleID)/setup.json")
        let seed = try #require(installer.range(
            of: #"SEED="$(bash "$ROOT/Scripts/agent-seed.sh" "$AGENT" "$SETUP")""#))
        let render = #"bash "$ROOT/Scripts/render-agent.sh" "$APP_DEST" "$LOG""#
        let seeded = try #require(installer.range(of: render + #" "$SEED" > "$AGENT""#))
        let unseeded = try #require(installer.range(of: render + #" > "$AGENT""#))
        let guardLine = try #require(installer.range(of: #"if [ -n "$SEED" ]; then"#))
        #expect(seed.upperBound <= guardLine.lowerBound)
        #expect(guardLine.upperBound <= seeded.lowerBound)
        #expect(seeded.upperBound <= unseeded.lowerBound)
        #expect(installer.components(separatedBy: #"> "$AGENT""#).count == 3)

        // The closing steps name the setup window, and no longer send anybody to grant
        // Accessibility by hand: the window asks, after saying why.
        #expect(installer.contains("setup window"))
        #expect(!installer.contains("grant Accessibility"))
    }

    @Test("install.sh prints agterm's keymap step only with agtermctl")
    func installerKeymapStep() throws {
        let installer = try Self.text(at: "Scripts/install.sh")
        // The keymap instruction sits inside the one branch that found agtermctl.
        let guardLine = try #require(installer.range(of: "if [ -n \"$AGTERMCTL\" ]; then"))
        let step = #"echo "  $STEP. add docs/keymap.snippet.conf"#
        let keymap = try #require(installer.range(of: step))
        let closing = try #require(installer.range(
            of: "\nfi\n", range: guardLine.upperBound..<installer.endIndex))
        #expect(guardLine.upperBound <= keymap.lowerBound)
        #expect(keymap.upperBound <= closing.lowerBound)
        let printed = installer.split(separator: "\n").filter {
            $0.contains("echo") && $0.contains("keymap.snippet.conf")
        }
        #expect(printed.count == 1)
    }

    @Test("install.sh installs the bundle and the client, and no bare daemon executable")
    func installerScope() throws {
        let installer = try Self.text(at: "Scripts/install.sh")
        #expect(installer.contains("bash \"$ROOT/Scripts/bundle.sh\""))
        #expect(installer.contains("launchctl bootstrap"))
        #expect(installer.contains("$HOME/.local/bin/dictactl"))
        // Installing the daemon binary on its own would put a TCC-anchorless copy on PATH, and
        // whichever one is running is then a guess. The build product is `Dicta` with a capital D;
        // `.build/release/dictactl` is the client and is expected above.
        #expect(!installer.contains(".build/release/Dicta"))
    }
}
