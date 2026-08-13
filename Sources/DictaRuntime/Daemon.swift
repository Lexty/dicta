import DictaCore
import Foundation

/// The daemon: owns the state machine and turns its decisions into the world.
///
/// The division of labour is the point. `StateMachine` decides and is pure; `Daemon` performs and
/// is not. Every rule worth arguing about — what a second start does, whether a duplicated stop
/// injects twice, whether a fault can inject at all — lives on the pure side and is asserted there
/// without a microphone.
public actor Daemon {
    private var machine = StateMachine()
    private let capture: Capture
    private let transcriber: Transcriber
    private let filter: Filter
    private let injector: Injector
    private let agterm: Agterm
    private let history: History
    private let maxDuration: TimeInterval

    private var capTask: Task<Void, Never>?

    public init(
        capture: Capture,
        transcriber: Transcriber,
        filter: Filter = NoFilter(),
        injector: Injector,
        agterm: Agterm = Agterm(),
        history: History = History(),
        maxDuration: TimeInterval = 600
    ) {
        self.capture = capture
        self.transcriber = transcriber
        self.filter = filter
        self.injector = injector
        self.agterm = agterm
        self.history = history
        self.maxDuration = maxDuration
    }

    // MARK: - Entry point

    public func handle(_ request: Request) async -> Response {
        switch request.cmd {
        case "start": await handleStart(request)
        case "stop": await handleStop(request)
        case "toggle": await handleToggle(request)
        case "abort": await handleAbort()
        case "status": Response(ok: true, state: machine.state.label, id: machine.state.recording?.id)
        case "last": handleLast(raw: request.raw ?? false)
        default: Response(ok: false, state: machine.state.label, message: "неизвестная команда \(request.cmd)")
        }
    }

    // MARK: - Commands

    /// One chord, two meanings — resolved HERE rather than in the shell.
    ///
    /// The obvious keymap line is `dictactl status | grep idle && start || stop`, and it is wrong:
    /// two round trips with a window between them, during which the duration cap can fire or a
    /// second chord can land, so the same keypress can both start and stop. Inside the actor the
    /// decision is atomic against every other command.
    private func handleToggle(_ request: Request) async -> Response {
        if machine.state.isBusy {
            return await handleStop(request)
        }
        return await handleStart(request)
    }

    private func handleStart(_ request: Request) async -> Response {
        guard let sessionID = request.sessionID, !sessionID.isEmpty else {
            return Response(ok: false, state: machine.state.label, message: "не передан sessionID")
        }
        // Resolve the focused pane before entering the machine: if agterm cannot tell us where the
        // text would go, there is no point starting a recording we could not deliver.
        //
        // This is the step that replaces the missing `$AGT_PANE` — the installed agterm build does
        // not export it, and the tree reports live focus anyway.
        let pane: Pane
        do {
            pane = try agterm.focusedPane(sessionID: sessionID, socket: request.socket)
        } catch {
            return Response(ok: false, state: machine.state.label, message: "\(error)")
        }
        return await begin(target: InjectionTarget(sessionID: sessionID, pane: pane, socket: request.socket))
    }

    /// Start recording for an already-resolved target. Split out from `handleStart` because pane
    /// resolution is the one part that needs a live agterm — everything below here is drivable with
    /// fakes alone, which is how the delivery rules get asserted without a terminal.
    public func begin(target: InjectionTarget) async -> Response {
        switch machine.start(target: target, at: Date()) {
        case .begin(let recording):
            do {
                try await capture.start()
            } catch {
                _ = machine.fault(reason: "\(error)")
                agterm.notify("микрофон не запустился: \(error)", target: target)
                return Response(ok: false, state: machine.state.label, message: "\(error)")
            }
            // Only NOW is the user told to speak. Announcing at keypress would train them to start
            // talking before audio flows, and lose the first syllable every time.
            guard machine.captureReady(id: recording.id) else {
                await capture.discard()
                return Response(ok: false, state: machine.state.label, message: "запись отменена на старте")
            }
            agterm.status("active", target: target, blink: true, sound: "Pop", color: "#ff3b30")
            armDurationCap(for: recording)
            return Response(ok: true, state: machine.state.label, id: recording.id, message: "пишу")

        case .rejected(let reason):
            agterm.status("blocked", target: target, sound: "Basso")
            return Response(ok: false, state: machine.state.label, message: reason)

        default:
            return Response(ok: false, state: machine.state.label, message: "неожиданное состояние")
        }
    }

    private func handleStop(_ request: Request) async -> Response {
        let mode = request.mode ?? .clean
        switch machine.stop(mode: mode) {
        case .finish(let recording, let mode):
            capTask?.cancel()
            capTask = nil
            let samples = await capture.stop()
            return await deliver(recording, mode: mode, samples: samples)

        case .cancel(let recording, let reason):
            capTask?.cancel()
            capTask = nil
            await capture.discard()
            agterm.status("idle", target: recording.target)
            agterm.notify(reason, target: recording.target)
            return Response(ok: false, state: machine.state.label, id: recording.id, message: reason)

        case .idempotent(let reason):
            // Not an error and deliberately silent: pressing stop again because nothing visible
            // happened is normal, and must not produce a second insertion or an alarming noise.
            return Response(ok: true, state: machine.state.label, message: reason)

        case .rejected(let reason):
            return Response(ok: false, state: machine.state.label, message: reason)

        case .begin:
            return Response(ok: false, state: machine.state.label, message: "неожиданное состояние")
        }
    }

    private func handleAbort() async -> Response {
        switch machine.abort() {
        case .cancel(let recording, let reason):
            capTask?.cancel()
            capTask = nil
            await capture.discard()
            agterm.status("idle", target: recording.target)
            return Response(ok: true, state: machine.state.label, id: recording.id, message: reason)
        case .idempotent(let reason):
            return Response(ok: true, state: machine.state.label, message: reason)
        default:
            return Response(ok: false, state: machine.state.label, message: "неожиданное состояние")
        }
    }

    private func handleLast(raw: Bool) -> Response {
        guard let entry = history.last() else {
            return Response(ok: false, state: machine.state.label, message: "истории пока нет")
        }
        return Response(
            ok: true,
            state: machine.state.label,
            id: entry.id,
            text: raw ? entry.raw : entry.text
        )
    }

    // MARK: - Delivery

    private func deliver(_ recording: Recording, mode: StopMode, samples: [Float]) async -> Response {
        let target = recording.target
        agterm.status("active", target: target, color: "#ffcc00")

        let raw: String
        do {
            raw = try await transcriber.transcribe(samples)
        } catch {
            return fail(recording, mode: mode, raw: "", reason: "распознавание не удалось: \(error)")
        }

        guard !Sanitizer.sanitize(raw).isEmpty else {
            machine.settle(id: recording.id)
            agterm.status("idle", target: target)
            agterm.notify("ничего не распознал", target: target)
            history.append(HistoryEntry(
                id: recording.id, mode: mode.rawValue, outcome: "empty",
                raw: raw, text: "", target: target
            ))
            return Response(ok: false, state: machine.state.label, id: recording.id, message: "пусто")
        }

        // The filter may fail, hang or return nothing; none of those may cost the user their words,
        // so the raw transcript is the fallback rather than an error.
        var text = raw
        var filterNote: String?
        if mode == .clean, filter.isConfigured {
            do {
                let filtered = try await filter.run(raw)
                if filtered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    filterNote = "фильтр вернул пустоту — вставил сырой текст"
                } else {
                    text = filtered
                }
            } catch {
                filterNote = "фильтр не сработал (\(error)) — вставил сырой текст"
            }
        }

        // THE one sanitiser, on every path: cleaned, raw, and the raw-as-fallback above. A newline
        // reaching `session type` is a Return, which submits a half-written prompt.
        text = Sanitizer.sanitize(text)
        guard Sanitizer.isInjectable(text) else {
            return fail(recording, mode: mode, raw: raw, reason: "текст не прошёл санитайзер")
        }

        guard machine.transcribed(id: recording.id) else {
            // Aborted while we were transcribing: the user said no, so nothing is injected.
            history.append(HistoryEntry(
                id: recording.id, mode: mode.rawValue, outcome: "aborted",
                raw: raw, text: text, target: target
            ))
            return Response(ok: false, state: machine.state.label, id: recording.id, message: "отменено")
        }

        do {
            try await injector.inject(text, into: target)
        } catch {
            return fail(recording, mode: mode, raw: raw, text: text,
                        reason: "не вставил: \(error). Текст сохранён — `dictactl last`")
        }

        machine.settle(id: recording.id)
        agterm.status("completed", target: target, autoReset: true, sound: "Tink")
        if let filterNote { agterm.notify(filterNote, target: target) }
        history.append(HistoryEntry(
            id: recording.id, mode: mode.rawValue, outcome: "injected",
            raw: raw, text: text, target: target, error: filterNote
        ))
        return Response(ok: true, state: machine.state.label, id: recording.id, text: text)
    }

    private func fail(
        _ recording: Recording,
        mode: StopMode,
        raw: String,
        text: String = "",
        reason: String
    ) -> Response {
        machine.settle(id: recording.id)
        agterm.status("blocked", target: recording.target, sound: "Basso")
        agterm.notify(reason, target: recording.target)
        history.append(HistoryEntry(
            id: recording.id, mode: mode.rawValue, outcome: "failed",
            raw: raw, text: text, target: recording.target, error: reason
        ))
        return Response(ok: false, state: machine.state.label, id: recording.id, message: reason)
    }

    // MARK: - Duration cap

    /// A forgotten recording must stop, and must NOT be injected: ten minutes of unrelated speech
    /// landing in an agent's prompt is a worse outcome than losing it. The text still reaches the
    /// history log, so nothing is destroyed.
    private func armDurationCap(for recording: Recording) {
        capTask = Task { [weak self, maxDuration] in
            try? await Task.sleep(nanoseconds: UInt64(maxDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.capExpired(recording)
        }
    }

    private func capExpired(_ recording: Recording) async {
        guard machine.state.recording?.id == recording.id else { return }
        let decision = machine.fault(reason: "запись шла \(Int(maxDuration / 60)) минут — остановил")
        guard case .cancel(_, let reason) = decision else { return }
        let samples = await capture.stop()
        agterm.status("blocked", target: recording.target, sound: "Basso")
        agterm.notify("\(reason). Текст не вставлен, лежит в `dictactl last`", target: recording.target)
        let raw = (try? await transcriber.transcribe(samples)) ?? ""
        history.append(HistoryEntry(
            id: recording.id, mode: "capped", outcome: "capped",
            raw: raw, text: "", target: recording.target, error: reason
        ))
    }
}
