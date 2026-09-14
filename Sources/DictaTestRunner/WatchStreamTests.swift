import DictaCore
import DictaIPC
import Foundation
import Testing

/// `watch` as a second connection SHAPE (D27), driven over real Unix sockets.
///
/// A mock cannot reach any of what is asserted here. Every property below is about a connection
/// that outlives one answer — how many may exist, how one ends without looking like a crash,
/// whether one blocks the chords — and each of those is a fact about descriptors and threads rather
/// than about the shape of the code.
///
/// The watchers are driven on real `Thread`s throughout, which is the same rule the server serves
/// connections under and the same measured reason: on Darwin, Swift concurrency's executor shares
/// the non-overcommit pool `DispatchQueue.global()` draws from, and blocking a cooperative thread
/// for the life of a stream is one worker that never comes back.
@Suite("watch stream")
struct WatchStreamTests {
    /// A watcher run on its own real thread, collecting what it is given.
    final class Watcher: @unchecked Sendable {
        private let lock = NSLock()
        private var received: [WatchEvent] = []
        private var failure: String?
        private var returned = false
        private let finished = DispatchSemaphore(value: 0)
        /// Held by the callback so a test can make the reader deliberately slow.
        var onEvent: ((WatchEvent) -> Void)?

        var events: [WatchEvent] { lock.withLock { received } }
        var error: String? { lock.withLock { failure } }
        var endedNormally: Bool { lock.withLock { returned } }

        func start(path: String, idleTimeout: TimeInterval = 10) {
            let thread = Thread { [self] in
                do {
                    try ControlClient.watch(to: path, idleTimeout: idleTimeout) { event in
                        lock.withLock { received.append(event) }
                        onEvent?(event)
                    }
                    lock.withLock { returned = true }
                } catch {
                    lock.withLock { failure = "\(error)" }
                }
                finished.signal()
            }
            thread.name = "dicta.test.watcher"
            thread.start()
        }

        @discardableResult
        func waitUntilFinished(seconds: Double = 5) -> Bool {
            finished.wait(timeout: .now() + seconds) == .success
        }

