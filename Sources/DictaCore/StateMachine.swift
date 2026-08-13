import Foundation

/// One dictation attempt. The `id` is monotonic and never reused, which is what makes a late or
/// duplicated command answerable: a `stop` naming a spent id is a no-op rather than a second stop
/// applied to the recording that started meanwhile.
public struct Recording: Equatable, Sendable {
    public let id: RecordingID
    public let target: InjectionTarget
    public let startedAt: Date

    public init(id: RecordingID, target: InjectionTarget, startedAt: Date) {
        self.id = id
        self.target = target
        self.startedAt = startedAt
    }
}

public enum DictaState: Equatable, Sendable {
    case idle
    /// Capture has been asked to start but has NOT confirmed. The user must not be told "speak"
    /// yet — see `Decision.begin`.
    case warming(Recording)
    case recording(Recording)
    case processing(Recording, StopMode)
    case injecting(Recording)

    public var label: String {
        switch self {
        case .idle: "idle"
        case .warming: "warming"
        case .recording: "recording"
        case .processing: "processing"
        case .injecting: "injecting"
        }
    }

    public var recording: Recording? {
        switch self {
        case .idle: nil
        case .warming(let r), .recording(let r), .injecting(let r): r
        case .processing(let r, _): r
        }
    }

    public var isBusy: Bool { self != .idle }
}

/// What the caller must DO about a command. The machine itself performs nothing — it only decides,
/// which is what lets every rule below be asserted without a microphone, a socket or a clock.
public enum Decision: Equatable, Sendable {
    /// Start capturing. Announce readiness to the user only once capture confirms.
    case begin(Recording)
    /// Stop capturing and turn the audio into text.
    case finish(Recording, StopMode)
    /// Throw the audio away. Nothing is injected — `reason` is shown to the user.
    case cancel(Recording, reason: String)
    /// The command cannot apply; tell the user why. No state change.
    case rejected(reason: String)
    /// The command already happened, or has been superseded. Deliberately NOT an error: pressing
    /// stop twice because nothing visibly happened is normal, and must not produce a second
    /// insertion or an alarming noise.
    case idempotent(reason: String)
}

/// The whole lifecycle, as a pure value. Held by the daemon; driven by the tests directly.
public struct StateMachine: Sendable {
    public private(set) var state: DictaState = .idle
    private var nextID: RecordingID = 1

    public init() {}

    // MARK: - Commands

    public mutating func start(target: InjectionTarget, at now: Date) -> Decision {
        switch state {
        case .idle:
            let recording = Recording(id: nextID, target: target, startedAt: now)
            nextID += 1
            state = .warming(recording)
            return .begin(recording)
        case .warming(let r), .recording(let r):
            return .rejected(reason: "уже пишу — запись #\(r.id) для сессии \(r.target.sessionID.prefix(8))")
        case .processing(let r, _), .injecting(let r):
            return .rejected(reason: "ещё обрабатываю запись #\(r.id)")
        }
    }

    public mutating func stop(mode: StopMode) -> Decision {
        switch state {
        case .idle:
            return .rejected(reason: "нечего останавливать")
        case .warming(let r):
            // Stopped before capture ever confirmed: there is no audio, and pretending otherwise
            // would send an empty transcript down the whole pipeline.
            state = .idle
            return .cancel(r, reason: "остановлено до того, как микрофон начал писать")
        case .recording(let r):
            state = .processing(r, mode)
            return .finish(r, mode)
        case .processing(let r, let m):
            return .idempotent(reason: "запись #\(r.id) уже обрабатывается (\(m.rawValue))")
        case .injecting(let r):
            return .idempotent(reason: "запись #\(r.id) уже вставляется")
        }
    }

    public mutating func abort() -> Decision {
        switch state {
        case .idle:
            return .idempotent(reason: "нечего отменять")
        case .warming(let r), .recording(let r), .injecting(let r):
            state = .idle
            return .cancel(r, reason: "отменено")
        case .processing(let r, _):
            state = .idle
            return .cancel(r, reason: "отменено")
        }
    }

    // MARK: - Progress reported by the runtime

    /// Capture confirmed. Returns false when the confirmation is for a recording that has already
    /// been abandoned — a late callback from a run the user aborted must not resurrect it.
    public mutating func captureReady(id: RecordingID) -> Bool {
        guard case .warming(let r) = state, r.id == id else { return false }
        state = .recording(r)
        return true
    }

    /// Text is in hand; injection may begin.
    public mutating func transcribed(id: RecordingID) -> Bool {
        guard case .processing(let r, _) = state, r.id == id else { return false }
        state = .injecting(r)
        return true
    }

    /// The attempt is over, successfully or not.
    public mutating func settle(id: RecordingID) {
        guard let current = state.recording, current.id == id else { return }
        state = .idle
    }

    /// Something the user did not ask for went wrong: the machine slept, the input device changed,
    /// capture died. Always discards — never injects. A recording whose audio boundary is in doubt
    /// is not worth guessing about.
    public mutating func fault(reason: String) -> Decision {
        guard let current = state.recording else {
            return .idempotent(reason: "нечего прерывать")
        }
        state = .idle
        return .cancel(current, reason: reason)
    }
}
