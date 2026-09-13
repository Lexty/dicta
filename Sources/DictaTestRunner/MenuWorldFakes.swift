import DictaCore
import DictaIPC
import DictaMenuKit
import DictaRecord
import Foundation
import Testing

/// A `MenuWorld` in which the test holds every capability: which closures run, in what order, and
/// what the socket, the record and the clock answer (D19).
///
/// Nothing here starts a thread or sleeps. Work sent off the main actor is held until the test runs
/// it, on the test's own thread and outside the lock, so a closure that sends more work (a
/// reconnect sending `connect` again) does not deadlock. Hops back to the main actor are held
/// separately, so a test chooses the order completions land in, which is what a real race does.
/// Timers and the reconnect backoff are recorded and fire only when the test says so.
final class FakeMenuWorld: @unchecked Sendable {
    /// How a scripted watch stream ends, after its events.
    enum Ending: Sendable {
        /// `ControlClient.watch` returning: the daemon sent `.end`.
        case returns
        /// `ControlClient.watch` throwing: the daemon went away, or was never there.
        case throwing(any Error)
        /// A stream that has not ended. The fake's watch must return, since it runs on the test's
        /// thread, so the one hop its return makes is dropped: a stream still open has not made
        /// it yet.
        case open
    }

    /// One call of `watch`: the events it delivers, then how it ends.
    struct WatchScript: Sendable {
        var events: [WatchEvent]
        var ending: Ending
    }

    /// One `scheduleTicker` call and what became of it.
    struct Ticker {
        var interval: TimeInterval
        var cancelled = false
        var tick: @MainActor () -> Void
    }

    /// An executable launched through `MenuEffects.run`.
    struct Run: Equatable {
        var executable: String
        var arguments: [String]
    }

    /// Everything the capabilities touch. **Guarded by `lock`.**
    struct State {
        var socketPresent = true
        var watchScripts: [WatchScript] = []
        var watchedPaths: [String] = []
        var offMain: [(name: String, work: @Sendable () -> Void)] = []
        var mainHops: [@MainActor @Sendable () -> Void] = []
        /// Set by an `.open` stream as it returns; the next hop is the one to drop.
        var dropNextHop = false
        var sent: [Request] = []
        var sentPaths: [String] = []
        /// Answers for `readRecent`, in order; with none left, the record is empty.
        var reads: [Result<[RecordEntry], any Error>] = []
        var readsAsked: [URL] = []
        var agterm: String?
        var sessionNames: [String: String] = [:]
        var treesAsked: [String] = []
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var tickers: [Ticker] = []
        var afters: [(delay: TimeInterval, work: @MainActor () -> Void)] = []
        var opened: [URL] = []
        var revealed: [URL] = []
        var copied: [String] = []
        var ran: [Run] = []
    }

    private let lock = NSLock()
    private var state = State()

    /// Reads or changes the state under the lock. Never call a capability from inside `body`.
    @discardableResult
    func with<T>(_ body: (inout State) -> T) -> T {
        lock.withLock { body(&state) }
    }

    /// The error an unscripted watch throws: a socket with nobody behind it.
    static let unscripted = ControlClient.ClientError.daemonCrashed(path: "unscripted")

