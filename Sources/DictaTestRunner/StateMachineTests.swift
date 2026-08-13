import DictaCore
import Foundation
import Testing

/// The lifecycle, driven with no microphone, no socket and no clock — which is the whole reason the
/// machine is a pure value. Everything here is a rule that would otherwise only be discovered by
/// mashing a chord at the wrong moment.
@Suite("Конечный автомат")
struct StateMachineTests {
    private func target(_ id: String = "SESSION-1", pane: Pane = .left) -> InjectionTarget {
        InjectionTarget(sessionID: id, pane: pane)
    }

    @Test("старт из покоя начинает запись и не объявляет готовность сразу")
    func startsFromIdle() {
        var machine = StateMachine()
        let decision = machine.start(target: target(), at: Date())
        guard case .begin(let recording) = decision else {
            Issue.record("ожидал .begin, получил \(decision)")
            return
        }
        // warming, а не recording: пользователю ещё нельзя говорить.
        #expect(machine.state == .warming(recording))
        let ready = machine.captureReady(id: recording.id)
        #expect(ready)
        #expect(machine.state == .recording(recording))
    }

    @Test("повторный старт не создаёт вторую запись")
    func rejectsSecondStart() {
        var machine = StateMachine()
        guard case .begin(let first) = machine.start(target: target(), at: Date()) else { return }
        _ = machine.captureReady(id: first.id)

        let second = machine.start(target: target("SESSION-2"), at: Date())
        guard case .rejected = second else {
            Issue.record("вторая запись не должна начинаться, получил \(second)")
            return
        }
        #expect(machine.state == .recording(first))
    }

    @Test("идентификаторы монотонны и не переиспользуются")
    func idsAreMonotonic() {
        var machine = StateMachine()
        guard case .begin(let first) = machine.start(target: target(), at: Date()) else { return }
        _ = machine.captureReady(id: first.id)
        _ = machine.stop(mode: .raw)
        machine.settle(id: first.id)

        guard case .begin(let second) = machine.start(target: target(), at: Date()) else { return }
        #expect(second.id > first.id)
    }

    @Test("второй стоп идемпотентен и не вставляет текст дважды")
    func duplicateStopIsIdempotent() {
        var machine = StateMachine()
        guard case .begin(let recording) = machine.start(target: target(), at: Date()) else { return }
        _ = machine.captureReady(id: recording.id)

        guard case .finish = machine.stop(mode: .clean) else {
            Issue.record("первый стоп обязан завершать запись")
            return
        }
        guard case .idempotent = machine.stop(mode: .clean) else {
            Issue.record("второй стоп обязан быть no-op, а не второй доставкой")
            return
        }
    }

    @Test("режим выбирается стопом, а не стартом")
    func modeComesFromStop() {
        var machine = StateMachine()
        guard case .begin(let recording) = machine.start(target: target(), at: Date()) else { return }
        _ = machine.captureReady(id: recording.id)
        guard case .finish(_, let mode) = machine.stop(mode: .raw) else { return }
        #expect(mode == .raw)
    }

    @Test("стоп до готовности микрофона отменяет, а не доставляет пустоту")
    func stopWhileWarmingCancels() {
        var machine = StateMachine()
        guard case .begin = machine.start(target: target(), at: Date()) else { return }
        guard case .cancel = machine.stop(mode: .clean) else {
            Issue.record("остановка во время warming не должна порождать доставку")
            return
        }
        #expect(machine.state == .idle)
    }

    @Test("стоп в покое отвергается")
    func stopWhenIdle() {
        var machine = StateMachine()
        guard case .rejected = machine.stop(mode: .clean) else {
            Issue.record("останавливать нечего")
            return
        }
    }

    @Test("отмена во время обработки не даёт вставить текст")
    func abortDuringProcessing() {
        var machine = StateMachine()
        guard case .begin(let recording) = machine.start(target: target(), at: Date()) else { return }
        _ = machine.captureReady(id: recording.id)
        _ = machine.stop(mode: .clean)

        guard case .cancel = machine.abort() else {
            Issue.record("отмена во время обработки обязана выбрасывать результат")
            return
        }
        // Транскрипция, вернувшаяся после отмены, не воскрешает запись.
        let resurrected = machine.transcribed(id: recording.id)
        #expect(!resurrected)
        #expect(machine.state == .idle)
    }

    @Test("запоздалое подтверждение микрофона не воскрешает отменённую запись")
    func lateCaptureReadyIsIgnored() {
        var machine = StateMachine()
        guard case .begin(let recording) = machine.start(target: target(), at: Date()) else { return }
        _ = machine.abort()
        let ready = machine.captureReady(id: recording.id)
        #expect(!ready)
        #expect(machine.state == .idle)
    }

    @Test("settle по чужому id не трогает текущую запись")
    func settleIgnoresForeignID() {
        var machine = StateMachine()
        guard case .begin(let recording) = machine.start(target: target(), at: Date()) else { return }
        _ = machine.captureReady(id: recording.id)
        machine.settle(id: recording.id + 999)
        #expect(machine.state == .recording(recording))
    }

    @Test("сбой всегда выбрасывает запись, а не вставляет её")
    func faultAlwaysDiscards() {
        var machine = StateMachine()
        guard case .begin(let recording) = machine.start(target: target(), at: Date()) else { return }
        _ = machine.captureReady(id: recording.id)

        guard case .cancel(let cancelled, _) = machine.fault(reason: "сменилось устройство ввода") else {
            Issue.record("сбой обязан отменять запись")
            return
        }
        #expect(cancelled.id == recording.id)
        #expect(machine.state == .idle)
    }

    @Test("цель фиксируется на старте и переживает переход в обработку")
    func targetIsCapturedAtStart() {
        var machine = StateMachine()
        let captured = target("SESSION-CAPTURED", pane: .right)
        guard case .begin(let recording) = machine.start(target: captured, at: Date()) else { return }
        _ = machine.captureReady(id: recording.id)
        guard case .finish(let finished, _) = machine.stop(mode: .clean) else { return }
        #expect(finished.target == captured)
    }
}
