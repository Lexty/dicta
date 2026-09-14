import DictaCore
import DictaIPC
import DictaMenuKit
import DictaRecord
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

    @Test("a refused watch is drawn as a refusal, and every other thrown error still as a failure")
    func refusedWatchIsNotAFailure() {
        let fake = FakeMenuWorld()
        let model = Self.model(fake)
        let reason = "dicta is already serving 4 watchers"
        fake.script([], then: .throwing(ControlClient.ClientError.watchRefused(reason)))
        model.start()
        fake.settle()
        #expect(model.model.link == .refused(reason))
        #expect(model.model.snapshot == nil)

        let slow = ControlClient.ClientError.timedOut(seconds: 2)
        fake.script([], then: .throwing(slow))
        fake.fireAfter()
        fake.settle()
        #expect(model.model.link == .failed(slow.description))
    }

    @Test("a refused watch retries through after, and a later accepted watch connects")
    func refusedWatchRetries() {
        let fake = FakeMenuWorld()
        let model = Self.model(fake)
        let refusal = ControlClient.ClientError.watchRefused("dicta is already serving 4 watchers")
        fake.script([], then: .throwing(refusal))
        model.start()
        fake.settle()
        #expect(model.model.link == .refused("dicta is already serving 4 watchers"))
        // A slot frees when a watcher goes, so the refusal is retried like any other lost link.
        #expect(fake.pendingAfterDelays == [Backoff.delay(afterFailures: 0)])

        fake.script([.update(Self.idle)], then: .open)
        fake.fireAfter()
        #expect(fake.pendingOffMain == ["watch"])
        fake.settle()
        #expect(model.model.link == .connected)
        #expect(model.model.snapshot == Self.idle)
        #expect(fake.with { $0.watchedPaths } == [Self.socket, Self.socket])
    }

    @Test("an event resets the backoff, and a leftover after while connected opens nothing")
    func eventResetsTheBackoff() {
        let fake = FakeMenuWorld()
        let model = Self.model(fake)
        let crashed = ControlClient.ClientError.daemonCrashed(path: Self.socket)
        fake.script([], then: .throwing(crashed))
        model.start()
        fake.settle()
        fake.script([], then: .throwing(crashed))
        fake.fireAfter()
        fake.settle()
        #expect(fake.pendingAfterDelays == [Backoff.delay(afterFailures: 1)])

        // Connected once, then lost: the wait starts over from the first delay, not the longest.
        fake.script([.update(Self.idle)], then: .throwing(crashed))
        fake.fireAfter()
        fake.settle()
        #expect(model.model.link == .failed(crashed.description))
        #expect(fake.pendingAfterDelays == [Backoff.delay(afterFailures: 0)])

        // A failure landing before the update it followed leaves a reconnect pending over a live
        // link. Its delay elapsing must not open a second stream.
        fake.script([.update(Self.idle)], then: .throwing(crashed))
        fake.fireAfter()
        fake.runOffMain("watch")
        #expect(fake.heldMainHops == 2)
        fake.releaseMain(at: 1)
        fake.releaseMain(at: 0)
        #expect(model.model.link == .connected)
        #expect(fake.pendingAfterDelays.count == 1)
        fake.fireAfter()
        #expect(!fake.pendingOffMain.contains("watch"))
        #expect(fake.with { $0.watchedPaths }.count == 4)
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

    @Test("with the panel closed, processing stops the ticker and warming never starts it")
    func onlyRecordingRunsTheTicker() {
        let fake = FakeMenuWorld()
        let model = Self.model(fake)
        fake.script([.update(StatusSnapshot(state: .warming)), .update(Self.recording),
                     .update(StatusSnapshot(state: .processing)), .update(Self.idle)],
                    then: .open)
        model.start()
        fake.runOffMain("watch")
        fake.releaseMain(at: 0)
        #expect(fake.with { $0.tickers }.isEmpty)
        fake.releaseMain(at: 0)
        #expect(fake.runningTickers == 1)
        // The ordinary way a clock stops: the microphone closes, and the link stays up.
        fake.releaseMain(at: 0)
        #expect(model.model.snapshot?.state == .processing)
        #expect(fake.runningTickers == 0)
        fake.settle()
        #expect(model.model.link == .connected)
        #expect(fake.runningTickers == 0)
        #expect(fake.with { $0.tickers.count } == 1)
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

    // MARK: - the record reads

    /// Two record reads, started in order and each already answered off the main actor, whose
    /// publications are still held. `older` was read first, `newer` second.
    static func twoHeldReads(_ fake: FakeMenuWorld, older: [RecordEntry],
                             newer: [RecordEntry]) -> StatusViewModel {
        twoHeldReads(fake, older: .success(older), newer: .success(newer))
    }

    /// Two held reads, as above, whose answers may be failures.
    static func twoHeldReads(_ fake: FakeMenuWorld, older: Result<[RecordEntry], any Error>,
                             newer: Result<[RecordEntry], any Error>) -> StatusViewModel {
        let model = model(fake)
        fake.with { $0.reads = [older, newer] }
        model.start()
        model.panelAppeared()
        #expect(fake.pendingOffMain == ["watch", "record", "record"])
        fake.runOffMain("record")
        #expect(fake.heldMainHops == 2)
        return model
    }

    @Test("an older read published late does not roll the drawer back")
    func olderReadLandingLateIsDropped() {
        let fake = FakeMenuWorld()
        let older = [DictationRowTests.entry(id: 1)]
        let newer = [DictationRowTests.entry(id: 1), DictationRowTests.entry(id: 2)]
        let model = Self.twoHeldReads(fake, older: older, newer: newer)
        // The race is slow publication, not a slow read: both reads finished in order, and the
        // newer one's hop lands first.
        fake.releaseMain(at: 1)
        #expect(model.recentState == .read(DictationRow.rows(from: newer)))
        fake.releaseMain(at: 0)
        #expect(model.recentState == .read(DictationRow.rows(from: newer)))
    }

    @Test("reads published in order leave the latest")
    func readsInOrderPublishTheLatest() {
        let fake = FakeMenuWorld()
        let older = [DictationRowTests.entry(id: 1)]
        let newer = [DictationRowTests.entry(id: 1), DictationRowTests.entry(id: 2)]
        let model = Self.twoHeldReads(fake, older: older, newer: newer)
        fake.releaseMain(at: 0)
        #expect(model.recentState == .read(DictationRow.rows(from: older)))
        fake.releaseMain(at: 0)
        #expect(model.recentState == .read(DictationRow.rows(from: newer)))
    }

    @Test("a single read publishes its rows")
    func singleReadPublishes() {
        let fake = FakeMenuWorld()
        let entries = [DictationRowTests.entry(id: 3), DictationRowTests.entry(id: 4)]
        fake.with { $0.reads = [.success(entries)] }
        let model = Self.model(fake)
        #expect(model.recentState == .unread)
        model.start()
        fake.runOffMain("record")
        #expect(model.recentState == .unread)
        fake.releaseMain()
        #expect(model.recentState == .read(DictationRow.rows(from: entries)))
        #expect(model.recentState.rows.map(\.id) == [4, 3])
    }

    static let unreadable = RecordReader.ReaderError.cannotRead(
        path: record.path, reason: "it could not be opened")

    @Test("a record that cannot be read is a failure with its reason, not an empty record")
    func unreadableRecordIsAFailure() {
        let fake = FakeMenuWorld()
        fake.with { $0.reads = [.failure(Self.unreadable)] }
        let model = Self.model(fake)
        model.start()
        fake.runOffMain("record")
        fake.releaseMain()
        #expect(model.recentState == .failed(reason: "it could not be opened", lastGood: []))
        #expect(!model.recentState.saysNothingYet)
        // The path is always the same known file, and would eat the panel's line.
        #expect(model.recentState.failure?.contains(Self.record.path) == false)
    }

    @Test("an older failing read landing after a newer success leaves the newer rows")
    func olderFailureLandingLateIsDropped() {
        let fake = FakeMenuWorld()
        let newer = [DictationRowTests.entry(id: 5)]
        let model = Self.twoHeldReads(fake, older: .failure(Self.unreadable),
                                      newer: .success(newer))
        fake.releaseMain(at: 1)
        fake.releaseMain(at: 0)
        #expect(model.recentState == .read(DictationRow.rows(from: newer)))
    }

    @Test("an older success landing after a newer failure keeps the failure")
    func olderSuccessLandingLateIsDropped() {
        let fake = FakeMenuWorld()
        let older = [DictationRowTests.entry(id: 5)]
        let model = Self.twoHeldReads(fake, older: .success(older),
                                      newer: .failure(Self.unreadable))
        fake.releaseMain(at: 1)
        fake.releaseMain(at: 0)
        #expect(model.recentState == .failed(reason: "it could not be opened", lastGood: []))
    }

    @Test("any other read error is shown by its description")
    func otherErrorsUseTheirDescription() {
        let fake = FakeMenuWorld()
        let other = ControlClient.ClientError.daemonNotRunning(path: "elsewhere")
        fake.with { $0.reads = [.failure(other)] }
        let model = Self.model(fake)
        model.start()
        fake.runOffMain("record")
        fake.releaseMain()
        #expect(model.recentState == .failed(reason: other.description, lastGood: []))
    }

    @Test("a record readable again clears the failure")
    func readableAgainClearsTheFailure() {
        let fake = FakeMenuWorld()
        let entries = [DictationRowTests.entry(id: 8)]
        fake.with { $0.reads = [.failure(Self.unreadable), .success(entries)] }
        let model = Self.model(fake)
        model.start()
        fake.settle()
        #expect(model.recentState.failure != nil)
        model.panelAppeared()
        fake.settle()
        #expect(model.recentState == .read(DictationRow.rows(from: entries)))
        #expect(model.recentState.failure == nil)
    }

    @Test("success, failure, failure, recovery: the last good rows hold until the record reads")
    func failuresKeepTheLastGoodRows() {
        let fake = FakeMenuWorld()
        let first = [DictationRowTests.entry(id: 1), DictationRowTests.entry(id: 2)]
        let recovered = [DictationRowTests.entry(id: 2), DictationRowTests.entry(id: 3)]
        let denied = RecordReader.ReaderError.cannotRead(
            path: Self.record.path, reason: "Operation not permitted")
        fake.with {
            $0.reads = [.success(first), .failure(Self.unreadable), .failure(denied),
                        .success(recovered)]
        }
        let model = Self.model(fake)
        let firstRows = DictationRow.rows(from: first)

        model.start()
        fake.settle()
        #expect(model.recentState == .read(firstRows))

        model.panelAppeared()
        fake.settle()
        #expect(model.recentState == .failed(reason: "it could not be opened", lastGood: firstRows))

        // The second failure says its own reason, and still holds the first success's rows.
        model.panelAppeared()
        fake.settle()
        #expect(model.recentState
            == .failed(reason: "Operation not permitted", lastGood: firstRows))

        model.panelAppeared()
        fake.settle()
        #expect(model.recentState == .read(DictationRow.rows(from: recovered)))
        #expect(fake.with { $0.reads }.isEmpty)
    }

    @Test("an attempt ending re-reads the record, and an idle update that ends nothing does not")
    func attemptEndingRereads() {
        let fake = FakeMenuWorld()
        let model = Self.model(fake)
        fake.script([.update(Self.idle), .update(Self.idle), .update(Self.recording),
                     .update(Self.idle)], then: .open)
        model.start()
        fake.runOffMain()
        #expect(fake.with { $0.readsAsked } == [Self.record])
        #expect(fake.heldMainHops == 5)
        // The first snapshot has no state before it, and the second follows an idle one.
        fake.releaseMain(at: 0)
        fake.releaseMain(at: 0)
        #expect(fake.pendingOffMain.isEmpty)
        fake.releaseMain(at: 0)
        #expect(fake.pendingOffMain.isEmpty)
        // Idle after a recording: the entry is already on disk, so the drawer reads it.
        fake.releaseMain(at: 0)
        #expect(fake.pendingOffMain == ["record"])
        fake.settle()
        #expect(fake.with { $0.readsAsked } == [Self.record, Self.record])
        #expect(model.model.snapshot == Self.idle)
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

    @Test("a command that fails to reach the daemon still re-reads the record")
    func failedCommandStillRereads() {
        let fake = FakeMenuWorld()
        let model = Self.connected(fake, to: Self.recording)
        fake.with {
            $0.readsAsked = []
            $0.sendErrors = [ControlClient.ClientError.daemonNotRunning(path: Self.socket)]
        }
        model.stopAndType()
        fake.settle()
        #expect(fake.with { $0.sent } == [Request(cmd: .stop, mode: .clean, attempt: 7)])
        #expect(fake.with { $0.readsAsked } == [Self.record])
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

    // MARK: - the setup window

    /// An idle snapshot with a choice pending, which is what opens the window by itself.
    static let pending = SetupModelTests.snapshot(.undecided)

    /// A model with a fake presenter attached before `start()`, as `MenuRoot` attaches its own.
    static func presented(_ fake: FakeMenuWorld) -> (StatusViewModel, FakeSetupPresenter) {
        let model = model(fake)
        let presenter = FakeSetupPresenter()
        model.setupPresenter = presenter
        return (model, presenter)
    }

    /// The requests `world.send` has received, once `count` have arrived.
    ///
    /// The setup window's requests go through the view model's real `OrderedSender`, whose worker
    /// is a real `Thread` the fake does not hold, so this waits on the fake's arrivals with a
    /// timeout. A request that should NOT be sent is checked by sending a later one that should,
    /// and finding it alone: the sender keeps order, so the first would have arrived before it.
    static func sent(_ fake: FakeMenuWorld, count: Int,
                     sourceLocation: SourceLocation = #_sourceLocation) -> [Request] {
        let arrived = fake.waitUntil { $0.sent.count >= count }
        #expect(arrived, "the setup sender delivered too few requests",
                sourceLocation: sourceLocation)
        return fake.with { $0.sent }
    }

    @Test("an idle first snapshot with a choice pending shows the window once")
    func idlePendingFirstSnapshotShows() {
        let fake = FakeMenuWorld()
        let (model, presenter) = Self.presented(fake)
        fake.script([.update(Self.pending), .update(Self.pending)], then: .open)
        model.start()
        fake.runOffMain("watch")
        fake.releaseMain(at: 0)
        #expect(presenter.shows == 1)
        // The same pending snapshot again is not the first of this launch.
        fake.settle()
        #expect(presenter.shows == 1)
    }

    @Test("a busy first snapshot never shows the window, and neither does a later idle one")
    func busyFirstSnapshotConsumesTheLatch() {
        let fake = FakeMenuWorld()
        let (model, presenter) = Self.presented(fake)
        let busy = SetupModelTests.snapshot(.undecided, state: .recording)
        fake.script([.update(busy), .update(Self.pending)], then: .open)
        model.start()
        fake.settle()
        #expect(model.model.snapshot == Self.pending)
        #expect(presenter.shows == 0)
    }

    @Test("a reconnect followed by a second pending snapshot shows nothing")
    func reconnectDoesNotReopen() {
        let fake = FakeMenuWorld()
        let (model, presenter) = Self.presented(fake)
        let crashed = ControlClient.ClientError.daemonCrashed(path: Self.socket)
        fake.script([.update(Self.pending)], then: .throwing(crashed))
        model.start()
        fake.settle()
        #expect(presenter.shows == 1)
        #expect(model.model.link == .failed(crashed.description))

        fake.script([.update(Self.pending)], then: .open)
        fake.fireAfter()
        fake.settle()
        #expect(model.model.link == .connected)
        #expect(presenter.shows == 1)
    }

    @Test("a presenter attached after the first snapshot never gets that launch's open")
    func latePresenterMissesTheOpen() {
        let fake = FakeMenuWorld()
        let model = Self.model(fake)
        fake.script([.update(Self.pending), .update(Self.pending)], then: .open)
        model.start()
        fake.runOffMain("watch")
        fake.releaseMain(at: 0)
        // Why `MenuRoot` attaches the presenter before anything can call `start()`: the latch was
        // consumed with nobody to show, and a later snapshot may not retry (D27).
        let presenter = FakeSetupPresenter()
        model.setupPresenter = presenter
        fake.settle()
        #expect(model.model.snapshot == Self.pending)
        #expect(presenter.shows == 0)
    }

    @Test("openSetup, the banner's Set Up action and perform(.openSetup) all show the window")
    func everyDoorShowsTheWindow() throws {
        let fake = FakeMenuWorld()
        let (model, presenter) = Self.presented(fake)
        model.openSetup()
        #expect(presenter.shows == 1)
        model.perform(.openSetup)
        #expect(presenter.shows == 2)

        // A setup step pending after the first snapshot: the banner offers "Set Up…", and its
        // action is the same door. The footer's "Set Up…" row calls `openSetup()`, which
        // `MenuBundleTests` reads.
        let needed = StatusSnapshot(state: .idle, readiness: .setupNeeded,
                                    setup: SetupSnapshot(scope: .undecided, offerSeen: false))
        let busy = StatusSnapshot(state: .recording)
        fake.script([.update(busy), .update(needed)], then: .open)
        model.start()
        fake.settle()
        #expect(presenter.shows == 2)
        let banner = try #require(model.model.banner)
        #expect(banner.actionTitle == "Set Up…")
        model.perform(try #require(banner.action))
        #expect(presenter.shows == 3)
        #expect(fake.with { $0.sent }.isEmpty)
    }

    @Test("with the link down, openSetup still shows the window, on the unavailable screen")
    func linkDownStillShowsTheWindow() {
        let fake = FakeMenuWorld()
        fake.with { $0.socketPresent = false }
        let (model, presenter) = Self.presented(fake)
        model.start()
        fake.settle()
        #expect(model.model.link == .notRunning)
        model.openSetup()
        #expect(presenter.shows == 1)
        #expect(model.setup.screen == .unavailable)
    }

    @Test("a click on the fresh screen hands SetupModel's request to world.send")
    func freshClickSendsTheModelsRequest() {
        let fake = FakeMenuWorld()
        let model = Self.connected(fake, to: Self.pending)
        let expected = model.setup.effect(of: .setUpDictation).request
        #expect(expected == SetupModelTests.configureOtherApps)
        model.setupClicked(.setUpDictation)
        #expect(Self.sent(fake, count: 1) == [SetupModelTests.configureOtherApps])
        #expect(fake.with { $0.sentPaths } == [Self.socket])
    }

    @Test("two different clicks arrive at world.send in click order")
    func clicksArriveInOrder() {
        let fake = FakeMenuWorld()
        let model = Self.connected(fake, to: Self.pending)
        // Waits on the real sender's worker thread, with a timeout (`sent`). Ordering under a held
        // transport is `OrderedSenderTests`'; this pins that the model uses the sender at all.
        model.setupClicked(.setUpDictation)
        model.setupClicked(.useOnlyWithAgterm)
        #expect(Self.sent(fake, count: 2)
            == [SetupModelTests.configureOtherApps, SetupModelTests.configureAgtermOnly])
    }

    @Test("a click after one that failed to send still arrives")
    func clickAfterAFailedSendArrives() {
        let fake = FakeMenuWorld()
        let model = Self.connected(fake, to: Self.pending)
        fake.with {
            $0.sendErrors = [ControlClient.ClientError.daemonNotRunning(path: Self.socket)]
        }
        model.setupClicked(.setUpDictation)
        model.setupClicked(.useOnlyWithAgterm)
        #expect(Self.sent(fake, count: 2)
            == [SetupModelTests.configureOtherApps, SetupModelTests.configureAgtermOnly])
    }

    @Test("Allow Access flips accessibilityRequested, and the row then opens the pane")
    func allowAccessFlipsTheRequest() {
        let fake = FakeMenuWorld()
        let checklist = SetupModelTests.snapshot(
            .otherApps, faculties: Faculties(microphone: true, models: true, terminal: true,
                                             scope: .otherApps, accessibility: false))
        let model = Self.connected(fake, to: checklist)
        #expect(!model.accessibilityRequested)
        // Not drawn yet, so not a click: nothing flips.
        model.setupClicked(.openAccessibilitySettings)
        #expect(!model.accessibilityRequested)

        model.setupClicked(.allowAccess)
        #expect(model.accessibilityRequested)
        #expect(Self.sent(fake, count: 1) == [SetupModelTests.prompt])

        model.setupClicked(.openAccessibilitySettings)
        #expect(Self.sent(fake, count: 2) == [SetupModelTests.prompt, SetupModelTests.check])
        #expect(fake.with { $0.opened } == [SetupModel.accessibilitySettings])
    }

    @Test("becoming key checks the grant without a prompt, under other-apps only")
    func becomingKeyChecksUnderOtherAppsOnly() {
        let otherApps = FakeMenuWorld()
        let checking = Self.connected(otherApps, to: SetupModelTests.snapshot(.otherApps))
        checking.setupBecameKey()
        #expect(Self.sent(otherApps, count: 1) == [SetupModelTests.check])

        let fresh = FakeMenuWorld()
        let quiet = Self.connected(fresh, to: Self.pending)
        quiet.setupBecameKey()
        // The later click arriving alone shows becoming key sent nothing before it.
        quiet.setupClicked(.setUpDictation)
        #expect(Self.sent(fresh, count: 1) == [SetupModelTests.configureOtherApps])
    }

    @Test("closing sends offerSeen only on the first-time offer")
    func closingRecordsOnlyTheFirstOffer() {
        let offer = FakeMenuWorld()
        let firstTime = Self.connected(offer, to: SetupModelTests.snapshot(.agtermOnly))
        #expect(firstTime.setup.screen == .offer(firstTime: true))
        firstTime.setupClosed()
        #expect(Self.sent(offer, count: 1) == [SetupModelTests.configureOfferSeen])

        let seen = FakeMenuWorld()
        let later = Self.connected(seen, to: SetupModelTests.snapshot(.agtermOnly, offerSeen: true))
        later.setupClosed()
        later.setupClicked(.enable)
        #expect(Self.sent(seen, count: 1) == [SetupModelTests.configureOtherApps])

        let fresh = FakeMenuWorld()
        let unanswered = Self.connected(fresh, to: Self.pending)
        unanswered.setupClosed()
        unanswered.setupClicked(.setUpDictation)
        #expect(Self.sent(fresh, count: 1) == [SetupModelTests.configureOtherApps])
    }

    @Test("a control the screen no longer draws sends nothing")
    func undrawnControlSendsNothing() {
        let fake = FakeMenuWorld()
        let model = Self.connected(fake, to: Self.pending)
        // The fresh screen draws neither: a click that landed after the stream replaced the screen.
        model.setupClicked(.keepAgtermOnly)
        model.setupClicked(.fetchModels)
        model.setupClicked(.setUpDictation)
        #expect(Self.sent(fake, count: 1) == [SetupModelTests.configureOtherApps])
        #expect(fake.with { $0.ran }.isEmpty)
        #expect(fake.with { $0.opened }.isEmpty)
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

    @Test("a focused-field target starts no name lookup and is captioned by its application")
    func focusedFieldNeedsNoLookup() {
        let fake = FakeMenuWorld()
        fake.with { $0.agterm = "/opt/agtermctl" }
        let field = Target.focusedField(
            FieldTarget(bundleID: "com.microsoft.VSCode", appName: "Code", pid: 4242))
        let model = Self.connected(
            fake, to: StatusSnapshot(state: .recording, attempt: 8, target: field))
        model.panelAppeared()
        #expect(!fake.pendingOffMain.contains("tree"))
        #expect(fake.with { $0.treesAsked }.isEmpty)
        #expect(model.targetCaption == "Code")
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
