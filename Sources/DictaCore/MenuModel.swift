import Foundation

// What the menu-bar UI shows, as a value (D27, D19).
//
// The SwiftUI view is wiring: it turns this into pixels and does nothing else. Everything that
// could be wrong — which glyph, which banner, whether the daemon is merely idle or actually gone,
// how long to wait before reconnecting — is decided here, where a test can reach it. `DictaMenu` is
// an executable target and SwiftPM cannot import one, so a decision written there would be
// unreachable from the runner; the same argument that put `ClientCommand` and `Presentation` here.

/// What the UI knows about its connection to the daemon.
///
/// **`notRunning` is not a kind of `idle`, and that distinction is the whole reason this exists.**
/// `idle` means a chord would work. An absent socket means nothing would happen at all, and drawing
/// the two the same way is the silence the UI was built to break. acta has no equivalent because
/// acta's menu *is* its daemon; here they are two processes (D27).
public enum DaemonLink: Sendable, Equatable {
    /// Trying to reach the daemon, and nothing is known yet. The first instant after login.
    case connecting
    /// A stream is open. `snapshot` is current.
    case connected
    /// There is no socket at all: the daemon was never started, or was stopped deliberately. No
    /// launch-on-demand — an absent socket means "not running", which is the rule acta wrote into
    /// `actactl`'s constraints too.
    case notRunning
    /// The daemon ended the stream on purpose, saying why. A clean shutdown, NOT a crash: the
    /// difference is the whole reason `WatchEvent.end` exists, and reporting it as a crash would be
    /// the false alarm the UI is supposed to avoid raising.
    case ended(String)
    /// The connection broke, or the daemon refused. Something is wrong and the user may need to
    /// know.
    case failed(String)
}

/// One line of trouble, with the single thing that would fix it.
public struct Banner: Sendable, Equatable {
    /// What the button does. `nil` for a banner that only reports — used sparingly, because a
    /// banner with nothing to do about it is a banner that gets dismissed and then ignored.
    public enum Action: String, Sendable, Equatable {
        /// Opens System Settings at Privacy & Security > Microphone.
        case openMicrophoneSettings
        /// Runs `Dicta --fetch-models`, the one long-running thing the panel owns.
        case fetchModels
        /// `launchctl kickstart -k` on the daemon's label.
        case restartDaemon
    }

    public var text: String
    public var tint: Tint
    public var action: Action?
    public var actionTitle: String?

    public init(text: String, tint: Tint, action: Action? = nil, actionTitle: String? = nil) {
        self.text = text
        self.tint = tint
        self.action = action
        self.actionTitle = actionTitle
    }
}

// There WAS a `dismissible` flag here, and it is gone rather than kept for later. Nothing ever set
// it: it existed for the "the last dictation did not land" banner, which became a line on the row
// that failed instead (`DictationRow.reason`). A field that looks like a feature and is written by
// nobody is worse than an absent one — it reads as implemented to everybody who greps for it, which
// is how the checkbox that asked for that banner came to be ticked over code that had none.
//
// The reason a fault banner needs no dismissal either: every banner this panel can show is a
// CURRENT condition — no daemon, no models, no microphone — so dismissing one would only hide
// something still true, and it would come straight back. A banner that reappears teaches people to
// stop reading banners.

/// Everything the panel and the glyph render, derived from the connection and the last snapshot.
public struct MenuModel: Sendable, Equatable {
    public var link: DaemonLink
    /// The last state the daemon reported. Kept across a lost connection so the panel can say what
    /// it last knew rather than blanking — but `presentation` ignores it when the link is down,
    /// because a stale "Listening" would be a lie about an open microphone.
    public var snapshot: StatusSnapshot?
    /// When `snapshot` arrived, so a running timer can be extrapolated between events. The daemon
    /// sends nothing while the user is speaking — there is no transition to send — so the seconds
    /// have to be counted locally from the last known figure.
    public var receivedAt: Date?

