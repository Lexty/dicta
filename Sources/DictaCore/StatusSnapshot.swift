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
    /// Last of the faults: it is the only one that still lets the user's words reach the record.
    /// Only ever the verdict under `agterm-only`, which an unreadable `setup.json` behaves as;
    /// under `other-apps` the fact is `fieldsOnly`, and under `undecided` it is `setupNeeded`.
    case terminalMissing = "terminal-missing"
    /// `agtermctl` could not be found and nobody has chosen where dictation goes (D31). Blocks, but
    /// is not a fault: it is a step the person has not taken, the state of a fresh install on a
    /// machine without agterm, and its banner opens the setup window rather than alarming.
    case setupNeeded = "setup-needed"
    /// The person chose `other-apps`, the Accessibility grant is missing, and `agtermctl` could not
    /// be found: nowhere is left for text to go. A pending step, not a fault.
    case accessibilityNeeded = "accessibility-needed"
    /// The person chose `other-apps` and the grant is missing, but agterm is there: agterm
    /// dictation works, and other applications wait on the grant.
    case accessibilityForFields = "accessibility-for-fields"
    /// `agtermctl` could not be found, and the person chose `other-apps` (D31): agterm chords are
    /// refused, and every other application's focused field still takes a dictation. A notice
    /// rather than a fault -- a machine without agterm is the configuration that choice exists
    /// for, and a red banner on it every morning would be a banner that stops being read.
    case fieldsOnly = "fields-only"

    /// Whether a chord pressed now would be refused for this reason.
    public var blocksDictation: Bool {
        switch self {
        case .ready, .starting, .fieldsOnly, .accessibilityForFields: false
        case .microphoneDenied, .modelsMissing, .terminalMissing, .setupNeeded,
             .accessibilityNeeded: true
        }
    }

    /// Whether something is broken, as opposed to a step the person has not taken yet. Only a fault
    /// is drawn red. The distinction is not `blocksDictation`: a fresh install without agterm
    /// blocks every hold, and drawing it with the same red triangle as a denied microphone would
    /// tell the person something failed before they have done anything at all.
    public var isFault: Bool {
        switch self {
        case .microphoneDenied, .modelsMissing, .terminalMissing: true
        case .ready, .starting, .setupNeeded, .accessibilityNeeded, .accessibilityForFields,
             .fieldsOnly: false
        }
    }

    /// Whether the banner's one action is opening the setup window: the verdicts that are a choice
    /// or a grant the person has not given yet.
    public var isSetupStep: Bool {
        switch self {
        case .setupNeeded, .accessibilityNeeded, .accessibilityForFields: true
        case .ready, .starting, .microphoneDenied, .modelsMissing, .terminalMissing, .fieldsOnly:
            false
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
        case .setupNeeded:
            "dicta is not set up yet — choose where dictation goes"
        case .accessibilityNeeded:
            "agtermctl could not be found, and typing into other apps needs Accessibility "
                + "permission"
        case .accessibilityForFields:
            "agterm dictation works — typing into other apps needs Accessibility permission"
        case .fieldsOnly:
            "agtermctl could not be found — dicta types into focused fields, and agterm chords "
                + "are refused"
        }
    }
}

