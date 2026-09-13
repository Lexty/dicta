import DictaCore
import DictaIPC
import DictaMenuKit
import Foundation
import Testing

/// The menu's view model, driven through a fake world (D19, D27).
///
/// `StatusViewModel` owns the connection, the ticker, the record reads and the setup window's
/// wiring. Until it moved into `DictaMenuKit` none of that was reachable from here; now the model
/// is real and only `MenuWorld`, the lowest seam, is fake. These first tests pin what it did when
/// it moved, so a later change starts from a known baseline.
@MainActor
@Suite("status view model")
struct StatusViewModelTests {
    static let socket = "/tmp/dicta-tests/control.sock"
    static let record = URL(fileURLWithPath: "/tmp/dicta-tests/record.jsonl")
    static let idle = StatusSnapshot(state: .idle)
    static let recording = StatusSnapshot(
        state: .recording, attempt: 7, target: Target(sessionID: "session-1", pane: .left),
        speakingSeconds: 3, capSeconds: 600)

    static func model(_ fake: FakeMenuWorld) -> StatusViewModel {
        StatusViewModel(world: fake.world, socketPath: socket, record: record)
    }

    /// A model that has started and received `snapshot`, with the stream still open, and every
    /// piece of work that caused settled.
    static func connected(_ fake: FakeMenuWorld,
                          to snapshot: StatusSnapshot) -> StatusViewModel {
        let model = model(fake)
        fake.script([.update(snapshot)], then: .open)
        model.start()
        fake.settle()
        return model
    }

    // MARK: - the connection

    @Test("the first model is seeded synchronously from whether the socket exists")
    func firstModelIsSynchronous() {
        let present = FakeMenuWorld()
        let seeded = Self.model(present)
        #expect(seeded.model == MenuModel(link: .connecting))
        #expect(seeded.now == present.with { $0.now })
        // Seeding asks nothing of the stream: no work was sent anywhere.
        #expect(present.pendingOffMain.isEmpty)

        let absent = FakeMenuWorld()
        absent.with { $0.socketPresent = false }
        #expect(Self.model(absent).model == MenuModel(link: .notRunning))
    }

    @Test("start() opens the watch and reads the record, once")
    func startConnects() {
        let fake = FakeMenuWorld()
        let model = Self.model(fake)
        model.start()
        #expect(fake.pendingOffMain == ["watch", "record"])
        model.start()
        #expect(fake.pendingOffMain == ["watch", "record"])

        fake.script([.update(Self.idle)])
        fake.runOffMain()
        #expect(fake.with { $0.watchedPaths } == [Self.socket])
        #expect(fake.with { $0.readsAsked } == [Self.record])
    }

    @Test("with no socket, start() reports not running and never opens the stream")
    func noSocketIsNotRunning() {
        let fake = FakeMenuWorld()
        let model = Self.model(fake)
        fake.with { $0.socketPresent = false }
        model.start()
        fake.settle()
        #expect(model.model.link == .notRunning)
        #expect(fake.with { $0.watchedPaths }.isEmpty)
        #expect(fake.pendingAfterDelays == [Backoff.first])
    }

    @Test("an update publishes the model, stamped with the world's clock")
    func updatePublishes() {
        let fake = FakeMenuWorld()
        let model = Self.connected(fake, to: Self.idle)
        let stamp = fake.with { $0.now }
        #expect(model.model == MenuModel(link: .connected, snapshot: Self.idle, receivedAt: stamp))
    }

    @Test("a clean end keeps the daemon's reason")
    func cleanEndKeepsTheReason() {
        let fake = FakeMenuWorld()
        let model = Self.model(fake)
        fake.script([.update(Self.idle),
                     WatchEvent(kind: .end, reason: "the daemon is shutting down")])
        model.start()
        fake.settle()
        #expect(model.model.link == .ended("the daemon is shutting down"))
        #expect(model.model.snapshot == nil)
    }

