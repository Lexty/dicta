import DictaCore
import DictaRuntime
import Foundation
import Testing

/// Feedback with no agterm (D13, D31): the three sounds and an `osascript` notification, driven
/// through a recording sound player and the agterm suite's recording runner.
///
/// What only a person can score -- that the sound is heard from the LaunchAgent, that the
/// notification is shown, and that a Focus mode leaves the sound alone -- is F11's and H28 (e)'s.
@Suite("system feedback")
struct SystemFeedbackTests {
    typealias StubRunner = AgtermTests.StubRunner

    static let field = Target.focusedField(
        FieldTarget(bundleID: "com.microsoft.VSCode", appName: "Code", pid: 4242))

    static func feedback() -> (SystemFeedback, FakeSoundPlayer, StubRunner) {
        let sounds = FakeSoundPlayer()
        let runner = StubRunner { _ in CommandOutput(status: 0) }
        return (SystemFeedback(sounds: sounds, runner: runner), sounds, runner)
    }

    @Test("listening plays Pop, done plays Tink, and working is silent")
    func eachStatePlaysAgtermsOwnSound() {
        let (feedback, sounds, runner) = Self.feedback()

        feedback.announce(.listening, for: Self.field)
        feedback.announce(.working, for: Self.field)
        feedback.announce(.done, for: Self.field)

        // The same vocabulary agterm's indicator carries, so a user who dictates in both places
        // hears one set of sounds rather than two.
        #expect(sounds.played == ["Pop", "Tink"])
        // A sound is not a notification: nothing was posted.
        #expect(runner.invocations.isEmpty)
    }

    @Test("a failure plays Basso and notifies through osascript")
    func aFailurePlaysBassoAndNotifies() throws {
        let (feedback, sounds, runner) = Self.feedback()

        feedback.announce(.blocked, for: Self.field)
        feedback.notify("nothing was inserted", for: Self.field)

        #expect(sounds.played == ["Basso"])
        let invocation = try #require(runner.invocations.first)
        #expect(runner.invocations.count == 1)
        #expect(invocation.executable == "/usr/bin/osascript")
        #expect(invocation.arguments
            == ["-e", #"display notification "nothing was inserted" with title "dicta""#])
    }

    @Test("an untargeted refusal is notified too, with no sound of its own")
    func anUntargetedNotificationIsPosted() {
        let (feedback, sounds, runner) = Self.feedback()

        feedback.notify("start needs agterm", for: nil)

        #expect(runner.invocations.map(\.executable) == ["/usr/bin/osascript"])
        #expect(sounds.played.isEmpty)
    }

    @Test("clearing the indicator does nothing, because nothing is lit")
    func clearIndicatorIsANoOp() {
        let (feedback, sounds, runner) = Self.feedback()

        feedback.clearIndicator(for: Self.field)
        feedback.clearIndicator(for: Target(sessionID: "S1", pane: .left))

        #expect(sounds.played.isEmpty)
        #expect(runner.invocations.isEmpty)
    }

    @Test("quotes, backslashes and a multi-line reason stay inside the osascript string")
    func notificationTextIsEscaped() throws {
        let (feedback, _, runner) = Self.feedback()
        let reason = "line one\nsaid \"no\" \\ then\r\nline three"

        feedback.notify(reason, for: nil)

        let script = try #require(runner.invocations.first?.arguments.last)
        // A raw line break inside an AppleScript string is a syntax error, and a quote that is not
        // escaped ends the string: either loses the notification on the path nobody is watching.
        #expect(script == #"display notification "line one\nsaid \"no\" \\ then\r\nline three""#
            + #" with title "dicta""#)
        #expect(!script.contains("\n"))
        #expect(!script.contains("\r"))
    }

    @Test("agterm's fallback and system feedback post the same notification")
    func bothNotifiersShareOneBuilder() throws {
        // One builder, so the escaping above cannot hold for one notifier and drift for the other.
        let reason = "a \"quoted\"\nreason"
        let failing = StubRunner { _ in CommandOutput(status: 1) }
        Agterm(executable: "/opt/homebrew/bin/agtermctl", runner: failing).notify(reason, for: nil)
        let (feedback, _, runner) = Self.feedback()
        feedback.notify(reason, for: nil)

        let fallback = try #require(failing.invocations.last)
        let posted = try #require(runner.invocations.first)
        #expect(fallback.executable == posted.executable)
        #expect(fallback.arguments == posted.arguments)
        #expect(posted.arguments == ScriptNotification.arguments(reason))
    }
}
