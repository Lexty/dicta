import Foundation

// What a `watch` stream carries, and what `status` answers with (D27). One value, deliberately.
//
// The reason it is one value rather than three reads is that the UI draws three things from it —
// the menu-bar glyph, the sentence under the app name, and the fault banner — and they must not be
// able to disagree. Two of them derived from `state` and the third from a separately-fetched
// readiness would eventually show an amber "working" glyph over a red "microphone denied" banner,
// and the user would have no way to know which half was stale.

/// Whether a chord pressed right now would produce a dictation, and if not, what stops it.
///
/// **Deliberately one verdict rather than a set**, even though two of these can be true at once on
/// a fresh install. The UI shows one banner with one action, so a set would only move the choice of
/// which to show into the view, where it could not be tested. The order below is the precedence,
/// and it is not arbitrary: it follows the pipeline, so the reason shown is always the FIRST one a
/// dictation would hit rather than the most recently noticed.
public enum Readiness: String, Codable, Sendable, CaseIterable {
    /// A chord would work.
    case ready
    /// The models are still loading, or the microphone has not been asked for yet. Not a fault: it
    /// is what the first seconds after login look like, and showing a red banner then would train
    /// the user to ignore red banners.
    case starting
    /// The microphone was denied. First in precedence because nothing downstream can happen
    /// without audio, and because it is the one the user fixes in System Settings, not a terminal.
    case microphoneDenied = "microphone-denied"
    /// The recognition models are not on disk. `Dicta --fetch-models` is the fix, and it is the
    /// common state of a fresh install rather than a malfunction.
    case modelsMissing = "models-missing"
    /// `agtermctl` could not be found, so nothing could be delivered even if it were recognised.
    /// Last in precedence: it is the only one that still lets the user's words reach the record.
    case terminalMissing = "terminal-missing"

    /// Whether a chord pressed now would be refused for this reason.
    public var blocksDictation: Bool {
        switch self {
        case .ready, .starting: false
        case .microphoneDenied, .modelsMissing, .terminalMissing: true
        }
    }

    /// The sentence a user is shown. Each names the thing to do, because a banner that only reports
    /// is a banner that gets dismissed.
    public var message: String? {
        switch self {
        case .ready, .starting: nil
        case .microphoneDenied:
            "dicta cannot hear you — grant the microphone in System Settings > Privacy & Security"
        case .modelsMissing:
            "the recognition models are not downloaded — run Dicta --fetch-models once"
        case .terminalMissing:
            "agtermctl could not be found, so dictated text has nowhere to go"
        }
    }
}

/// The three things a dictation needs, and whether each has been established yet.
///
/// `nil` is not "broken" — it is "nobody has looked". That distinction is the whole reason these
/// are optionals: at login the models are still loading and the microphone has not answered, and a
/// daemon that reported those as denied would put two red banners in front of the user every
/// morning, which is how a red banner stops meaning anything.
///
/// `readiness` is DERIVED. Nothing stores the verdict, so it cannot go stale against the facts it
/// was computed from — the failure mode where a UI shows "Ready" because a `readiness` field was
/// set once and never recomputed after the models failed to load.
public struct Faculties: Codable, Sendable, Equatable {
    /// Whether the microphone has been granted. `nil` until TCC has answered.
    public var microphone: Bool?
    /// Whether the recognition models are loaded. `nil` while the start-up load is still running.
    public var models: Bool?
    /// Whether `agtermctl` was found. `nil` before the first look.
    public var terminal: Bool?

    public init(microphone: Bool? = nil, models: Bool? = nil, terminal: Bool? = nil) {
        self.microphone = microphone
        self.models = models
        self.terminal = terminal
    }

    /// The first reason a dictation would fail, in pipeline order: heard, then recognised, then
    /// delivered. A reason further down the pipeline is real but not yet the user's problem.
    public var readiness: Readiness {
        if microphone == false { return .microphoneDenied }
        if models == false { return .modelsMissing }
        if terminal == false { return .terminalMissing }
        // Anything still unknown means start-up, not health. Checked AFTER the failures so that a
        // denied microphone is reported even while the models are still loading — the user can act
        // on it now, and by the time they come back the rest will have settled.
        if microphone == nil || models == nil || terminal == nil { return .starting }
        return .ready
    }
}

/// The daemon's state as of one instant (D27).
public struct StatusSnapshot: Codable, Sendable, Equatable {
    public var state: LifecycleState
    public var readiness: Readiness
    /// The live attempt, when there is one.
    public var attempt: AttemptID?
    /// Where this attempt's words are going, captured at the start and never substituted (D4).
    /// Showing it is D4 made visible: the one moment when noticing the wrong pane is still free.
    public var target: Target?
    /// Seconds of speech so far. Absent unless the microphone is actually open — it is measured
    /// from the moment capture CONFIRMED (D13), not from the keypress, so it never claims to have
    /// been recording during the ~95 ms before the device was live.
    public var speakingSeconds: Double?
    /// D15's cap, carried so the UI can render `2:41 / 10:00` without a copy of the daemon's
    /// constants. A UI that hard-coded ten minutes would keep saying ten after the daemon's
    /// configuration changed, and the first the user would know is a dictation vanishing early.
    public var capSeconds: Double?

    public init(
        state: LifecycleState,
        readiness: Readiness = .ready,
        attempt: AttemptID? = nil,
        target: Target? = nil,
        speakingSeconds: Double? = nil,
        capSeconds: Double? = nil
    ) {
        self.state = state
        self.readiness = readiness
        self.attempt = attempt
        self.target = target
        self.speakingSeconds = speakingSeconds
        self.capSeconds = capSeconds
    }

    /// Whether an attempt is under way. `warming` counts: the microphone is being opened, and a
    /// second chord is refused (§6).
    public var isBusy: Bool { state != .idle }

    /// How close the cap is, in the last-minute sense the UI turns amber for. `nil` when there is
    /// no attempt or no cap.
    public var secondsUntilCap: Double? {
        guard let speakingSeconds, let capSeconds else { return nil }
        return max(0, capSeconds - speakingSeconds)
    }
}
