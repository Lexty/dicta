import DictaCore
import DictaIPC
import Foundation
import Testing

/// The transport, driven over real Unix sockets rather than over a mock of one.
///
/// A mock would assert the shape of the code and nothing about the two things that actually go
/// wrong here: what a hostile or half-dead peer does to the other end, and whether the framing
/// rules the two halves apply are the same rules. Both need a descriptor.
@Suite("control socket")
struct ControlSocketTests {
    // MARK: - harness

    /// Sockets live under `/tmp` and not under `FileManager.temporaryDirectory`, for the reason
    /// `PathsTests` asserts about the real socket: `sun_path` is 104 bytes, and the per-user temp
    /// directory plus a UUID is already most of that budget.
    static func temporaryDirectory() -> URL {
        let name = "dicta-ipc-\(UUID().uuidString.prefix(8))"
        return URL(fileURLWithPath: "/tmp").appendingPathComponent(name, isDirectory: true)
    }

    struct Fixture {
        let server: ControlServer
        let path: String
        let directory: URL

        func tearDown() {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func makeServer(
        readTimeout: TimeInterval = ControlTimeouts.serverRead,
        handler: @escaping ControlServer.Handler
    ) throws -> Fixture {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("c.sock").path
        let server = ControlServer(path: path, readTimeout: readTimeout, handler: handler)
        try server.start()
        return Fixture(server: server, path: path, directory: directory)
    }

    /// Everything the server was handed, in order.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ControlServer.Incoming] = []

        func record(_ item: ControlServer.Incoming) { lock.withLock { items.append(item) } }
        var all: [ControlServer.Incoming] { lock.withLock { items } }
    }

