import Foundation

// What the setup window shows and sends, as a value (D27, D31, D19).
//
// `DictaMenu` renders this and sends what it says, and decides nothing else: which screen a state
// gets, what each button sends, when the window may open by itself and what each checklist row
// offers are all here, because an executable target is unreachable from the test runner. The
// window reads every consequence of what it sends — a choice saved, or a write that failed — from
// the `watch` stream, as the rest of the menu does.

/// Whether a snapshot is the first a menu process has received.
///
/// Asked on every snapshot. It answers `true` exactly once per process, on the first real snapshot
/// — consumed even when that snapshot is busy, which forfeits the automatic open for this launch on
/// purpose — and it never resets: not on a reconnect, and not when the window closes. A window that
/// could open by itself later would take focus from the pane just dictated into (D22).
public struct FirstSnapshotLatch: Sendable, Equatable {
    private var consumed = false

    public init() {}

    /// Whether `snapshot` is the first real snapshot of this launch. `nil` — an `.end` frame, or an
    /// update that carried nothing — consumes nothing.
    public mutating func observe(_ snapshot: StatusSnapshot?) -> Bool {
        guard snapshot != nil, !consumed else { return false }
        consumed = true
        return true
    }
}

/// Which screen the window draws, one per state of the person's choice.
public enum SetupScreen: Sendable, Equatable {
    /// No snapshot, or one without `setup`: an older daemon, or none. Nothing to send.
    case unavailable
    /// Nobody has chosen. "Use only with agterm" is offered only when agterm is found: having it
    /// installed is not intent, but offering it without agterm would offer a dead end.
    case fresh(showsAgtermOnly: Bool)
    /// `setup.json` could not be used; the person chooses again, as on a fresh install.
    case problem(SetupLoadProblem, showsAgtermOnly: Bool)
    /// agterm only. The first time is the one-time offer; afterwards an ordinary enable screen.
    case offer(firstTime: Bool)
    /// Other apps chosen: what is done and what is still needed.
    case checklist([ChecklistRow])
}

/// A button the window draws. Its title is the copy; what it sends is `SetupModel.effect(of:)`.
public enum SetupControl: String, Sendable, Equatable, CaseIterable {
    case setUpDictation
    case useOnlyWithAgterm
    case enable
    case keepAgtermOnly
    case allowAccess
    case openAccessibilitySettings
    case fetchModels
    case openMicrophoneSettings

    public var title: String {
        switch self {
        case .setUpDictation: "Set up dictation"
        case .useOnlyWithAgterm: "Use only with agterm"
        case .enable: "Enable"
        case .keepAgtermOnly: "Keep agterm only"
        case .allowAccess: "Allow Access…"
        case .openAccessibilitySettings: "Open Accessibility Settings"
        case .fetchModels: "Fetch Models…"
        case .openMicrophoneSettings: "Open Settings"
        }
    }
}

/// What one checklist row says, and the one thing it offers.
public struct ChecklistRow: Sendable, Equatable {
    public enum Item: String, Sendable, Equatable, CaseIterable {
        case accessibility
        case models
        case microphone
        case holdKey
    }

    public enum Status: String, Sendable, Equatable {
        /// Established.
        case done
        /// Nobody has an answer yet, and nothing the person does here would give one sooner.
        case waiting
        /// A step for the person, with the control that takes it.
        case needed
        /// Not a step: a fact the person needs, such as which key starts a dictation.
        case info
    }

    public var item: Item
    public var status: Status
    public var title: String
    public var detail: String
    public var control: SetupControl?

    public init(item: Item, status: Status, title: String, detail: String,
                control: SetupControl? = nil) {
        self.item = item
        self.status = status
        self.title = title
        self.detail = detail
        self.control = control
    }
}

/// What a click, a close or the window becoming key does: at most one request to the daemon, a
/// System Settings pane to open, or one of the banner's existing actions.
public struct SetupEffect: Sendable, Equatable {
    public var request: Request?
    public var url: URL?
    public var action: Banner.Action?

    public init(request: Request? = nil, url: URL? = nil, action: Banner.Action? = nil) {
        self.request = request
        self.url = url
        self.action = action
    }

    public static let nothing = SetupEffect()
    public var isNothing: Bool { self == .nothing }
}

/// Every decision the setup window makes.
public struct SetupModel: Sendable, Equatable {
    /// The Accessibility pane itself, not the top of System Settings.
    public static let accessibilitySettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    /// The latest snapshot from the stream, or `nil` before one or after the link was lost.
    public var snapshot: StatusSnapshot?
    /// Whether `snapshot` is the first of this menu launch, as `FirstSnapshotLatch` answered.
    public var firstSnapshotOfThisLaunch: Bool
    /// Whether "Allow Access…" was clicked in this window during this launch.
    public var accessibilityRequested: Bool