    public init(link: DaemonLink = .connecting, snapshot: StatusSnapshot? = nil,
                receivedAt: Date? = nil) {
        self.link = link
        self.snapshot = snapshot
        self.receivedAt = receivedAt
    }

    /// The glyph, its tint and the sentence under the app name.
    public var presentation: Presentation {
        switch link {
        case .connected:
            guard let snapshot else { return Presentation.connecting }
            return Presentation.of(snapshot)
        case .connecting:
            return Presentation.connecting
        case .notRunning, .ended:
            return Presentation.daemonNotRunning
        case .failed:
            return Presentation.unreachable
        }
    }

    /// The banner, when there is one. At most one: the panel has room for a single sentence with a
    /// single button, and choosing between two of them in the view is a choice no test could reach.
    public var banner: Banner? {
        switch link {
        case .notRunning:
            return Banner(
                text: "dicta is not running — no control socket. The chords will do nothing.",
                tint: .red,
                action: .restartDaemon,
                actionTitle: "Start dicta"
            )
        case let .ended(reason):
            // A clean shutdown. Amber rather than red: nothing is broken, the daemon was asked to
            // stop, and saying "dicta crashed" about `launchctl bootout` is the exact false alarm
            // `WatchEvent.end` was added to prevent.
            return Banner(text: "dicta stopped: \(reason)", tint: .amber,
                          action: .restartDaemon, actionTitle: "Start dicta")
        case let .failed(reason):
            return Banner(text: reason, tint: .red, action: .restartDaemon,
                          actionTitle: "Restart dicta")
        case .connecting:
            return nil
        case .connected:
            guard let message = snapshot?.readiness.message else { return nil }
            // A notice is amber, a fault is red: `fieldsOnly` is a working daemon telling the user
            // where its words can and cannot go, and red would say something is broken.
            let tint: Tint = snapshot?.readiness.blocksDictation == true ? .red : .amber
            return Banner(text: message, tint: tint,
                          action: Self.action(for: snapshot?.readiness),
                          actionTitle: Self.actionTitle(for: snapshot?.readiness))
        }
    }

    /// What the MENU BAR ITSELF draws — the one part of this UI the user does not have to open.
    ///
    /// The reason it exists is a finding rather than a preference (2026-08-24, the user, watching
    /// the installed build): **`mic` → `mic.fill` is not distinguishable without looking for it.**
    /// Peripheral vision reads shape and movement; it does not read a fill inside an unchanged
    /// silhouette of unchanged width. So the glyph was passive and always visible, as §5.2
    /// promised, and still failed the one job it had.
    ///
    /// A running clock beside it changes the WIDTH of the item, which shifts every icon to its
    /// left. That is a change peripheral vision does read, it costs no animation, and it puts the
    /// timer where the user actually is — the panel's copy of it is only ever seen by someone who
    /// opened the panel, which during a dictation is nobody, because during a dictation the focus
    /// is in the pane being dictated into.
    ///
    /// The other half of the finding is the sharper one and it is what makes this dicta's job
    /// rather than the system's: **macOS's own microphone indicator says "some app has the
    /// microphone", not "dicta is recording"**. With anything else on the machine holding the
    /// device, it is lit for a reason that has nothing to do with this attempt. Disambiguating that
    /// is something only dicta's own item can do.
    public func barLabel(at now: Date) -> BarLabel {
        let presentation = presentation
        guard let seconds = speakingSeconds(at: now) else {
            return BarLabel(glyph: presentation.glyph, tint: presentation.tint)
        }
        return BarLabel(
            glyph: presentation.glyph,
            // The GLYPH stays red for the whole recording, and only the digits go amber. Red means
            // "the microphone is open" across this family, and it must not stop meaning that for
            // the last minute of an attempt — a strip where red comes and goes while the device is
            // still live is a worse instrument than one with no warning in it at all.
            tint: presentation.tint,
            timer: Duration.clock(seconds),
            timerTint: isNearCap(at: now) ? .amber : .red
        )
    }

