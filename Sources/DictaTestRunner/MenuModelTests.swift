import DictaCore
import Foundation
import Testing

/// What the menu-bar UI shows, asserted as values (D27, D19).
///
/// The SwiftUI views are not tested and this suite does not pretend otherwise. What IS tested is
/// every decision underneath them, because `DictaMenu` is an executable target that SwiftPM cannot
/// import: a decision written in the view would be unreachable from here, which is precisely why
/// none of them are.
@Suite("menu model")
struct MenuModelTests {
    static let live = StatusSnapshot(state: .recording, readiness: .ready,
                                     speakingSeconds: 10, capSeconds: 600)

    // MARK: - the state acta cannot have

    @Test("a daemon that is not running is never drawn as an idle one")
    func notRunningIsNotIdle() {
        let gone = MenuModel(link: .notRunning)
        let idle = MenuModel(link: .connected, snapshot: StatusSnapshot(state: .idle))
        // `idle` means a chord would work. An absent socket means nothing would happen at all, and
        // drawing the two alike is the silence the whole UI exists to break.
        #expect(gone.presentation.glyph != idle.presentation.glyph)
        #expect(gone.presentation.status != idle.presentation.status)
        #expect(gone.banner?.action == .restartDaemon)
    }

    @Test("a clean shutdown is amber and never says the daemon crashed")
    func endedIsNotACrash() {
        let ended = MenuModel(link: .ended("the daemon is shutting down"))
        let banner = try? #require(ended.banner)
        #expect(banner?.tint == .amber)
        // The false alarm `WatchEvent.end` was added to prevent: an orderly `launchctl bootout`
        // must not put "dicta crashed" in front of the user.
        #expect(banner?.text.contains("crash") == false)
        #expect(ended.banner?.text.contains("stopped") == true)
    }

    @Test("a broken connection is red, and says so")
    func failedIsRed() {
        let failed = MenuModel(link: .failed("dicta is not answering — the socket has no listener"))
        #expect(failed.presentation.tint == .red)
        #expect(failed.banner?.tint == .red)
    }

    @Test("connecting claims nothing")
    func connectingClaimsNothing() {
        let connecting = MenuModel(link: .connecting)
        // Claiming readiness before having asked would be wrong exactly when the answer matters —
        // at login, in the first second, when the user's first chord is about to be pressed.
        #expect(connecting.presentation.status != "Ready")
        #expect(connecting.banner == nil)
    }

    // MARK: - a stale snapshot never survives a lost link

    @Test("a lost connection does not keep drawing a live microphone")
    func staleRecordingIsNotShown() {
        // The dangerous case: the daemon died while recording. Keeping the last snapshot on screen
        // would leave a red "Listening" glyph over a microphone that is not open — a UI confidently
        // wrong about the one thing it exists to report.
        let stale = MenuModel(link: .failed("gone"), snapshot: Self.live, receivedAt: Date())
        #expect(stale.presentation.glyph != Presentation.of(Self.live).glyph)
        #expect(stale.speakingSeconds(at: Date()) == nil)
    }

    // MARK: - banners

    @Test("each blocking readiness gets its own single action")
    func banners() {
        let denied = MenuModel(link: .connected,
                               snapshot: StatusSnapshot(state: .idle,
                                                        readiness: .microphoneDenied))
        #expect(denied.banner?.action == .openMicrophoneSettings)
        let models = MenuModel(link: .connected,
                               snapshot: StatusSnapshot(state: .idle, readiness: .modelsMissing))
        #expect(models.banner?.action == .fetchModels)
        // `agtermctl` missing has no button: nothing the panel could run would install it, and a
        // button that does nothing is worse than none.
        let terminal = MenuModel(link: .connected,
                                 snapshot: StatusSnapshot(state: .idle,
                                                          readiness: .terminalMissing))
        #expect(terminal.banner != nil)
        #expect(terminal.banner?.action == nil)
    }