    @Test("a thrown watch schedules a backoff reconnect through after")
    func thrownWatchBacksOff() {
        let fake = FakeMenuWorld()
        let model = Self.model(fake)
        let crashed = ControlClient.ClientError.daemonCrashed(path: Self.socket)
        fake.script([], then: .throwing(crashed))
        model.start()
        fake.settle()
        #expect(model.model.link == .failed(crashed.description))
        #expect(fake.pendingAfterDelays == [Backoff.delay(afterFailures: 0)])

        // The delay elapsing reconnects; a second failure waits longer.
        fake.script([], then: .throwing(ControlClient.ClientError.daemonNotRunning(path: "x")))
        fake.fireAfter()
        #expect(fake.pendingOffMain == ["watch"])
        fake.settle()
        #expect(model.model.link == .notRunning)
        #expect(fake.pendingAfterDelays == [Backoff.delay(afterFailures: 1)])
        #expect(fake.with { $0.watchedPaths } == [Self.socket, Self.socket])
    }

    // MARK: - the ticker

    @Test("with the panel closed, a recording schedules the ticker and an end cancels it")
    func endCancelsTheTicker() {
        let fake = FakeMenuWorld()
        let model = Self.model(fake)
        fake.script([.update(Self.recording),
                     WatchEvent(kind: .end, reason: "the daemon is shutting down")])
        model.start()
        fake.runOffMain("watch")
        // Three hops wait: the update, the end, and the return. Landed one at a time, so the end
        // is shown to cancel the ticker on its own, before the returning thread reports anything.
        #expect(fake.heldMainHops == 3)
        fake.releaseMain(at: 0)
        #expect(fake.runningTickers == 1)
        #expect(fake.with { $0.tickers.map(\.interval) } == [1])
        fake.releaseMain(at: 0)
        #expect(model.model.link == .ended("the daemon is shutting down"))
        #expect(fake.runningTickers == 0)
        fake.settle()
        #expect(fake.runningTickers == 0)
    }

    @Test("with the panel closed, a watch that throws mid-recording cancels the ticker")
    func thrownWatchCancelsTheTicker() {
        let fake = FakeMenuWorld()
        let model = Self.model(fake)
        let crashed = ControlClient.ClientError.daemonCrashed(path: Self.socket)
        fake.script([.update(Self.recording)], then: .throwing(crashed))
        model.start()
        fake.runOffMain("watch")
        fake.releaseMain(at: 0)
        #expect(fake.runningTickers == 1)
        fake.settle()
        #expect(model.model.link == .failed(crashed.description))
        #expect(fake.runningTickers == 0)
        // The reconnect is still scheduled: stopping the second hand stops nothing else.
        #expect(fake.pendingAfterDelays == [Backoff.delay(afterFailures: 0)])
    }

    @Test("with the panel open, the ticker survives an end, a disconnect and a restart")
    func openPanelKeepsTheTicker() {
        let fake = FakeMenuWorld()
        let model = Self.model(fake)
        fake.script([.update(Self.recording),
                     WatchEvent(kind: .end, reason: "the daemon is shutting down")])
        model.start()
        model.panelAppeared()
        fake.settle()
        #expect(model.model.link == .ended("the daemon is shutting down"))
        #expect(fake.runningTickers == 1)

        // The drawer's relative times still need a second hand while nothing is connected.
        let later = fake.with { state -> Date in
            state.now += 5
            return state.now
        }
        fake.tick()
        #expect(model.now == later)

        // The daemon is gone when the backoff elapses...
        fake.script([], then: .throwing(ControlClient.ClientError.daemonNotRunning(path: "x")))
        fake.fireAfter()
        fake.settle()
        #expect(model.model.link == .notRunning)
        #expect(fake.runningTickers == 1)

        // ...and back, idle, when the next one does.
        fake.script([.update(Self.idle)], then: .open)
        fake.fireAfter()
        fake.settle()
        #expect(model.model.link == .connected)
        #expect(fake.runningTickers == 1)
        // The same ticker throughout: none was cancelled and scheduled again.
        #expect(fake.with { $0.tickers.count } == 1)

        model.panelDisappeared()
        #expect(fake.runningTickers == 0)
    }

