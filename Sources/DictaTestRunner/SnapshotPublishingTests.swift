import DictaCore
import DictaIPC
import DictaRuntime
import Foundation
import Testing

/// The daemon feeding `watch` (D27), driven through a real socket with a real watcher on the far
/// end.
///
/// Everything here is about ORDER and about not being on the attempt path — neither of which a
/// unit test over `Daemon` alone could reach, because both are properties of what a second process
/// observes while the first is working.
@Suite("snapshot publishing")
struct SnapshotPublishingTests {
    struct Fixture {
        let daemon: Daemon
        let capture: FakeCapture?
        let resolver: FakeTargetResolver
        let path: String
        let directory: URL

        func tearDown() {
            daemon.stop()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func makeDaemon(capture: any Capture = FakeCapture()) throws -> Fixture {
        // `/tmp` rather than the per-user temp directory: `sun_path` is 104 bytes and the latter
        // plus a UUID is most of that budget already (`PathsTests` asserts the same about the real
        // socket).
        let directory = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("dicta-pub-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let resolver = FakeTargetResolver()
        resolver.setPane(.left)
        let daemon = Daemon(
            configuration: Daemon.Configuration(
                socketPath: directory.appendingPathComponent("c.sock").path,
                activeTargetFile: directory.appendingPathComponent("target.json")),
            capture: capture,
            transcriber: FakeTranscriber(),
            history: FakeHistory(),
            clock: FakeClock(),
            feedback: FakeNotifier(),
            terminal: { _ in
                Daemon.Terminal(resolver: resolver, injector: FakeInjector(),
                                notifier: FakeNotifier())
            }
        )
        try daemon.start()
        return Fixture(daemon: daemon, capture: capture as? FakeCapture, resolver: resolver,
                       path: directory.appendingPathComponent("c.sock").path,
                       directory: directory)
    }

    // MARK: - the stream tracks the lifecycle

    @Test("a dictation's states reach a watcher, in order")
    func transitionsAreStreamed() throws {
        let fixture = try Self.makeDaemon()
        defer { fixture.tearDown() }

        let watcher = WatchStreamTests.Watcher()
        watcher.start(path: fixture.path)
        #expect(Self.waitForWatchers(fixture, count: 1))

        // Attaching is its own first event and it precedes every transition — the state the
        // daemon is in at the instant the stream opens, which is what stops a UI drawing the last
        // thing it knew over a daemon that has since restarted.
        #expect(watcher.waitForEvents(1))
        #expect(watcher.events.first?.snapshot?.state == .idle)

        _ = fixture.daemon.handle(.request(Request(cmd: .toggle, sessionID: "S1")))
        #expect(Self.waitForState(watcher, .warming))

        // Capture confirms: only now is the microphone open, and only now may anything say so
        // (D13, invariant 4).
        fixture.capture?.reportReady(AttemptID(1))
        #expect(Self.waitForState(watcher, .recording))

        let states = watcher.events.compactMap { $0.snapshot?.state }
        #expect(states.prefix(3) == [.idle, .warming, .recording])
    }

    @Test("a stream never goes backwards")
    func sequencesAreMonotonic() throws {
        // `ImmediateCapture`, and the choice IS the test. It hands its audio over from inside
        // `drain`, exactly as the real `AudioCapture` does, so `.drainCapture` re-enters `apply`
        // and runs recognition, injection and the terminal transition before the outer effect loop
        // has finished. `FakeCapture` delivers only when a test tells it to, so with it this
        // assertion is vacuous — probed: moving `publish` after the effect loop leaves the whole
        // suite green on `FakeCapture`, and fails here.
        let fixture = try Self.makeDaemon(capture: ImmediateCapture())
        defer { fixture.tearDown() }

        let watcher = WatchStreamTests.Watcher()
        watcher.start(path: fixture.path)
        #expect(Self.waitForWatchers(fixture, count: 1))

        // One chord to start (capture confirms from inside `begin`), one to stop and deliver.
        _ = fixture.daemon.handle(.request(Request(cmd: .toggle, sessionID: "S1")))
        #expect(Self.waitForState(watcher, .recording))
        _ = fixture.daemon.handle(.request(Request(cmd: .toggle, sessionID: "S1")))
        #expect(Self.waitForState(watcher, .idle))

        let states = watcher.events.compactMap { $0.snapshot?.state }
        // The state the glyph exists for. This is what the probe kills: with `publish` moved after
        // the effect loop, the inner transitions bump the sequence first and the outer one is then
        // DROPPED as stale — so the red "listening" glyph never appears at all. The guard behaves
        // correctly there (it refuses to rewrite the UI backwards); the ordering is what makes it
        // unnecessary. A missing state is the symptom, going backwards is what is prevented.
        #expect(states.contains(.recording),
                "the recording state never reached the watcher: \(states)")

        let sequences = watcher.events.compactMap(\.sequence)
        #expect(sequences.count >= 3, "too few transitions reached the watcher: \(states)")
        #expect(sequences == sequences.sorted(),
                "the stream went backwards: \(sequences)")
        #expect(Set(sequences).count == sequences.count, "a transition was published twice")
        // The last word is the truth. A UI left on a stale state would be confidently wrong about
        // whether the microphone is open, which is worse than flickering.
        #expect(watcher.events.last?.snapshot?.state == .idle)
    }