    var world: MenuWorld {
        MenuWorld(
            socketExists: { [self] _ in with { $0.socketPresent } },
            watch: { [self] path, onEvent in
                let script = with { state -> WatchScript? in
                    state.watchedPaths.append(path)
                    return state.watchScripts.isEmpty ? nil : state.watchScripts.removeFirst()
                }
                guard let script else { throw Self.unscripted }
                for event in script.events { onEvent(event) }
                switch script.ending {
                case .returns: break
                case let .throwing(error): throw error
                case .open: with { $0.dropNextHop = true }
                }
            },
            send: { [self] request, path in
                with {
                    $0.sent.append(request)
                    $0.sentPaths.append(path)
                }
            },
            readRecent: { [self] url, _ in
                let answer = with { state -> Result<[RecordEntry], any Error> in
                    state.readsAsked.append(url)
                    return state.reads.isEmpty ? .success([]) : state.reads.removeFirst()
                }
                return try answer.get()
            },
            locateAgterm: { [self] in with { $0.agterm } },
            sessionNames: { [self] tool in
                with {
                    $0.treesAsked.append(tool)
                    return $0.sessionNames
                }
            },
            offMain: { [self] name, work in with { $0.offMain.append((name, work)) } },
            toMain: { [self] work in
                with {
                    guard !$0.dropNextHop else { return $0.dropNextHop = false }
                    $0.mainHops.append(work)
                }
            },
            now: { [self] in with { $0.now } },
            scheduleTicker: { [self] interval, tick in
                let index = with { state -> Int in
                    state.tickers.append(Ticker(interval: interval, tick: tick))
                    return state.tickers.count - 1
                }
                return MenuCancel { [self] in with { $0.tickers[index].cancelled = true } }
            },
            after: { [self] delay, work in with { $0.afters.append((delay, work)) } },
            effects: MenuEffects(
                openURL: { [self] url in with { $0.opened.append(url) } },
                revealInFinder: { [self] url in with { $0.revealed.append(url) } },
                copy: { [self] text in with { $0.copied.append(text) } },
                run: { [self] executable, arguments in
                    with { $0.ran.append(Run(executable: executable, arguments: arguments)) }
                }))
    }

    // MARK: - scripting

    /// Queues the next `watch` call's stream.
    func script(_ events: [WatchEvent], then ending: Ending = .returns) {
        with { $0.watchScripts.append(WatchScript(events: events, ending: ending)) }
    }

    /// The names of the work waiting off the main actor, in the order it was sent.
    var pendingOffMain: [String] {
        with { $0.offMain.map(\.name) }
    }

    /// Runs the waiting off-main work in order, including any it sends, or only the work with that
    /// name. Each closure runs outside the lock.
    func runOffMain(_ name: String? = nil) {
        while let work = with({ state -> (@Sendable () -> Void)? in
            guard let index = state.offMain.firstIndex(where: { name == nil || $0.name == name })
            else { return nil }
            return state.offMain.remove(at: index).work
        }) {
            work()
        }
    }

    /// How many hops back to the main actor are held.
    var heldMainHops: Int {
        with { $0.mainHops.count }
    }

    /// Lands the held hop at `index`, and only that one.
    @MainActor
    func releaseMain(at index: Int = 0) {
        let hop = with { $0.mainHops.remove(at: index) }
        hop()
    }

    /// Lands every held hop in the order it was made, including any a landing hop makes.
    @MainActor
    func releaseMain() {
        while let hop = with({ $0.mainHops.isEmpty ? nil : $0.mainHops.removeFirst() }) {
            hop()
        }
    }

    /// Runs off-main work and lands hops until neither is left. Timers and the backoff do not fire.
    @MainActor
    func settle(sourceLocation: SourceLocation = #_sourceLocation) {
        for _ in 0..<100 {
            runOffMain()
            releaseMain()
            if with({ $0.offMain.isEmpty && $0.mainHops.isEmpty }) { return }
        }
        Issue.record("the fake world never settled", sourceLocation: sourceLocation)
    }

    /// Runs the oldest pending `after`, as its delay elapsing would.
    @MainActor
    func fireAfter(sourceLocation: SourceLocation = #_sourceLocation) {
        guard let pending = with({ $0.afters.isEmpty ? nil : $0.afters.removeFirst() }) else {
            Issue.record("no after is pending", sourceLocation: sourceLocation)
            return
        }
        pending.work()
    }

    /// The delays of every `after` still pending.
    var pendingAfterDelays: [TimeInterval] {
        with { $0.afters.map(\.delay) }
    }

    /// The tickers scheduled and not cancelled.
    var runningTickers: Int {
        with { $0.tickers.filter { !$0.cancelled }.count }
    }

    /// Fires every running ticker once.
    @MainActor
    func tick() {
        let ticks = with { $0.tickers.filter { !$0.cancelled }.map(\.tick) }
        for tick in ticks { tick() }
    }
}

/// A setup window that counts the times it was asked to show.
@MainActor
final class FakeSetupPresenter: SetupWindowPresenting {
    private(set) var shows = 0

    func show() {
        shows += 1
    }
}