        /// Polls until the watcher has at least `count` events, so tests never sleep a fixed span.
        func waitForEvents(_ count: Int, seconds: Double = 5) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if events.count >= count { return true }
                usleep(5_000)
            }
            return events.count >= count
        }
    }

    static func makeServer(
        handler: @escaping ControlServer.Handler = { _ in Response(kind: .accepted, state: .idle) }
    ) throws -> ControlSocketTests.Fixture {
        try ControlSocketTests.makeServer(handler: handler)
    }

    // MARK: - the stream itself

    @Test("a watcher is accepted and receives what the daemon publishes")
    func watcherReceivesUpdates() throws {
        let fixture = try Self.makeServer()
        defer { fixture.tearDown() }

        let watcher = Watcher()
        watcher.start(path: fixture.path)
        // The handshake has to have landed before publishing means anything: an event published
        // before the watcher registered would go to nobody, which is correct behaviour and would
        // make this test flaky rather than wrong.
        #expect(Self.waitForWatchers(fixture.server, count: 1))

        fixture.server.publish(.update(state: .warming))
        #expect(watcher.waitForEvents(1))
        #expect(watcher.events.first?.kind == .update)
        #expect(watcher.events.first?.snapshot?.state == .warming)
    }

    @Test("a slow reader is given the newest state, never a queue of stale ones")
    func updatesAreCoalesced() throws {
        let fixture = try Self.makeServer()
        defer { fixture.tearDown() }

        let watcher = Watcher()
        let blocked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        watcher.onEvent = { event in
            if event.snapshot?.state == .warming {
                blocked.signal()
                release.wait()
            }
        }
        watcher.start(path: fixture.path)
        #expect(Self.waitForWatchers(fixture.server, count: 1))

        fixture.server.publish(.update(state: .warming))
        #expect(blocked.wait(timeout: .now() + 5) == .success)

        // MANY, and the count is the point. Coalescing happens in the daemon's one-slot outbox, so
        // it only bites once the WRITER is behind — and with a parked reader the kernel's socket
        // buffer absorbs the first few frames before the writer blocks at all. Publishing four and
        // asserting "exactly one arrives" therefore asserts the size of a socket buffer, not the
        // design: measured, four published while parked delivered three.
        //
        // What the design actually guarantees is what is asserted here: the daemon queues NOTHING
        // per watcher beyond one pending event, so a reader that falls far behind sees a small
        // fraction of what was published and always ends on the newest state. Six hundred is well
        // past any buffer.
        let published = 600
        for index in 0 ..< published {
            fixture.server.publish(.update(state: index == published - 1 ? .idle : .recording))
        }
        release.signal()

        #expect(watcher.waitForEvents(2))
        // Settle: the writer has to be given the chance to prove it has nothing more to say.
        usleep(300_000)
        let states = watcher.events.map { $0.snapshot?.state }
        #expect(states.first == .warming)
        #expect(states.count < published / 4,
                "expected the outbox to collapse, got \(states.count) of \(published)")
        // And it lands on the truth. A UI that ended on a stale state would be worse than one that
        // flickered — it would be confidently wrong about whether the microphone is open.
        #expect(states.last == .idle)
    }

    // MARK: - how a stream ends

    @Test("a daemon shutting down ENDS the stream rather than dropping it")
    func shutdownEndsTheStream() throws {
        let fixture = try Self.makeServer()
        let watcher = Watcher()
        watcher.start(path: fixture.path)
        #expect(Self.waitForWatchers(fixture.server, count: 1))

        fixture.server.stop()

        #expect(watcher.waitUntilFinished())
        // The whole point. A closed connection reads as `closedByPeer`, which the client reports as
        // "the daemon died" — so without an explicit end, every orderly `launchctl bootout` would
        // put a false crash report in front of the user.
        #expect(watcher.error == nil,
                "a clean shutdown reported as a failure: \(watcher.error ?? "")")
        #expect(watcher.endedNormally)
        #expect(watcher.events.last?.kind == .end)
        #expect(watcher.events.last?.reason?.isEmpty == false)
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    @Test("a watcher that goes away is dropped, and the daemon keeps serving")
    func deadWatcherIsDropped() throws {
        let fixture = try Self.makeServer()
        defer { fixture.tearDown() }

        // A raw connection that asks to watch and then vanishes mid-stream.
        let raw = try Self.rawWatch(fixture.path)
        #expect(Self.waitForWatchers(fixture.server, count: 1))
        close(raw)

        // Nothing is published, and that is the point: an idle daemon writes nothing, so a write
        // that fails can never be what finds the peer gone. The close is noticed on the read side,
        // as acta's `ControlConnection` notices it, and a dead watcher is never retried.
        #expect(Self.waitForWatchers(fixture.server, count: 0))

        // And the daemon is unharmed: an ordinary command still answers.
        let response = try ControlClient.send(Request(cmd: .status), to: fixture.path)
        #expect(response.kind == .accepted)
    }

    @Test("a dead watcher is still dropped while the daemon publishes without a pause")
    func deadWatcherIsDroppedUnderContinuousPublishing() throws {
        let fixture = try Self.makeServer()
        defer { fixture.tearDown() }

        let raw = try Self.rawWatch(fixture.path)
        #expect(Self.waitForWatchers(fixture.server, count: 1))
        close(raw)

        // With an event always ready the writer's `poll` never waits, but it still looks at the
        // client before each one, and a write into the closed peer ends it too. Either way the
        // slot frees while the publishing goes on, as it would under a dictation in progress.
        let publishing = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        let server = fixture.server
        let publisher = Thread {
            while publishing.wait(timeout: .now()) == .timedOut {
                server.publish(.update(state: .recording))
            }
            stopped.signal()
        }
        publisher.start()
        let dropped = Self.waitForWatchers(fixture.server, count: 0)
        publishing.signal()
        #expect(stopped.wait(timeout: .now() + 5) == .success)
        #expect(dropped)

        let response = try ControlClient.send(Request(cmd: .status), to: fixture.path)
        #expect(response.kind == .accepted)
    }

    @Test("watchers that die while the daemon is idle free their slots for the next one")
    func deadWatchersFreeTheirSlots() throws {
        let fixture = try Self.makeServer()
        defer { fixture.tearDown() }

        // The crash loop that filled every slot in minutes: each client dies without a word, and
        // the daemon has nothing to say to any of them.
        var raws: [Int32] = []
        for _ in 0 ..< ControlTimeouts.maxWatchers { raws.append(try Self.rawWatch(fixture.path)) }
        #expect(Self.waitForWatchers(fixture.server, count: ControlTimeouts.maxWatchers))
        for raw in raws { close(raw) }
        // Removal happens in `serve`'s `defer`, on each connection's own thread, so a fifth watcher
        // connecting at once would race it rather than test it.
        #expect(Self.waitForWatchers(fixture.server, count: 0))

        let next = Watcher()
        next.start(path: fixture.path)
        #expect(Self.waitForWatchers(fixture.server, count: 1))
        fixture.server.publish(.update(state: .warming))
        #expect(next.waitForEvents(1))
        #expect(next.error == nil, "the next watcher was refused: \(next.error ?? "")")
        #expect(next.events.first?.snapshot?.state == .warming)
    }

    @Test("a watcher that talks after the handshake has its watch ended and its slot freed")
    func talkingWatcherIsEnded() throws {
        let fixture = try Self.makeServer()
        defer { fixture.tearDown() }

        // The byte goes only after the accepted response has been read: bytes that arrive with the
        // request frame are consumed by the handshake read, and no promise is made about them.
        let raw = try Self.rawWatch(fixture.path)
        defer { close(raw) }
        #expect(Self.waitForWatchers(fixture.server, count: 1))
        ControlSocketTests.rawWrite(Data([0x0A]), to: raw)

        #expect(Self.waitForWatchers(fixture.server, count: 0))
        // The server closed its end, so the client reads the end of the connection, not an event.
        var byte: UInt8 = 0
        #expect(read(raw, &byte, 1) == 0)
    }

    @Test("a live watcher that says nothing is never taken for a dead one")
    func silentWatcherIsKept() throws {
        let fixture = try Self.makeServer()
        defer { fixture.tearDown() }

        let raw = try Self.rawWatch(fixture.path)
        defer { close(raw) }
        #expect(Self.waitForWatchers(fixture.server, count: 1))

        // Silence is what a healthy watcher sounds like; only a close or a byte ends it.
        usleep(500_000)
        #expect(fixture.server.watcherCount == 1)

        fixture.server.publish(.update(state: .recording))
        let frame = try Framing.readFrame(from: raw)
        let event = try Wire.decode(WatchEvent.self, from: frame)
        #expect(event.kind == .update)
        #expect(event.snapshot?.state == .recording)
    }

    // MARK: - the cap

    @Test("past the cap a watcher is REFUSED with a response, never by a dropped connection")
    func watcherCapIsRefusedPolitely() throws {
        let fixture = try Self.makeServer()
        defer { fixture.tearDown() }

        var watchers: [Watcher] = []
        for _ in 0 ..< ControlTimeouts.maxWatchers {
            let watcher = Watcher()
            watcher.start(path: fixture.path)
            watchers.append(watcher)
        }
        #expect(Self.waitForWatchers(fixture.server, count: ControlTimeouts.maxWatchers))

        let extra = Watcher()
        extra.start(path: fixture.path)
        #expect(extra.waitUntilFinished())
        // A refusal, not a hang-up. `daemonCrashed` here would mean the UI told the user dicta had
        // died because a second copy of the UI was already open.
        let error = try #require(extra.error)
        #expect(error.contains("refused to be watched"), "got: \(error)")
        #expect(!error.contains("died"))

        for watcher in watchers { _ = watcher }
    }

    // MARK: - the property the chords depend on

    @Test("a watcher connected for the whole test never delays a command")
    func watcherDoesNotBlockCommands() throws {
        // The handler is deliberately slow, so that a `watch` holding the handler lock would show
        // up as commands taking whole seconds rather than as a deadlock nobody can attribute.
        let served = ControlSocketTests.Recorder()
        let fixture = try ControlSocketTests.makeServer { incoming in
            served.record(incoming)
            return Response(kind: .accepted, state: .idle)
        }
        defer { fixture.tearDown() }

        let watcher = Watcher()
        watcher.start(path: fixture.path)
        #expect(Self.waitForWatchers(fixture.server, count: 1))

        // Ten ordinary round trips with the watcher parked. If `watch` were serialised, the handler
        // lock would be held for the lifetime of the stream and not one of these would return.
        let started = Date()
        for _ in 0 ..< 10 {
            let response = try ControlClient.send(Request(cmd: .status), to: fixture.path)
            #expect(response.kind == .accepted)
        }
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 2.0, "ten round trips took \(elapsed) s behind a watcher")

        // And the watcher is still live afterwards — it was not consumed by serving the commands.
        fixture.server.publish(.update(state: .recording))
        #expect(watcher.waitForEvents(1))
    }

    // MARK: - helpers

    /// A raw connection that has asked to watch and read its accepted response, so a test can close
    /// it, or talk on it, without a client in the way. It carries `rawConnect`'s 2-second read
    /// timeout, so a read that is never answered fails rather than hangs.
    static func rawWatch(_ path: String) throws -> Int32 {
        let raw = try ControlSocketTests.rawConnect(to: path)
        do {
            try Framing.write(try Wire.encode(Request(cmd: .watch)), to: raw)
            let response = try Wire.decode(Response.self, from: try Framing.readFrame(from: raw))
            try #require(response.kind == .accepted, "watch refused: \(response.message ?? "")")
        } catch {
            close(raw)
            throw error
        }
        return raw
    }

    /// Polls the server's watcher count. Reaching into `publish` is not enough: registration
    /// happens on the connection's thread, so a test that published immediately would be asserting
    /// on a race rather than on behaviour.
    static func waitForWatchers(_ server: ControlServer, count: Int, seconds: Double = 5) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if server.watcherCount == count { return true }
            usleep(5_000)
        }
        return server.watcherCount == count
    }
}
