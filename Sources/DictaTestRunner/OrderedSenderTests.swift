import DictaCore
import DictaRuntime
import Foundation
import Testing

/// The setup window's requests reach the daemon in the order the person made them (D27, D31).
@Suite("ordered sender")
struct OrderedSenderTests {
    /// Every item the transport was handed, in arrival order, and a gate that holds the first.
    final class Transport: @unchecked Sendable {
        private let lock = NSLock()
        private var arrived: [Request] = []
        private let firstHeld = DispatchSemaphore(value: 0)
        let firstArrived = DispatchSemaphore(value: 0)
        let delivered = DispatchSemaphore(value: 0)
        private let handle: @Sendable (Request) -> Void

        init(handle: @escaping @Sendable (Request) -> Void = { _ in }) {
            self.handle = handle
        }

        var arrivals: [Request] { lock.withLock { arrived } }

        func releaseFirst() { firstHeld.signal() }

        func deliver(_ request: Request) {
            let isFirst = lock.withLock { () -> Bool in
                arrived.append(request)
                return arrived.count == 1
            }
            if isFirst {
                firstArrived.signal()
                // The first transport call, slow to reach the daemon.
                _ = firstHeld.wait(timeout: .now() + 10)
            }
            handle(request)
            delivered.signal()
        }
    }

    /// A fresh screen with agterm found, where both choices are drawn side by side.
    static let freshWithAgterm = SetupModel(snapshot: StatusSnapshot(
        state: .idle, readiness: .ready,
        setup: SetupSnapshot(scope: .undecided, offerSeen: false),
        faculties: Faculties(microphone: true, models: true, terminal: true, scope: .undecided)))

    @Test("conflicting choices, the first held in transport, arrive in click order; the last wins")
    func conflictingChoicesKeepClickOrder() throws {
        let setup = DaemonTests.fieldSetup(scope: .undecided)
        let store = try #require(setup.store as? FakeSetupStore)
        let daemon = DaemonTests.daemonWithoutAgterm(feedback: FakeNotifier(), setup: setup)
        let transport = Transport { request in _ = daemon.handle(.request(request)) }
        let sender = OrderedSender<Request>(name: "test.setup") { transport.deliver($0) }

        let first = try #require(Self.freshWithAgterm.effect(of: .setUpDictation).request)
        let second = try #require(Self.freshWithAgterm.effect(of: .useOnlyWithAgterm).request)
        sender.enqueue(first)
        #expect(transport.firstArrived.wait(timeout: .now() + 10) == .success)
        // The person changes their mind while the first choice is still on its way.
        sender.enqueue(second)
        // Nothing overtakes a request still in transport.
        #expect(transport.delivered.wait(timeout: .now() + 0.2) == .timedOut)
        #expect(transport.arrivals == [first])

        transport.releaseFirst()
        #expect(transport.delivered.wait(timeout: .now() + 10) == .success)
        #expect(transport.delivered.wait(timeout: .now() + 10) == .success)

        #expect(transport.arrivals == [first, second])
        #expect(store.writes == [.save(SetupState(scope: .otherApps, offerSeen: true)),
                                 .save(SetupState(scope: .agtermOnly, offerSeen: true))])
        let snapshot = try #require(daemon.handle(.request(DaemonTests.status)).snapshot)
        #expect(snapshot.setup?.scope == .agtermOnly)
        #expect(setup.fieldSwitch.current == nil, "the gate the first choice opened stayed open")
    }

    @Test("a close enqueued behind a pending click is sent after it, never before")
    func closeFollowsAPendingClick() throws {
        let transport = Transport()
        let sender = OrderedSender<Request>(name: "test.setup") { transport.deliver($0) }
        let offer = SetupModel(snapshot: StatusSnapshot(
            state: .idle, readiness: .ready,
            setup: SetupSnapshot(scope: .agtermOnly, offerSeen: false)))

        let enable = try #require(offer.effect(of: .enable).request)
        let close = try #require(offer.effectOfClosing.request)
        sender.enqueue(enable)
        #expect(transport.firstArrived.wait(timeout: .now() + 10) == .success)
        sender.enqueue(close)
        transport.releaseFirst()
        #expect(transport.delivered.wait(timeout: .now() + 10) == .success)
        #expect(transport.delivered.wait(timeout: .now() + 10) == .success)
        #expect(transport.arrivals == [enable, close])
    }

    @Test("a sender that has drained starts a new worker for what is enqueued later, in order")
    func deliversAgainAfterDraining() {
        let transport = Transport()
        transport.releaseFirst()
        let drained = DispatchSemaphore(value: 0)
        let batchQueued = DispatchSemaphore(value: 0)
        let requests = (0..<50).map { _ in Request(cmd: .accessibility, prompt: false) }
            + [Request(cmd: .configure, offerSeen: true)]
        let sender = OrderedSender<Request>(
            name: "test.setup",
            deliver: { request in
                // The second batch's first item waits until the whole batch is queued, so its
                // worker cannot end halfway through and blur one restart into several.
                if transport.arrivals.count == 1 { _ = batchQueued.wait(timeout: .now() + 10) }
                transport.deliver(request)
            },
            idle: { drained.signal() })

        sender.enqueue(requests[0])
        // The first worker has found nothing left and ended, not merely delivered.
        #expect(drained.wait(timeout: .now() + 10) == .success)
        #expect(transport.arrivals == [requests[0]])

        for request in requests.dropFirst() { sender.enqueue(request) }
        batchQueued.signal()
        #expect(drained.wait(timeout: .now() + 10) == .success)
        #expect(transport.arrivals == requests)
        #expect(drained.wait(timeout: .now() + 0.1) == .timedOut, "a worker ended mid-batch")
    }
}
