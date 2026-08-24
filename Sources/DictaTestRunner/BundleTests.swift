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
        #expect(info["CFBundleIconFile"] == nil, "the bundle is not meant to have artwork")
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
        #expect(arguments == ["__DICTA_APP__/Contents/MacOS/Dicta"])
    }

    @Test("every placeholder in the template is one install.sh substitutes")
    func placeholdersAreSubstituted() throws {
        // launchd expands neither ~ nor $HOME in these keys, so the template ships placeholders. A
        // placeholder nobody replaces would be a literal path in the user's home directory, and
        // the daemon's stderr would vanish into it.
        let template = try Self.text(at: "Scripts/launchagent.plist")
        let installer = try Self.text(at: "Scripts/install.sh")
        var found: Set<String> = []
        var scanner = template[...]
        while let start = scanner.range(of: "__") {
            let rest = scanner[start.upperBound...]
            guard let end = rest.range(of: "__") else { break }
            found.insert("__" + rest[..<end.lowerBound] + "__")
            scanner = rest[end.upperBound...]
        }
        #expect(found == ["__DICTA_APP__", "__DICTA_LOG__"])
        for placeholder in found {
            #expect(installer.contains("s|\(placeholder)|"),
                    "install.sh never replaces \(placeholder)")
        }
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