    // MARK: - commands

    @Test("stopAndType and abort send requests naming the live attempt")
    func commandsNameTheAttempt() {
        let fake = FakeMenuWorld()
        let model = Self.connected(fake, to: Self.recording)
        fake.with { $0.readsAsked = [] }

        model.stopAndType()
        #expect(fake.pendingOffMain == ["command"])
        fake.settle()
        model.abort()
        fake.settle()
        #expect(fake.with { $0.sent } == [
            Request(cmd: .stop, mode: .clean, attempt: 7),
            Request(cmd: .abort, attempt: 7),
        ])
        #expect(fake.with { $0.sentPaths } == [Self.socket, Self.socket])
        // Each command's completion re-reads the record.
        #expect(fake.with { $0.readsAsked } == [Self.record, Self.record])
    }

    // MARK: - the effects

    @Test("openRecord reveals the injected record URL")
    func openRecordRevealsTheInjectedURL() {
        let fake = FakeMenuWorld()
        Self.model(fake).openRecord()
        #expect(fake.with { $0.revealed } == [Self.record])
    }

    @Test("the banner actions and copy reach their effects")
    func bannerActionsReachEffects() {
        let fake = FakeMenuWorld()
        let model = Self.model(fake)
        let presenter = FakeSetupPresenter()
        model.setupPresenter = presenter

        model.perform(.openMicrophoneSettings)
        #expect(fake.with { $0.opened } == [URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!])

        model.perform(.fetchModels)
        model.perform(.restartDaemon)
        #expect(fake.with { $0.ran } == [
            FakeMenuWorld.Run(executable: "/bin/sh", arguments: [
                "-c", "\"$HOME/Applications/Dicta.app/Contents/MacOS/Dicta\" --fetch-models"]),
            FakeMenuWorld.Run(executable: "/bin/launchctl", arguments: [
                "kickstart", "-k", "gui/\(getuid())/\(Paths.bundleID)"]),
        ])

        model.perform(.openSetup)
        #expect(presenter.shows == 1)

        model.copy("the delivered text")
        #expect(fake.with { $0.copied } == ["the delivered text"])
        // None of it went to the daemon.
        #expect(fake.with { $0.sent }.isEmpty)
    }

    // MARK: - the session name

    @Test("with no agterm found, the name lookup starts no work and the caption uses the id")
    func noAgtermStartsNoThread() {
        let fake = FakeMenuWorld()
        let model = Self.connected(fake, to: Self.recording)
        #expect(model.model.link == .connected)
        model.panelAppeared()
        #expect(!fake.pendingOffMain.contains("tree"))
        #expect(fake.with { $0.treesAsked }.isEmpty)
        #expect(model.targetCaption == Self.recording.target?.caption(name: nil))
    }

    @Test("a located agterm is asked once per session, and names the caption")
    func agtermNamesTheSession() {
        let fake = FakeMenuWorld()
        fake.with {
            $0.agterm = "/opt/agtermctl"
            $0.sessionNames = ["session-1": "dicta"]
        }
        let model = Self.model(fake)
        fake.script([.update(Self.recording)], then: .open)
        model.start()
        fake.runOffMain("watch")
        fake.releaseMain()
        #expect(fake.pendingOffMain.filter { $0 == "tree" }.count == 1)
        // A second ask while the first is in flight starts nothing.
        model.panelAppeared()
        #expect(fake.pendingOffMain.filter { $0 == "tree" }.count == 1)
        fake.runOffMain("tree")
        fake.releaseMain()
        #expect(fake.with { $0.treesAsked } == ["/opt/agtermctl"])
        #expect(model.targetCaption == Self.recording.target?.caption(name: "dicta"))

        // Known now: another look costs no subprocess.
        model.panelAppeared()
        #expect(!fake.pendingOffMain.contains("tree"))
    }
}