    public init(snapshot: StatusSnapshot?, firstSnapshotOfThisLaunch: Bool = false,
                accessibilityRequested: Bool = false) {
        self.snapshot = snapshot
        self.firstSnapshotOfThisLaunch = firstSnapshotOfThisLaunch
        self.accessibilityRequested = accessibilityRequested
    }

    // MARK: - opening by itself

    /// Whether the window opens by itself now. Only at the first snapshot of a launch, only while
    /// idle, and only for something pending: a choice, the one-time offer, or a setup problem. A
    /// save error alone is never a reason, and never suppresses one. Never later, so the window
    /// cannot take focus from agterm in the middle of a session (D27).
    public var shouldAutoOpen: Bool {
        guard firstSnapshotOfThisLaunch, let snapshot, snapshot.state == .idle,
              let setup = snapshot.setup else { return false }
        if setup.loadProblem != nil { return true }
        switch setup.scope {
        case .undecided: return true
        case .agtermOnly: return !setup.offerSeen
        case .otherApps: return false
        }
    }

    // MARK: - the screen

    public var screen: SetupScreen {
        guard let setup = snapshot?.setup else { return .unavailable }
        let agtermFound = snapshot?.faculties?.terminal == true
        if let problem = setup.loadProblem {
            return .problem(problem, showsAgtermOnly: agtermFound)
        }
        switch setup.scope {
        case .undecided: return .fresh(showsAgtermOnly: agtermFound)
        case .agtermOnly: return .offer(firstTime: !setup.offerSeen)
        case .otherApps: return .checklist(checklistRows)
        }
    }

    /// The last write that failed, shown inline on whichever screen `screen` picks: that is the
    /// screen whose operation failed, because a failed write changes neither the scope nor the load
    /// problem. Not a screen of its own.
    public var saveError: String? {
        snapshot?.setup?.saveError
    }

    public var heading: String {
        switch screen {
        case .unavailable: "Setup is not available"
        case .fresh: "Dictate into text fields in your apps"
        case .problem: "Choose where dictation goes again"
        case .offer(firstTime: true): "Dicta can now type into other apps"
        case .offer(firstTime: false): "Type into other apps"
        case .checklist: "Dictation into your apps"
        }
    }

    public var body: [String] {
        switch screen {
        case .unavailable:
            ["The running dicta is not reachable, or is older than this menu. "
                + "dictactl configure makes the same choice from a terminal."]
        case .fresh, .offer:
            Self.pitch
        case let .problem(problem, _):
            ["\(problem).", "Until you choose again, dicta types only into agterm."] + Self.pitch
        case .checklist:
            ["Dicta types what you say into the text field you are using, and into agterm."]
        }
    }

    private static let pitch = [
        "Hold the key, wait for the sound, speak, and let go.",
        "Speech is recognised on this Mac.",
        "Dicta needs the microphone, and Accessibility permission to type into other apps.",
    ]

    /// The screen's own buttons, in order. Checklist rows carry theirs separately.
    public var controls: [SetupControl] {
        switch screen {
        case .unavailable:
            []
        case let .fresh(showsAgtermOnly), let .problem(_, showsAgtermOnly):
            showsAgtermOnly ? [.setUpDictation, .useOnlyWithAgterm] : [.setUpDictation]
        case .offer(firstTime: true):
            [.enable, .keepAgtermOnly]
        case .offer(firstTime: false):
            [.enable]
        case .checklist:
            [.useOnlyWithAgterm]
        }
    }

    // MARK: - what each thing sends

    /// What clicking `control` does. Nothing for a control this screen does not draw, so a click
    /// landing on a screen the stream has already replaced sends nothing it did not show.
    public func effect(of control: SetupControl) -> SetupEffect {
        guard offers(control) else { return .nothing }
        switch control {
        case .setUpDictation, .enable:
            return SetupEffect(request: Self.choose(.otherApps))
        case .useOnlyWithAgterm:
            return SetupEffect(request: Self.choose(.agtermOnly))
        case .keepAgtermOnly:
            return SetupEffect(request: Request(cmd: .configure, offerSeen: true))
        case .allowAccess:
            return SetupEffect(request: Request(cmd: .accessibility, prompt: true))
        case .openAccessibilitySettings:
            // The pane, and a check that never prompts: the dialog was already shown once.
            return SetupEffect(request: Request(cmd: .accessibility, prompt: false),
                               url: Self.accessibilitySettings)
        case .fetchModels:
            return SetupEffect(action: .fetchModels)
        case .openMicrophoneSettings:
            return SetupEffect(action: .openMicrophoneSettings)
        }
    }

