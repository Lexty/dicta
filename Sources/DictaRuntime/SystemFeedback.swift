import AppKit
import DictaCore
import Foundation

// Feedback where there is no agterm to give it (D13, D31): a focused-field target has no session
// indicator, and a daemon started without `agtermctl` has nobody to ask for one.
//
// What is left is what F11 measured from the LaunchAgent: `NSSound` plays with no `NSApplication`,
// and an `osascript` notification is shown -- except under a Focus mode, where the sound is the
// only signal that reaches the user. Neither needs a permission, so constructing this asks for
// nothing.

/// A named system sound, behind a seam so a test can hear what was played without a speaker.
public protocol SoundPlayer: Sendable {
    func play(_ name: String)
}

/// The real one. `NSSound(named:)` keeps the sound it finds in its own registry, so the object
/// outlives this call and plays to the end.
public struct SystemSoundPlayer: SoundPlayer {
    public init() {}

    public func play(_ name: String) {
        _ = NSSound(named: NSSound.Name(name))?.play()
    }
}

/// A desktop notification through `osascript`, the one mechanism both notifiers share: agterm's
/// fallback when agterm cannot show one, and `SystemFeedback`'s only road.
///
/// One builder, so the escaping cannot drift between the two: a message that breaks out of the
/// AppleScript string is a notification lost on exactly the paths §7 says nobody is watching.
public enum ScriptNotification {
    public static let executable = "/usr/bin/osascript"

    public static func arguments(_ message: String) -> [String] {
        ["-e", "display notification \(quoted(message)) with title \"dicta\""]
    }

    /// An AppleScript string literal. The line breaks matter: a raw newline inside one is a syntax
    /// error, so a multi-line reason -- agtermctl's stderr, most of the time -- would lose the
    /// notification on the very path that exists because agterm is already broken.
    public static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}

/// §6's feedback with no indicator: agterm's own three sounds, and notifications.
///
/// It answers for every target alike, because it has nothing to aim: which attempts reach it is the
/// daemon's routing, not a decision made here. `working` is silent, as it is in agterm, where it is
/// a colour and nothing else.
public struct SystemFeedback: Notifier {
    /// How many `osascript` calls ONE `stop` of a focused-field attempt can make through this
    /// notifier, worst case: the field path's counterpart of
    /// `ProcessRunner.worstCaseCallsPerStop`. A sound is not a subprocess and is not counted.
    ///
    ///  1. the dictionary's degradation notice
    ///  2. the filter's fallback notice
    ///  3. the delivery failure's notice
    ///  4. the record's "recovery is unavailable" notice
    public static let worstCaseCallsPerStop = 4

    private let sounds: any SoundPlayer
    private let runner: any CommandRunner

    public init(sounds: any SoundPlayer = SystemSoundPlayer(),
                runner: any CommandRunner = ProcessRunner()) {
        self.sounds = sounds
        self.runner = runner
    }

    /// The sound for a state, and the same one agterm's indicator carries for it
    /// (`Agterm.statusArguments`), so a user who dictates in both places hears one vocabulary.
    public static func sound(for feedback: Feedback) -> String? {
        switch feedback {
        case .listening: "Pop"
        case .working: nil
        case .done: "Tink"
        case .blocked: "Basso"
        }
    }

    public func announce(_ feedback: Feedback, for target: Target) {
        guard let name = Self.sound(for: feedback) else { return }
        sounds.play(name)
    }

    public func notify(_ message: String, for target: Target?) {
        _ = try? runner.run(ScriptNotification.executable, ScriptNotification.arguments(message))
    }

    /// Nothing is lit, so nothing is put out.
    public func clearIndicator(for target: Target) {}
}