    @Test("a missing agterm with focused fields on is an amber notice, and without them a fault")
    func fieldsOnlyBannerIsANotice() throws {
        let notice = MenuModel(link: .connected,
                               snapshot: StatusSnapshot(state: .idle, readiness: .fieldsOnly))
        let banner = try #require(notice.banner)
        #expect(banner.tint == .amber)
        #expect(banner.action == nil)
        #expect(banner.text.contains("agtermctl"))
        let fault = MenuModel(link: .connected,
                              snapshot: StatusSnapshot(state: .idle, readiness: .terminalMissing))
        #expect(fault.banner?.tint == .red)
    }

    @Test("a banner is red only for a fault, and a setup step is amber with Set Up")
    func setupStepBannersAreAmber() throws {
        for readiness in Readiness.allCases {
            let model = MenuModel(link: .connected,
                                  snapshot: StatusSnapshot(state: .idle, readiness: readiness))
            guard let banner = model.banner else {
                #expect(readiness.message == nil, "\(readiness) has a message and no banner")
                continue
            }
            #expect(banner.tint == (readiness.isFault ? .red : .amber), "\(readiness)")
        }
        for readiness in [Readiness.setupNeeded, .accessibilityNeeded, .accessibilityForFields] {
            let model = MenuModel(link: .connected,
                                  snapshot: StatusSnapshot(state: .idle, readiness: readiness))
            let banner = try #require(model.banner)
            #expect(banner.tint == .amber)
            #expect(banner.action == .openSetup)
            #expect(banner.actionTitle == "Set Up…")
        }
        // No other verdict opens the window: a fault names its own fix, and `fieldsOnly` has none.
        for readiness in [Readiness.microphoneDenied, .modelsMissing, .terminalMissing,
                          .fieldsOnly] {
            let model = MenuModel(link: .connected,
                                  snapshot: StatusSnapshot(state: .idle, readiness: readiness))
            #expect(model.banner?.action != .openSetup)
        }
    }

    @Test("a healthy daemon shows no banner at all")
    func healthyHasNoBanner() {
        let ready = MenuModel(link: .connected,
                              snapshot: StatusSnapshot(state: .idle, readiness: .ready))
        #expect(ready.banner == nil)
        // Nor while starting: two red banners every morning is how a red banner stops meaning
        // anything.
        let starting = MenuModel(link: .connected,
                                 snapshot: StatusSnapshot(state: .idle, readiness: .starting))
        #expect(starting.banner == nil)
    }

    // MARK: - the menu bar itself

    @Test("the menu bar shows a clock only while the microphone is open")
    func barTimerOnlyWhileRecording() {
        let received = Date()
        let recording = MenuModel(link: .connected, snapshot: Self.live, receivedAt: received)
        #expect(recording.barLabel(at: received).timer == "0:10")
        // Every other state shows the glyph alone. `warming` is the one that matters: a clock is an
        // announcement, and D13 forbids announcing an open microphone before capture confirms it.
        for state in [LifecycleState.idle, .warming, .processing, .injecting] {
            let model = MenuModel(link: .connected,
                                  snapshot: StatusSnapshot(state: state, speakingSeconds: 10,
                                                           capSeconds: 600),
                                  receivedAt: received)
            #expect(model.barLabel(at: received).timer == nil)
        }
        // Nor over a link that is down — the same rule the panel's timer follows, for the same
        // reason: a clock ticking over a daemon nobody can reach is counting a dictation that may
        // have ended minutes ago.
        let stale = MenuModel(link: .failed("gone"), snapshot: Self.live, receivedAt: received)
        #expect(stale.barLabel(at: received).timer == nil)
    }

    @Test("the clock counts on in the menu bar, since the daemon sends nothing while you speak")
    func barTimerExtrapolates() {
        let received = Date()
        let model = MenuModel(link: .connected, snapshot: Self.live, receivedAt: received)
        #expect(model.barLabel(at: received.addingTimeInterval(51)).timer == "1:01")
        // Truncated rather than rounded: a clock reading 0:11 before eleven seconds of speech had
        // happened would claim audio that is not in the buffer.
        #expect(model.barLabel(at: received.addingTimeInterval(0.9)).timer == "0:10")
    }