    /// A connection made without `ControlClient`, so a test can put bytes on the wire that the
    /// client half would never produce.
    static func rawConnect(to path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, size)
            }
        }
        try #require(connected == 0, "connect() failed with errno \(errno)")
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
        return descriptor
    }

    static func rawWrite(_ bytes: Data, to descriptor: Int32) {
        _ = bytes.withUnsafeBytes { raw in Darwin.write(descriptor, raw.baseAddress, raw.count) }
    }

    /// A frame larger than a socket buffer has to be written by somebody other than the thread that
    /// is going to read it. A real thread rather than `DispatchQueue.global()`, for the same reason
    /// `ControlServer` uses one: swift-testing runs these cases in parallel on the very pool that
    /// queue draws from, and a blocked writer there deadlocks against the tests around it.
    static func writeInBackground(_ bytes: Data, to descriptor: Int32) {
        let thread = Thread { rawWrite(bytes, to: descriptor) }
        thread.stackSize = 128 * 1024
        thread.start()
    }

    static func rawReadResponse(from descriptor: Int32) throws -> Response {
        try Wire.decode(Response.self, from: Framing.readFrame(from: descriptor))
    }

    static func ok(_ state: LifecycleState = .idle, _ message: String? = nil) -> Response {
        Response(kind: .accepted, state: state, message: message)
    }

    // MARK: - the round trip

    @Test("a request reaches the daemon and its answer comes back")
    func roundTrip() throws {
        let seen = Recorder()
        let fixture = try Self.makeServer { incoming in
            seen.record(incoming)
            return Response(kind: .accepted, state: .recording, attempt: 7,
                            target: Target(sessionID: "session:7", pane: .left),
                            message: "listening")
        }
        defer { fixture.tearDown() }

        let request = Request(cmd: .toggle, sessionID: "session:7",
                              agtermSocket: "/tmp/agterm.sock", mode: .raw)
        let response = try ControlClient.send(request, to: fixture.path)

        #expect(seen.all == [.request(request)])
        #expect(response.kind == .accepted)
        #expect(response.state == .recording)
        #expect(response.attempt == 7)
        #expect(response.target == Target(sessionID: "session:7", pane: .left))
        #expect(response.message == "listening")
    }

    @Test("every verb survives a real socket", arguments: Command.allCases)
    func everyCommandRoundTrips(command: Command) throws {
        let seen = Recorder()
        let fixture = try Self.makeServer { incoming in
            seen.record(incoming)
            return Self.ok()
        }
        defer { fixture.tearDown() }

        _ = try ControlClient.send(Request(cmd: command, sessionID: "s"), to: fixture.path)
        #expect(seen.all == [.request(Request(cmd: command, sessionID: "s"))])
    }

    @Test("text on the response comes back byte for byte")
    func textSurvives() throws {
        // `last` reads the record back, and reading back is not injection — so the text may hold a
        // newline and must not be quietly repaired on the way out (§9, §8.1's parenthesis).
        let fixture = try Self.makeServer { _ in
            Response(kind: .accepted, state: .idle, text: "line one\nline two  ")
        }
        defer { fixture.tearDown() }

        let response = try ControlClient.send(Request(cmd: .last), to: fixture.path)
        #expect(response.text == "line one\nline two  ")
    }

    // MARK: - the frame limit

    @Test("the transport enforces exactly the limit the wire type declares")
    func limitsAgree() throws {
        // Two limits would mean one end producing frames the other refuses — the drift this module
        // exists to prevent.
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }

        // Written from another thread because a frame this size is far larger than a socketpair's
        // buffer: a same-thread write would block until somebody read it, which is this thread.
        let body = Data(repeating: 0x78, count: Wire.maxFrameBytes - 1) + Data([0x0A])
        let writeEnd = pair[1]
        Self.writeInBackground(body, to: writeEnd)

        #expect(try Framing.readFrame(from: pair[0]).count == Wire.maxFrameBytes - 1)
    }

    @Test("an oversized frame is refused at the limit, not after reading all of it")
    func oversizedFrameIsRefusedEarly() throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        var on: Int32 = 1
        setsockopt(pair[1], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        let excess = 16 * 1024
        let payload = Data(repeating: 0x78, count: Wire.maxFrameBytes + excess)
        // The writer blocks once the socket buffer fills, which is the point: whatever the reader
        // refused to take is still queued behind it.
        let writeEnd = pair[1]
        Self.writeInBackground(payload, to: writeEnd)

        do {
            _ = try Framing.readFrame(from: pair[0])
            Issue.record("an oversized frame was accepted")
        } catch let error as TransportError {
            guard case let .frameTooLarge(bytes, limit) = error else {
                Issue.record("expected frameTooLarge, got \(error)")
                return
            }
            #expect(limit == Wire.maxFrameBytes)
            #expect(bytes > Wire.maxFrameBytes)
            #expect(bytes < Wire.maxFrameBytes + excess,
                    "the whole frame was buffered before it was refused")
        }

        // Proof it stopped early rather than draining the peer: the rest is still there to read.
        var leftovers = [UInt8](repeating: 0, count: 1024)
        let remaining = leftovers.withUnsafeMutableBytes { raw in
            Darwin.read(pair[0], raw.baseAddress, raw.count)
        }
        #expect(remaining > 0, "the reader consumed the entire oversized frame")
    }

    @Test("an oversized request is answered with a rejection instead of killing the daemon")
    func oversizedRequestIsRejected() throws {
        let seen = Recorder()
        let fixture = try Self.makeServer { incoming in
            seen.record(incoming)
            if case .undecodable(let reason) = incoming {
                return Response(kind: .rejected, state: .idle, message: reason)
            }
            return Self.ok()
        }
        defer { fixture.tearDown() }

        let descriptor = try Self.rawConnect(to: fixture.path)
        let payload = Data(repeating: 0x78, count: Wire.maxFrameBytes + 8 * 1024) + Data([0x0A])
        Self.writeInBackground(payload, to: descriptor)

        let response = try Self.rawReadResponse(from: descriptor)
        #expect(response.kind == .rejected)
        #expect(response.message?.contains("exceeds") == true)
        // Deliberately not closing `descriptor`: a writer may still be blocked on it, and closing a
        // descriptor out from under a blocked write is a descriptor-reuse race the test does not
        // need to take. The process is about to exit.
    }

    // MARK: - malformed input

    @Test("a truncated frame is rejected rather than parsed")
    func truncatedFrameIsRejected() throws {
        let fixture = try Self.makeServer { incoming in
            if case .undecodable(let reason) = incoming {
                return Response(kind: .rejected, state: .idle, message: reason)
            }
            return Self.ok(.idle, "parsed")
        }
        defer { fixture.tearDown() }

        let descriptor = try Self.rawConnect(to: fixture.path)
        defer { close(descriptor) }
        Self.rawWrite(Data(#"{"cmd":"sta"#.utf8), to: descriptor)
        // Half-closing is what makes this a *truncated* frame rather than a slow one.
        shutdown(descriptor, SHUT_WR)

        let response = try Self.rawReadResponse(from: descriptor)
        #expect(response.kind == .rejected)
        #expect(response.message?.contains("11 bytes") == true)
    }

    @Test("a truncated read reports how much arrived, so it cannot be mistaken for silence")
    func truncationIsItsOwnError() throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]) }

        Self.rawWrite(Data("half a frame".utf8), to: pair[1])
        close(pair[1])

        #expect(throws: TransportError.truncated(bytes: 12)) {
            try Framing.readFrame(from: pair[0])
        }
    }

    @Test("a peer that says nothing at all is distinguished from one that says too little")
    func closedByPeerIsItsOwnError() throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]) }
        close(pair[1])

        #expect(throws: TransportError.closedByPeer) { try Framing.readFrame(from: pair[0]) }
    }

    @Test("garbage is rejected as a command this build does not know")
    func garbageIsRejected() throws {
        let seen = Recorder()
        let fixture = try Self.makeServer { incoming in
            seen.record(incoming)
            if case .undecodable(let reason) = incoming {
                return Response(kind: .rejected, state: .idle, message: reason)
            }
            return Self.ok()
        }
        defer { fixture.tearDown() }

        let descriptor = try Self.rawConnect(to: fixture.path)
        defer { close(descriptor) }
        Self.rawWrite(Data("not json at all\n".utf8), to: descriptor)

        let response = try Self.rawReadResponse(from: descriptor)
        #expect(response.kind == .rejected)
        #expect(response.message?.isEmpty == false)
        // The transport hands the frame over rather than answering it: only the daemon knows which
        // lifecycle state to report, and inventing `idle` here would be indistinguishable from the
        // truth to the client.
        #expect(seen.all.count == 1)
        if case .request = seen.all[0] { Issue.record("garbage decoded as a request") }
    }

    @Test("a frame naming an unknown verb is rejected, not guessed at")
    func unknownVerbIsRejected() throws {
        let fixture = try Self.makeServer { incoming in
            if case .undecodable(let reason) = incoming {
                return Response(kind: .rejected, state: .idle, message: reason)
            }
            return Self.ok(.idle, "parsed")
        }
        defer { fixture.tearDown() }

        let descriptor = try Self.rawConnect(to: fixture.path)
        defer { close(descriptor) }
        Self.rawWrite(Data("{\"cmd\":\"selfDestruct\"}\n".utf8), to: descriptor)

        #expect(try Self.rawReadResponse(from: descriptor).kind == .rejected)
    }

    // MARK: - a peer that goes away

    @Test("a client that disconnects mid-request does not wedge the server")
    func disconnectMidRequestDoesNotWedge() throws {
        let fixture = try Self.makeServer { _ in Self.ok(.idle, "still here") }
        defer { fixture.tearDown() }

        let abandoned = try Self.rawConnect(to: fixture.path)
        Self.rawWrite(Data(#"{"cmd":"sta"#.utf8), to: abandoned)
        close(abandoned)

        let response = try ControlClient.send(Request(cmd: .status), to: fixture.path)
        #expect(response.message == "still here")
    }

    @Test("a client that connects and says nothing does not hold up the next keypress")
    func silentClientDoesNotBlockTheNextOne() throws {
        // Served off the accept thread on purpose. Serially, the keypress behind a silent client
        // would wait out the whole server read timeout.
        let fixture = try Self.makeServer(readTimeout: 5) { _ in Self.ok(.idle, "prompt") }
        defer { fixture.tearDown() }

        let silent = try Self.rawConnect(to: fixture.path)
        defer { close(silent) }

        let started = Date()
        let response = try ControlClient.send(Request(cmd: .status), to: fixture.path)
        let elapsed = Date().timeIntervalSince(started)

        #expect(response.message == "prompt")
        #expect(elapsed < 1.0, "the round trip took \(elapsed) s behind a silent client")
    }

    @Test("a daemon that accepts and never answers becomes a fast local failure")
    func unresponsiveDaemonTimesOut() throws {
        let gate = DispatchSemaphore(value: 0)
        let fixture = try Self.makeServer(readTimeout: 5) { _ in
            _ = gate.wait(timeout: .now() + 5)
            return Self.ok()
        }
        defer { gate.signal(); fixture.tearDown() }

        let started = Date()
        do {
            _ = try ControlClient.send(Request(cmd: .status), to: fixture.path, readTimeout: 0.3)
            Issue.record("an unresponsive daemon was reported as a success")
        } catch let error as ControlClient.ClientError {
            #expect(error == .timedOut(seconds: 0.3))
        }
        #expect(Date().timeIntervalSince(started) < 2.0)
    }

    // MARK: - no daemon behind the socket

    @Test("no socket file at all is reported as a daemon that is not running")
    func noSocketAtAll() throws {
        let directory = Self.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("c.sock").path

        #expect(throws: ControlClient.ClientError.daemonNotRunning(path: path)) {
            try ControlClient.send(Request(cmd: .status), to: path)
        }
    }

    @Test("a socket file with nobody behind it is reported as a crashed daemon")
    func staleSocketFile() throws {
        // The two are different sentences on the user's desktop: "you never started it" would send
        // them to launch a daemon that is already installed and dying on startup.
        let directory = Self.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("c.sock").path
        try Self.leaveStaleSocket(at: path)

        #expect(throws: ControlClient.ClientError.daemonCrashed(path: path)) {
            try ControlClient.send(Request(cmd: .status), to: path)
        }
        #expect(ControlClient.ClientError.daemonCrashed(path: path)
            != ControlClient.ClientError.daemonNotRunning(path: path))
    }

    /// Binds a socket and drops the descriptor without unlinking — exactly what a crashed daemon
    /// leaves behind.
    static func leaveStaleSocket(at path: String) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, size) }
        }
        try #require(bound == 0, "bind() failed with errno \(errno)")
        close(descriptor)
        try #require(FileManager.default.fileExists(atPath: path))
    }

    // MARK: - the server's own lifecycle

    @Test("a second daemon is refused while the first one's socket is live")
    func secondInstanceRefused() throws {
        let fixture = try Self.makeServer { _ in Self.ok() }
        defer { fixture.tearDown() }

        let second = ControlServer(path: fixture.path) { _ in Self.ok() }
        #expect(throws: ControlServer.ServerError.alreadyRunning(path: fixture.path)) {
            try second.start()
        }
    }

    @Test("a socket left by a crashed daemon is replaced rather than refused")
    func staleSocketIsReplaced() throws {
        let directory = Self.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("c.sock").path
        try Self.leaveStaleSocket(at: path)

        let server = ControlServer(path: path) { _ in Self.ok(.idle, "recovered") }
        try server.start()
        defer { server.stop() }

        #expect(try ControlClient.send(Request(cmd: .status), to: path).message == "recovered")
    }

    @Test("stopping removes the socket file, so nothing is left claiming a live daemon")
    func stopUnlinks() throws {
        let fixture = try Self.makeServer { _ in Self.ok() }
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        #expect(FileManager.default.fileExists(atPath: fixture.path))

        fixture.server.stop()
        #expect(!FileManager.default.fileExists(atPath: fixture.path))
        fixture.server.stop()
    }

    @Test("a socket path too long for sun_path is refused rather than silently truncated")
    func pathTooLongIsRefused() throws {
        // Truncation is how a daemon binds one path and a client connects to another.
        let directory = Self.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(String(repeating: "n", count: 120)).path

        let server = ControlServer(path: path) { _ in Self.ok() }
        #expect(throws: ControlServer.ServerError.pathTooLong(path: path, limit: 103)) {
            try server.start()
        }
        #expect(throws: ControlClient.ClientError
            .transport(.pathTooLong(path: path, limit: 103))) {
            try ControlClient.send(Request(cmd: .status), to: path)
        }
    }

    // MARK: - what a verb is allowed to cost

    @Test("the verbs that carry the whole pipeline wait longer than the ones that do not")
    func pipelineVerbsGetTheLongerRead() {
        // The daemon does NOT answer before doing the work: `stop` returns only after recognition
        // and the keystrokes. Three seconds was therefore a ceiling on the pipeline, and the first
        // chord after a rebuild -- which waits for the one 17 s model load rather than losing the
        // audio -- expired inside it. The user was told dicta had not answered about a dictation
        // that had in fact just landed in their input line.
        #expect(ControlTimeouts.read(for: .stop) == ControlTimeouts.pipelineRead)
        // `toggle` too, because the start-or-stop decision belongs to the daemon (D7) -- the client
        // cannot know which direction its own chord will resolve.
        #expect(ControlTimeouts.read(for: .toggle) == ControlTimeouts.pipelineRead)
        for quick in [Command.status, .last, .start, .abort] {
            #expect(ControlTimeouts.read(for: quick) == ControlTimeouts.clientRead,
                    "\(quick.rawValue) performs no work and must fail fast")
        }
        #expect(ControlTimeouts.pipelineRead > ControlTimeouts.clientRead)
    }

    @Test("an answer too large for a frame is refused in words, not by dropping the connection")
    func anOversizedAnswerIsStillAnAnswer() throws {
        // `guard let frame = try? Wire.encode(response) else { return }` closed the connection, and
        // the client reads a close as `closedByPeer` -> "the daemon died". So the one response the
        // size limit exists to catch was reported as a crash of a perfectly healthy daemon.
        let huge = String(repeating: "a", count: Wire.maxFrameBytes)
        let fixture = try Self.makeServer { _ in
            Response(kind: .accepted, state: .idle, text: huge)
        }
        defer { fixture.tearDown() }

        let response = try ControlClient.send(Request(cmd: .last), to: fixture.path)

        #expect(response.kind == .rejected)
        #expect(response.text == nil)
        #expect(response.message?.contains("too large") == true,
                "the answer must say what happened: \(response.message ?? "nothing")")
    }

    @Test("an answer at the record's own ceiling still travels")
    func textAtTheRecordCeilingRoundTrips() throws {
        // The other side of the same boundary, and why `RecognisedText.maxBytes` is the frame
        // limit LESS an envelope allowance: everything the record will accept must come back out.
        let atCeiling = String(repeating: "a", count: RecognisedText.maxBytes)
        let fixture = try Self.makeServer { _ in
            Response(kind: .accepted, state: .idle, attempt: 7,
                     target: Target(sessionID: "S1", pane: .left), text: atCeiling)
        }
        defer { fixture.tearDown() }

        let response = try ControlClient.send(Request(cmd: .last), to: fixture.path)

        #expect(response.kind == .accepted)
        #expect(response.text == atCeiling)
    }
}
