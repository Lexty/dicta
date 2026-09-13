import DictaCore
import Foundation
import Testing

/// The menu-bar bundle (D27), asserted the same way `BundleTests` asserts the daemon's: by reading
/// the files `Scripts/bundle.sh` and `Scripts/install.sh` actually ship.
///
/// The reason this suite exists is narrower than "the plist should be right". Three of the
/// properties below have no other guard anywhere, and each one fails silently rather than loudly:
///
///  * **A shared identifier.** Two bundles claiming `dev.personal.dicta` is how a TCC grant gets
///    attributed to whichever one macOS saw last — D11's failure arriving through a door D11 never
///    described. Nothing at build time notices; the symptom is a microphone prompt weeks later.
///  * **A microphone usage description on the UI.** Its presence would let this bundle *ask*, and a
///    second binary that can open the device is exactly what invariant 8 forbids. An absent key
///    cannot be tested by looking at it, only by asserting it stays absent.
///  * **Entitlements copied over from the daemon.** `com.apple.security.device.audio-input` on the
///    UI would be the same failure spelled in the other file. `bundle.sh` passes the menu an empty
///    entitlements argument on purpose, and that is a line a refactor would tidy away.
///
/// What this does not do, deliberately, is run `codesign` — same reasoning as `BundleTests`: that
/// check lives in `bundle.sh`, which now applies it to both bundles through one function.
@Suite("menu bundle")
struct MenuBundleTests {
    // MARK: - Info.plist

    @Test("DictaMenu-Info.plist is a well-formed plist")
    func menuPlistParses() throws {
        let info = try BundleTests.plist(at: "Resources/DictaMenu-Info.plist")
        #expect(!info.isEmpty)
    }

    @Test("the menu has its own identity, and it is NOT the daemon's")
    func menuIdentifierIsDistinct() throws {
        let info = try BundleTests.plist(at: "Resources/DictaMenu-Info.plist")
        let identifier = try #require(info["CFBundleIdentifier"] as? String)
        #expect(identifier == "dev.personal.dicta.menu")
        // The load-bearing half. `Paths.bundleID` is the daemon's, and the socket, the record and
        // the microphone grant all sit under it; a UI sharing it would be a second bundle claiming
        // the identity a TCC grant is recorded against.
        #expect(identifier != Paths.bundleID)
    }

    @Test("the menu bundle cannot ask for the microphone")
    func menuHasNoMicrophoneUsageDescription() throws {
        let info = try BundleTests.plist(at: "Resources/DictaMenu-Info.plist")
        // macOS shows this string in the TCC prompt. A bundle without it cannot prompt at all — the
        // request fails instead — which is the desired outcome for a binary that must never open
        // the device (D11, invariant 8). `Scripts/linkage.sh` asserts it cannot; this asserts it
        // may not.
        #expect(info["NSMicrophoneUsageDescription"] == nil)
    }

    @Test("the menu has no dock icon")
    func menuIsAnAgent() throws {
        let info = try BundleTests.plist(at: "Resources/DictaMenu-Info.plist")
        // A dock tile would put a dictation one stray click away from stealing focus from the
        // terminal it is about to type into, and would make agterm stop being frontmost — which
        // under D22 silences the hold key.
        #expect(info["LSUIElement"] as? Bool == true)
    }

    @Test("the menu wears the daemon's icon rather than one of its own")
    func menuSharesTheDaemonIcon() throws {
        let info = try BundleTests.plist(at: "Resources/DictaMenu-Info.plist")
        // One tool in two processes. The daemon is met in the Privacy list and the menu in Finder,
        // and a second drawing would be a distinction with nothing behind it. This is NOT the
        // menu-bar glyph: that is an SF Symbol picked per state in `Presentation`, since a menu bar
        // renders a template symbol and not artwork.
        #expect(info["CFBundleIconFile"] as? String == "AppIcon")
    }

    @Test("the executable key names what bundle.sh copies in")
    func menuExecutableName() throws {
        let info = try BundleTests.plist(at: "Resources/DictaMenu-Info.plist")
        #expect(info["CFBundleExecutable"] as? String == "DictaMenu")
        let script = try BundleTests.text(at: "Scripts/bundle.sh")
        #expect(script.contains("MENU_APP_NAME=\"DictaMenu\""))
        #expect(script.contains("MENU_BIN=\"$ROOT/.build/release/DictaMenu\""))
    }

    // MARK: - Signing