    /// Seconds of speech as of `now`, extrapolated from the last snapshot.
    ///
    /// `nil` unless the microphone is actually open. Counted from `speakingSeconds`, which the
    /// daemon measures from the moment capture CONFIRMED (D13) — so the timer never claims to have
    /// been recording during the ~95 ms before the device was live.
    public func speakingSeconds(at now: Date) -> Double? {
        guard link == .connected,
              let snapshot, snapshot.state == .recording,
              let base = snapshot.speakingSeconds, let receivedAt else { return nil }
        return base + now.timeIntervalSince(receivedAt)
    }

    /// Whether the timer should read as urgent: D15's cap is close enough to lose a dictation to.
    ///
    /// The cap stops the attempt and injects NOTHING, so arriving at it is not a small thing — and
    /// a user who has been speaking for nine minutes has no other way to know.
    public func isNearCap(at now: Date, warning: Double = 60) -> Bool {
        guard let seconds = speakingSeconds(at: now),
              let cap = snapshot?.capSeconds else { return false }
        return cap - seconds <= warning
    }

    private static func action(for readiness: Readiness?) -> Banner.Action? {
        switch readiness {
        case .microphoneDenied: .openMicrophoneSettings
        case .modelsMissing: .fetchModels
        default: nil
        }
    }

    private static func actionTitle(for readiness: Readiness?) -> String? {
        switch readiness {
        case .microphoneDenied: "Open Settings"
        case .modelsMissing: "Fetch Models…"
        default: nil
        }
    }
}

/// The menu-bar item: a glyph, and — only while the microphone is open — a clock beside it.
public struct BarLabel: Sendable, Equatable {
    public var glyph: String
    public var tint: Tint
    /// `0:42`, or `nil` when the item is the glyph alone.
    ///
    /// Present under exactly the same condition as the panel's timer, which is `speakingSeconds`
    /// being non-nil: connected, recording, and counted from the instant capture CONFIRMED. It is
    /// therefore absent through `warming`, and that is D13 and invariant 4 reaching the menu bar —
    /// a clock is an announcement, and a user who starts speaking to one that began before the
    /// device was live loses the first syllable every time.
    public var timer: String?
    /// The digits' colour: red while recording, amber inside the last minute before D15's cap.
    public var timerTint: Tint

    public init(glyph: String, tint: Tint, timer: String? = nil, timerTint: Tint = .red) {
        self.glyph = glyph
        self.tint = tint
        self.timer = timer
        self.timerTint = timerTint
    }
}

/// How long to wait before trying the socket again.
///
/// Bounded and backing off, because the common reason to be disconnected is the ordinary one — the
/// daemon is being reinstalled, or the machine just woke — and a UI reconnecting in a tight loop
/// would spend a laptop's battery announcing that it is worried. The ceiling is low enough that the
/// glyph comes back on its own within seconds of the daemon returning, which is what stops the user
/// having to think about the UI at all.
public enum Backoff {
    public static let first: TimeInterval = 0.5
    public static let ceiling: TimeInterval = 5.0

    /// The delay after `failures` consecutive failed attempts. `0` failures is the first retry.
    public static func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return first }
        let doubled = first * pow(2, Double(min(failures, 10)))
        return min(doubled, ceiling)
    }
}

public extension Presentation {
    /// Before anything is known. Deliberately not "Ready": a UI claiming readiness before it had
    /// asked would be wrong exactly when the answer matters, at login.
    static let connecting = Presentation(glyph: "mic", tint: .faint, status: "Connecting…")

    /// The daemon's socket is there but the stream broke or was refused.
    static let unreachable = Presentation(
        glyph: "exclamationmark.triangle.fill",
        tint: .red,
        status: "dicta is not answering"
    )
}