    // MARK: - readiness

    @Test("readiness reaches the UI without a transition, and status agrees with the stream")
    func readinessIsPublished() throws {
        let fixture = try Self.makeDaemon()
        defer { fixture.tearDown() }

        let watcher = WatchStreamTests.Watcher()
        watcher.start(path: fixture.path)
        #expect(Self.waitForWatchers(fixture, count: 1))

        // Nothing has been established yet, so the daemon is starting rather than broken.
        let handshake = try ControlClient.send(Request(cmd: .status), to: fixture.path)
        #expect(handshake.snapshot?.readiness == .starting)

        fixture.daemon.observe { $0.microphone = false }
        #expect(Self.waitFor(watcher) { $0.readiness == .microphoneDenied })

        // The two routes are one function, so they cannot drift — a panel that opened saying
        // "Ready" and then admitted on its first event that the microphone was denied would be the
        // exact failure `snapshot()` exists to prevent.
        let after = try ControlClient.send(Request(cmd: .status), to: fixture.path)
        #expect(after.snapshot?.readiness == .microphoneDenied)
        #expect(after.snapshot?.state == watcher.events.last?.snapshot?.state)
    }

    @Test("a watcher is told the state it attached to, before anything has transitioned")
    func attachingIsItsOwnFirstEvent() throws {
        // The defect this closes was invisible to every other test here, because they all make
        // something happen and then look. The daemon publishes on TRANSITIONS, so a watcher that
        // attaches to an idle daemon and waits was told nothing at all — and after a daemon restart
        // the menu-bar strip went on saying "dicta is not answering" over a connection that had
        // been live for minutes. That lie sustains itself: nobody dictates at a strip that says
        // dicta is dead, and only a dictation would have corrected it (F9b).
        let fixture = try Self.makeDaemon()
        defer { fixture.tearDown() }

        let watcher = WatchStreamTests.Watcher()
        watcher.start(path: fixture.path)

        // Nothing is done to the daemon. The event has to come from attaching.
        #expect(watcher.waitForEvents(1))
        #expect(watcher.events.first?.kind == .update)
        #expect(watcher.events.first?.snapshot?.state == .idle)
        // Carries no sequence, which is already this protocol's word for "not a transition" — the
        // same thing a readiness change is, and the daemon never drops one for going backwards.
        #expect(watcher.events.first?.sequence == nil)
    }

    @Test("the cap travels with the snapshot")
    func capTravels() throws {
        let fixture = try Self.makeDaemon()
        defer { fixture.tearDown() }
        let response = try ControlClient.send(Request(cmd: .status), to: fixture.path)
        // So the UI can render `2:41 / 10:00` without a copy of the daemon's constants (D15).
        #expect(response.snapshot?.capSeconds == 600)
    }

    // MARK: - the property the chords depend on

    @Test("a watcher on the far end does not change what an attempt does")
    func watchingChangesNothing() throws {
        let fixture = try Self.makeDaemon()
        defer { fixture.tearDown() }

        let watcher = WatchStreamTests.Watcher()
        watcher.start(path: fixture.path)
        #expect(Self.waitForWatchers(fixture, count: 1))

        // D27's promise in its testable form: the daemon holds no reference to the UI and nothing
        // it does for a dictation may wait on one. The attempt resolves identically whether or not
        // anybody is looking.
        let started = fixture.daemon.handle(.request(Request(cmd: .toggle, sessionID: "S1")))
        #expect(started.kind == .accepted)
        fixture.capture?.reportReady(AttemptID(1))
        #expect(Self.waitForState(watcher, .recording))
        let stopped = fixture.daemon.handle(.request(Request(cmd: .toggle, sessionID: "S1")))
        #expect(stopped.kind == .accepted)
        fixture.capture?.reportDrained(AttemptID(1))
        #expect(Self.waitForState(watcher, .idle))
        #expect(fixture.daemon.state == .idle)
    }

    // MARK: - helpers

    /// Polls the daemon's watcher count: registration happens on the connection's own thread.
    static func waitForWatchers(_ fixture: Fixture, count: Int, seconds: Double = 5) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if fixture.daemon.watcherCount == count { return true }
            usleep(5_000)
        }
        return fixture.daemon.watcherCount == count
    }

    static func waitForState(_ watcher: WatchStreamTests.Watcher,
                             _ state: LifecycleState,
                             seconds: Double = 5) -> Bool {
        waitFor(watcher, seconds: seconds) { $0.state == state }
    }

    static func waitFor(_ watcher: WatchStreamTests.Watcher,
                        seconds: Double = 5,
                        _ matches: (StatusSnapshot) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let snapshot = watcher.events.last?.snapshot, matches(snapshot) { return true }
            usleep(5_000)
        }
        return watcher.events.last?.snapshot.map(matches) ?? false
    }
}