    @Test("bundle.sh signs the menu with the daemon's identity and NO entitlements")
    func menuIsSignedWithoutEntitlements() throws {
        let script = try BundleTests.text(at: "Scripts/bundle.sh")
        // The empty third argument is the whole assertion: entitlements are claims a binary makes
        // about itself, and handing the UI the daemon's file would have it claiming audio-input.
        #expect(script.contains("sign_and_check \"$MENU_APP_DIR\" \"$MENU_BUNDLE_ID\" \"\""))
        #expect(script.contains(
            "sign_and_check \"$APP_DIR\" \"$BUNDLE_ID\" \"$ROOT/Resources/Dicta.entitlements\""))
        // Both bundles go through one function, so the identity-based-requirement check cannot hold
        // for one and quietly not for the other.
        #expect(script.contains("that is an ad-hoc signature"))
    }

    // MARK: - The LaunchAgent

    @Test("the menu's agent runs the binary inside its own signed bundle")
    func menuAgentRunsTheBundle() throws {
        let agent = try BundleTests.plist(at: "Scripts/menu-launchagent.plist")
        let arguments = try #require(agent["ProgramArguments"] as? [String])
        #expect(arguments == ["__DICTA_MENU_APP__/Contents/MacOS/DictaMenu"])
        #expect(agent["Label"] as? String == "dev.personal.dicta.menu")
        #expect(agent["RunAtLoad"] as? Bool == true)
        #expect(agent["KeepAlive"] as? Bool == true)
    }

    @Test("the menu's agent claims no scheduling priority")
    func menuAgentIsNotInteractive() throws {
        let agent = try BundleTests.plist(at: "Scripts/menu-launchagent.plist")
        // The daemon declares `Interactive` because a human waits on its keypress path (F4).
        // Nothing waits on the UI — D27 says it is never on the attempt path — so asking launchd to
        // prefer it would be asking launchd to prefer the menu over the thing the menu is about.
        #expect(agent["ProcessType"] == nil)
    }

    @Test("every placeholder in the menu's template is one install.sh substitutes")
    func menuPlaceholdersAreSubstituted() throws {
        let template = try BundleTests.text(at: "Scripts/menu-launchagent.plist")
        let installer = try BundleTests.text(at: "Scripts/install.sh")
        var found: Set<String> = []
        var scanner = template[...]
        while let start = scanner.range(of: "__") {
            let rest = scanner[start.upperBound...]
            guard let end = rest.range(of: "__") else { break }
            found.insert("__" + rest[..<end.lowerBound] + "__")
            scanner = rest[end.upperBound...]
        }
        #expect(found == ["__DICTA_MENU_APP__"])
        for placeholder in found {
            #expect(installer.contains("s|\(placeholder)|"),
                    "install.sh never replaces \(placeholder)")
        }
    }

    // MARK: - The installer

    @Test("install.sh installs the menu bundle and loads its agent")
    func installerCoversTheMenu() throws {
        let installer = try BundleTests.text(at: "Scripts/install.sh")
        #expect(installer.contains("install_bundle \"$ROOT/DictaMenu.app\" \"$MENU_APP_DEST\""))
        #expect(installer.contains("reload_agent \"$MENU_LABEL\" \"$MENU_AGENT\""))
        // Both agents go through one `reload_agent`, so the bootout/bootstrap race the daemon's
        // install learned about on 2026-08-16 cannot be half-fixed for the second one.
        #expect(installer.contains("reload_agent \"$LABEL\" \"$AGENT\""))
        // The UI is removable. If this ever becomes a hard dependency of the daemon's install,
        // D27's "the UI's absence changes no outcome" has stopped being true.
        #expect(!installer.contains("DictaMenu.app/Contents/MacOS/Dicta\""))
    }

    // MARK: - The linkage budget

    @Test("linkage.sh scores the menu, and forbids it the capture stack")
    func linkageCoversTheMenu() throws {
        let script = try BundleTests.text(at: "Scripts/linkage.sh")
        #expect(script.contains("--menu"))
        #expect(script.contains("MENU_FORBIDDEN='AVFAudio|AVFoundation|CoreML|FluidAudio'"))
        // The one difference from `dictactl`'s rules, written down rather than inferred.
        #expect(script.contains("AppKit is absent from the list on purpose"))
        // The menu is held to the daemon's full keystroke rule, not a weakened one — measured, see
        // the comment in the script.
        #expect(script.contains("check_keystrokes \"$MENU\" \"the UI\""))
        // Built by default, not only when asked for: a check that runs only under a flag is a check
        // that stops running.
        #expect(script.contains("swift build --product DictaMenu"))
    }

    @Test("linkage.sh forbids the client and the menu posting keystrokes or reading accessibility")
    func linkageForbidsPostingOutsideTheDaemon() throws {
        let script = try BundleTests.text(at: "Scripts/linkage.sh")
        // Invariant 14's "never by dictactl or the menu-bar UI" is a property of the linked
        // binaries, so the script's row is the whole check; losing it loses the clause silently.
        #expect(script.contains(
            "POSTING='CGEventPost|CGEventPostToPid|CGEventKeyboardSetUnicodeString|"
                + "AXUIElementCreateSystemWide|AXUIElementCopyAttributeValue'"
        ))
        #expect(script.contains("check_posting \"$BINARY\""))
        #expect(script.contains("check_posting \"$MENU\""))
        // Never on the daemon: it posts by design when the option is on.
        #expect(!script.contains("check_posting \"$DAEMON\""))
    }
}