    /// What closing the window does. Only the first-time offer records anything: closing it is an
    /// answer, "not now", and it must not come back at every launch. A fresh screen closed asks
    /// again next launch, because nothing was chosen.
    public var effectOfClosing: SetupEffect {
        guard case .offer(firstTime: true) = screen else { return .nothing }
        return SetupEffect(request: Request(cmd: .configure, offerSeen: true))
    }

    /// What the window opening or becoming key does: the person may be coming back from System
    /// Settings, so the grant is checked — never prompted, including when the system dialog hands
    /// focus back — and only when the latest snapshot says `other-apps`. If that snapshot is stale
    /// the daemon's refusal stays authoritative.
    public var effectOfBecomingKey: SetupEffect {
        guard snapshot?.setup?.scope == .otherApps else { return .nothing }
        return SetupEffect(request: Request(cmd: .accessibility, prompt: false))
    }

    private func offers(_ control: SetupControl) -> Bool {
        if controls.contains(control) { return true }
        guard case let .checklist(rows) = screen else { return false }
        return rows.contains { $0.control == control }
    }

    private static func choose(_ scope: SetupScope) -> Request {
        Request(cmd: .configure, scope: scope, offerSeen: true)
    }

    // MARK: - the checklist

    private var checklistRows: [ChecklistRow] {
        let faculties = snapshot?.faculties
        var rows = [accessibilityRow(faculties?.accessibility),
                    Self.modelsRow(faculties?.models),
                    Self.microphoneRow(faculties?.microphone)]
        if let hold = snapshot?.hold {
            rows.append(Self.holdRow(hold))
        }
        return rows
    }

    private func accessibilityRow(_ granted: Bool?) -> ChecklistRow {
        let detail = "Lets Dicta type the words it heard into the app you are using."
        if granted == true {
            return ChecklistRow(item: .accessibility, status: .done, title: "Accessibility",
                                detail: detail)
        }
        return ChecklistRow(item: .accessibility, status: .needed, title: "Accessibility",
                            detail: detail,
                            control: accessibilityRequested ? .openAccessibilitySettings
                                : .allowAccess)
    }

    private static func modelsRow(_ loaded: Bool?) -> ChecklistRow {
        switch loaded {
        case true?:
            ChecklistRow(item: .models, status: .done, title: "Speech models",
                         detail: "Downloaded and loaded.")
        case false?:
            ChecklistRow(item: .models, status: .needed, title: "Speech models",
                         detail: "The recognition models are not downloaded.",
                         control: .fetchModels)
        case nil:
            ChecklistRow(item: .models, status: .waiting, title: "Speech models",
                         detail: "Waiting for the models to load.")
        }
    }

    private static func microphoneRow(_ granted: Bool?) -> ChecklistRow {
        switch granted {
        case true?:
            ChecklistRow(item: .microphone, status: .done, title: "Microphone",
                         detail: "Allowed.")
        case false?:
            ChecklistRow(item: .microphone, status: .needed, title: "Microphone",
                         detail: "Dicta cannot hear you until the microphone is allowed.",
                         control: .openMicrophoneSettings)
        case nil:
            // The request belongs to the daemon's start-up; the window neither owns nor
            // sequences it, so it has nothing to offer but patience.
            ChecklistRow(item: .microphone, status: .waiting, title: "Microphone",
                         detail: "Waiting for the microphone permission asked at start-up.")
        }
    }

    private static func holdRow(_ hold: HoldSnapshot) -> ChecklistRow {
        switch hold {
        case let .armed(keys):
            // Joined by hand: a locale's list formatter would put a word of another language into
            // an English window (the language rule, AGENTS.md).
            let names = keys.count > 1
                ? keys.dropLast().joined(separator: ", ") + " or " + keys[keys.count - 1]
                : keys.joined()
            return ChecklistRow(
                item: .holdKey, status: .info, title: "Hold key",
                detail: "\(names.prefix(1).uppercased())\(names.dropFirst()). "
                    + "Hold it in any text field, wait for the sound, speak, let go.")
        case .disabled:
            return ChecklistRow(item: .holdKey, status: .info, title: "Hold key",
                                detail: "No hold key is armed (--no-hold).")
        }
    }
}
