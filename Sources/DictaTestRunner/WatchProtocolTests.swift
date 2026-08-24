import DictaCore
import DictaIPC
import Foundation
import Testing

/// The pure half of `watch` (D27): the vocabulary, the concurrency test, and the timeout that had
/// to be invented rather than reused.
@Suite("watch protocol")
struct WatchProtocolTests {
    @Test("watch is served concurrently, and the list is a test rather than a habit")
    func watchIsConcurrent() {
        #expect(Command.watch.isServedConcurrently)
        // The other two members, so a change to any of them is visible here rather than only in a
        // deadlock. The test the list encodes: does the verb begin an attempt or end one?
        #expect(Command.abort.isServedConcurrently)
        #expect(Command.dictate.isServedConcurrently)
        for command in [Command.status, .toggle, .start, .stop, .last] {
            #expect(!command.isServedConcurrently, "\(command.rawValue) must stay serialised (D7)")
        }
    }

    @Test("watch raises no desktop notification when it cannot connect")
    func watchIsNotShoutedAbout() {
        // Sent by a long-lived program that renders the answer, so the failure already has an
        // audience — the UI's own window. §7's notification exists for a chord, whose stderr goes
        // nowhere.
        #expect(Command.watch.isTypedByHand)
    }

    @Test("the stream's idle timeout is its own number, not one borrowed from a one-answer verb")
    func idleTimeoutIsDistinct() {
        // The point of the assertion is the INEQUALITY. Every other value here means "how long
        // may one answer take"; a watcher waits for a person to press a key, which they may not do
        // for hours, and `clientRead` would call such a daemon dead in three seconds.
        #expect(ControlTimeouts.watchIdle > ControlTimeouts.clientRead)
        #expect(ControlTimeouts.watchIdle > ControlTimeouts.pipelineRead)
        #expect(ControlTimeouts.watchIdle > ControlTimeouts.dictateWait)
    }

    @Test("the handshake keeps the short timeout, and no chord verb inherits the stream's")
    func handshakeTimeoutIsShort() {
        // `watch`'s FIRST frame is an ordinary accept-or-refuse response and arrives as fast as the
        // daemon can take its lock. Only what follows is long-lived, and that is applied by the
        // watching client rather than looked up per verb: one number cannot say "short then long".
        #expect(ControlTimeouts.read(for: .watch) == ControlTimeouts.clientRead)
        for command in [Command.stop, .toggle, .start, .abort] {
            #expect(ControlTimeouts.read(for: command) != ControlTimeouts.watchIdle,
                    "\(command.rawValue) must not inherit the stream's idle timeout")
        }
    }

    @Test("the watcher cap exists and is small")
    func watcherCapIsBounded() {
        // It exists because a watcher breaks the premise every other connection rests on: they are
        // momentary, so "how many can there be" needed no answer. This is the answer.
        #expect(ControlTimeouts.maxWatchers >= 1)
        #expect(ControlTimeouts.maxWatchers <= 8)
    }

    @Test("a watch event round-trips: an update carries a snapshot, an end carries a reason")
    func eventRoundTrip() throws {
        let snapshot = StatusSnapshot(state: .recording,
                                      readiness: .ready,
                                      attempt: AttemptID(7),
                                      target: Target(sessionID: "s", pane: .left),
                                      speakingSeconds: 12.5,
                                      capSeconds: 600)
        let update = WatchEvent.update(snapshot, sequence: 9)
        let decoded = try Wire.decode(WatchEvent.self, from: try Wire.encode(update))
        #expect(decoded == update)
        #expect(decoded.snapshot?.state == .recording)
        #expect(decoded.snapshot?.speakingSeconds == 12.5)
        #expect(decoded.sequence == 9)
        #expect(decoded.reason == nil)

        let end = WatchEvent.end("the daemon is shutting down")
        let decodedEnd = try Wire.decode(WatchEvent.self, from: try Wire.encode(end))
        #expect(decodedEnd == end)
        // No snapshot on an end: there is nothing true to say about the state of a daemon that has
        // stopped, and a stale one would be worse than none.
        #expect(decodedEnd.snapshot == nil)
        #expect(decodedEnd.reason == "the daemon is shutting down")
    }

    @Test("watch takes only the flags about reaching the daemon")
    func watchParsesWithoutAttemptFlags() throws {
        let parsed = try #require(try? ClientCommand.parse(["watch"]).get())
        #expect(parsed.request.cmd == .watch)
        #expect(parsed.request.mode == nil)
        #expect(parsed.request.sessionID == nil)

        let withControl = try #require(try? ClientCommand.parse(["watch", "--control", "/x"]).get())
        #expect(withControl.controlSocket == "/x")

        // It names no attempt, chooses no mode and pins no session, because it changes nothing.
        #expect((try? ClientCommand.parse(["watch", "--mode", "raw"]).get()) == nil)
        #expect((try? ClientCommand.parse(["watch", "--session", "s"]).get()) == nil)
    }
}