/// The things a dictation needs, whether each has been established yet, and the scope that decides
/// which of them matter.
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
    /// The scope in force (D31): `agterm-only` for an unreadable `setup.json`, because that is how
    /// the daemon behaves over one. It decides whether a missing `agtermctl` leaves anywhere for
    /// text to go, and whether the grant matters at all. Not a faculty that can be unknown: the
    /// daemon has it before anything else is looked at.
    public var scope: SetupScope
    /// Whether the Accessibility grant was present at the last check. `nil` until a check, and
    /// always `nil` unless the scope is `other-apps`: reporting it otherwise would be an
    /// accessibility call nobody asked for.
    public var accessibility: Bool?

    public init(microphone: Bool? = nil, models: Bool? = nil, terminal: Bool? = nil,
                scope: SetupScope = .agtermOnly, accessibility: Bool? = nil) {
        self.microphone = microphone
        self.models = models
        self.terminal = terminal
        self.scope = scope
        self.accessibility = accessibility
    }

    /// The first reason a dictation would fail, in pipeline order: heard, then recognised, then
    /// delivered. A reason further down the pipeline is real but not yet the user's problem.
    public var readiness: Readiness {
        if microphone == false { return .microphoneDenied }
        if models == false { return .modelsMissing }
        if terminal == false, scope == .agtermOnly { return .terminalMissing }
        // Anything still unknown means start-up, not health. Checked AFTER the failures so that a
        // denied microphone is reported even while the models are still loading — the user can act
        // on it now, and by the time they come back the rest will have settled. The grant is a fact
        // only under `other-apps`; anywhere else nobody may look, so it cannot be waited on.
        if microphone == nil || models == nil || terminal == nil { return .starting }
        if scope == .otherApps, accessibility == nil { return .starting }
        // Everything below is after `starting`, unlike the faults: each is a pending step or a
        // notice, and one that pre-empted "Starting…" would claim a readiness nobody has
        // established yet.
        switch scope {
        case .undecided:
            return terminal == false ? .setupNeeded : .ready
        case .agtermOnly:
            return .ready
        case .otherApps:
            if accessibility == false {
                return terminal == false ? .accessibilityNeeded : .accessibilityForFields
            }
            return terminal == false ? .fieldsOnly : .ready
        }
    }
}

/// The person's choice as the daemon holds it (D31), for the setup window to draw from.
public struct SetupSnapshot: Codable, Sendable, Equatable {
    /// The scope in force: `agterm-only` while `loadProblem` stands.
    public var scope: SetupScope
    public var offerSeen: Bool
    /// Why `setup.json` could not be used. Stands until a replacement succeeds, so every
    /// `configure` meanwhile, a retry after a failed one included, replaces the file.
    public var loadProblem: SetupLoadProblem?
    /// The last write that failed, cleared by the next that succeeds. Separate from `loadProblem`
    /// because a failed replacement must leave the window on the problem with its error.
    public var saveError: String?

    public init(scope: SetupScope, offerSeen: Bool, loadProblem: SetupLoadProblem? = nil,
                saveError: String? = nil) {
        self.scope = scope
        self.offerSeen = offerSeen
        self.loadProblem = loadProblem
        self.saveError = saveError
    }
}

/// What the hold trigger was armed with, so the window can name the gesture that actually works.
///
/// `disabled` is explicit rather than a missing value: an older daemon's snapshot lacks the field
/// too, and its user must not be told that no key is armed.
public enum HoldSnapshot: Codable, Sendable, Equatable {
    /// The display names of the effective keys, custom ones included.
    case armed(keys: [String])
    /// `--no-hold`: no key starts anything.
    case disabled
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
    /// The person's choice. `nil` from a daemon older than the setup window.
    public var setup: SetupSnapshot?
    /// The facts `readiness` was derived from, carried so the setup window's checklist reads the
    /// microphone, the models, agterm and the grant from the same value as the verdict. `nil` from
    /// an older daemon.
    public var faculties: Faculties?
    /// What the hold trigger was armed with. `nil` means not reported, never "no key".
    public var hold: HoldSnapshot?

    public init(
        state: LifecycleState,
        readiness: Readiness = .ready,
        attempt: AttemptID? = nil,
        target: Target? = nil,
        speakingSeconds: Double? = nil,
        capSeconds: Double? = nil,
        setup: SetupSnapshot? = nil,
        faculties: Faculties? = nil,
        hold: HoldSnapshot? = nil
    ) {
        self.state = state
        self.readiness = readiness
        self.attempt = attempt
        self.target = target
        self.speakingSeconds = speakingSeconds
        self.capSeconds = capSeconds
        self.setup = setup
        self.faculties = faculties
        self.hold = hold
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