    @Test("the last minute turns the digits amber and leaves the glyph red")
    func barTimerWarnsWithoutLying() {
        let received = Date()
        let late = StatusSnapshot(state: .recording, speakingSeconds: 550, capSeconds: 600)
        let model = MenuModel(link: .connected, snapshot: late, receivedAt: received)
        let label = model.barLabel(at: received)
        #expect(label.timerTint == .amber)
        // Red means "the microphone is open" across this whole family, and it must go on meaning
        // that for the last minute of an attempt. A strip where red comes and goes while the device
        // is still live is a worse instrument than one with no cap warning in it at all.
        #expect(label.tint == .red)
        #expect(label.glyph == Presentation.of(late).glyph)
    }

    @Test("an idle menu bar is the glyph alone, in the colour the panel would agree with")
    func barIsQuietWhenIdle() {
        let now = Date()
        for link in [DaemonLink.connecting, .notRunning, .ended("stopped"), .failed("gone")] {
            let label = MenuModel(link: link).barLabel(at: now)
            #expect(label.timer == nil)
            // One state, drawn twice, cannot disagree with itself: the strip and the header read
            // the same `presentation`.
            #expect(label.glyph == MenuModel(link: link).presentation.glyph)
            #expect(label.tint == MenuModel(link: link).presentation.tint)
        }
    }

    // MARK: - the timer

    @Test("the timer counts on between events, because the daemon sends none while you speak")
    func timerExtrapolates() {
        let received = Date()
        let model = MenuModel(link: .connected, snapshot: Self.live, receivedAt: received)
        // The daemon publishes on TRANSITIONS. Speaking is not a transition, so nothing arrives for
        // the whole dictation and the seconds have to be counted locally from the last figure.
        let seconds = try? #require(model.speakingSeconds(at: received.addingTimeInterval(5)))
        #expect(seconds == 15)
    }

    @Test("there is no timer unless the microphone is actually open")
    func timerOnlyWhileRecording() {
        for state in [LifecycleState.idle, .warming, .processing, .injecting] {
            let model = MenuModel(link: .connected,
                                  snapshot: StatusSnapshot(state: state, speakingSeconds: 10,
                                                           capSeconds: 600),
                                  receivedAt: Date())
            // `warming` especially: D13 and invariant 4 say nothing announces an open microphone
            // before capture confirms, and a running clock is an announcement.
            #expect(model.speakingSeconds(at: Date()) == nil, "\(state.rawValue) showed a timer")
        }
    }

    @Test("the last minute before the cap reads as urgent")
    func nearCapIsUrgent() {
        let received = Date()
        let model = MenuModel(link: .connected,
                              snapshot: StatusSnapshot(state: .recording, speakingSeconds: 545,
                                                       capSeconds: 600),
                              receivedAt: received)
        // D15's cap stops the attempt and injects NOTHING. A user nine minutes into a dictation has
        // no other way to know it is about to be thrown away.
        #expect(model.isNearCap(at: received))
        let early = MenuModel(link: .connected,
                              snapshot: StatusSnapshot(state: .recording, speakingSeconds: 10,
                                                       capSeconds: 600),
                              receivedAt: received)
        #expect(!early.isNearCap(at: received))
    }

    // MARK: - reconnecting

    @Test("the backoff grows and is bounded")
    func backoffIsBounded() {
        #expect(Backoff.delay(afterFailures: 0) == Backoff.first)
        #expect(Backoff.delay(afterFailures: 1) > Backoff.delay(afterFailures: 0))
        // Bounded, so the glyph comes back within seconds of the daemon returning — the user should
        // never have to think about the UI — while a laptop is not spending its battery announcing
        // that it is worried.
        #expect(Backoff.delay(afterFailures: 50) == Backoff.ceiling)
        for failures in 0 ... 50 {
            #expect(Backoff.delay(afterFailures: failures) <= Backoff.ceiling)
        }
    }
}
