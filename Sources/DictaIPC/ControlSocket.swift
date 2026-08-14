import DictaCore
import Foundation

// Both halves of the control transport, deliberately in ONE file.
//
// The framing rules are three lines long and they are the kind of thing that drifts: one end grows
// a length prefix, the other keeps scanning for a newline, and the symptom is a keypress that hangs
// for the read timeout. Keeping `Framing` between `ControlServer` and `ControlClient` means neither
// end can be changed without the other being in view.
//
// One JSON line in, one JSON line out, connection closed. No length prefix, no framing version
// negotiation: client and daemon ship from this repository together and are always in lockstep, and
// a frame stays typeable by hand --
//
//     echo '{"cmd":"status"}' \
//         | nc -U ~/Library/Application\ Support/dev.personal.dicta/control.sock
//
// The trust boundary is the filesystem: a 0600 socket in a 0700 directory owned by this uid. No
// token, because any process running as this user can already act as this user.

/// Timeouts, all of them short. The caller is a keypress: an unresponsive daemon must become a
/// visible local failure in well under a second of the user's attention, not a hang they interpret
/// as "it is still thinking" while they keep talking into a recording that no longer exists.
public enum ControlTimeouts {
    /// A local `connect(2)` either succeeds at once or fails; this only bounds the case where the
    /// daemon is alive but its accept backlog is full.
    public static let connect: TimeInterval = 0.5
    /// How long the client waits for the answer to a command that performs no work and is typed by
    /// hand — `status` and `last`. These return as fast as the daemon can take its lock, so
    /// anything past a few seconds is a daemon that is not answering rather than one thinking; and
    /// when the guess is wrong, the cost is a re-run of a diagnostic rather than an utterance.
    public static let clientRead: TimeInterval = 3.0
    /// How long the client waits for a command that carries the **whole remainder of an attempt**.
    ///
    /// The daemon does NOT answer before doing the work: `Daemon.apply` performs every effect
    /// inline, so a `stop` returns only after drain → recognition → dictionary → sanitiser →
    /// `agtermctl session type` have all run. Measured, that is about half a second (F1). The
    /// exception is the first chord after a rebuild, where `ParakeetTranscriber` deliberately waits
    /// for the one start-up model load rather than losing an utterance already in hand — 17 s of
    /// ANE compilation, measured.
    ///
    /// Three seconds therefore used to expire *while the text was being delivered*, and the user
    /// was told dicta had not answered about a dictation that in fact landed.
    ///
    /// This number is a CEILING OVER THE DAEMON'S OWN CEILINGS, not a guess. Anything smaller than
    /// what the daemon is willing to spend reproduces exactly the misreport it was raised to
    /// remove, just further out: the client gives up, says "dicta did not answer" and fires the
    /// desktop notification, and the daemon goes on to inject the text a minute later. The daemon's
    /// budget is `ParakeetTranscriber.patience` (waiting for the one start-up load) plus
    /// `ParakeetEngine.inferenceCeiling` plus the `agtermctl` calls the delivery makes, each
    /// bounded by `ProcessRunner.defaultDeadline` -- and `daemonCeilingsFitTheClientTimeout`
    /// asserts the sum still fits here, so the two cannot drift apart again.
    ///
    /// Long is the right direction to be wrong in. `connect` and the frame write catch a daemon
    /// that is dead or gone in well under a second; this timeout is only ever reached by a daemon
    /// that accepted the command and is grinding on it, and giving up on that one is what costs an
    /// utterance.
    ///
    /// 180 rather than 120 because the sum was recounted: `patience` (60) + `inferenceCeiling` (30)
    /// + `ProcessRunner.worstCaseCallsPerStop` × `defaultDeadline` (60) is 150, and 120 sat under
    /// its own daemon's budget.
    public static let pipelineRead: TimeInterval = 180.0
    /// How long the server waits for a connected client to say something. Bounds a client that
    /// connects and then wanders off.
    public static let serverRead: TimeInterval = 2.0

    /// The read timeout a verb deserves. Every verb a CHORD can send gets the pipeline's ceiling.
    ///
    /// `stop` and `toggle` are the two that carry the pipeline themselves — `toggle` because the
    /// start-or-stop decision belongs to the daemon (D7), so the client cannot know which direction
    /// it will resolve. `start` and `abort` perform no work of their own, but `ControlServer.serve`
    /// takes `handlerLock` for every command, so either can be QUEUED BEHIND a pipeline that is
    /// still running. Three seconds there reproduces the misreport `pipelineRead` exists to remove,
    /// on the one control the user reaches for when nothing seems to be happening: `dictactl abort`
    /// gives up, says "dicta did not answer within 3.0 s" and fires the desktop notification, about
    /// a daemon that is at that moment typing the text.
    ///
    /// `status` and `last` keep the short one deliberately — they are typed by hand, they cost no
    /// utterance, and a diagnostic that hangs for two minutes is worse than one that is re-run.
    public static func read(for command: Command) -> TimeInterval {
        switch command {
        case .stop, .toggle, .start, .abort: pipelineRead
        case .status, .last: clientRead
        }
    }
}

/// What can go wrong at the byte level, on either end.
public enum TransportError: Error, Equatable, CustomStringConvertible {
    case frameTooLarge(bytes: Int, limit: Int)
    case truncated(bytes: Int)
    case closedByPeer
    case timedOut
    case io(String, code: Int32)
    case pathTooLong(path: String, limit: Int)

    public var description: String {
        switch self {
        case let .frameTooLarge(bytes, limit):
            "frame of \(bytes) bytes exceeds the \(limit)-byte limit"
        case let .truncated(bytes):
            "the peer closed after \(bytes) bytes without ending the frame"
        case .closedByPeer:
            "the peer closed the connection without sending anything"
        case .timedOut:
            "the peer did not answer in time"
        case let .io(call, code):
            "\(call) failed (errno \(code))"
        case let .pathTooLong(path, limit):
            "the socket path is \(path.utf8.count) bytes, over the \(limit)-byte limit"
        }
    }
}

/// JSON-lines framing over a raw descriptor. `Wire` owns what a frame *is*; this owns getting one
/// off a socket without letting a confused peer decide how much memory we buffer.
public enum Framing {
    /// Read granularity. One frame per connection, so bytes that arrive after the newline belong to
    /// nobody and are discarded with the descriptor.
    static let chunkBytes = 4096

    /// Writes a whole frame, tolerating short writes. Never partial: a half-written frame is
    /// invalid JSON at the far end, which reports as a protocol error and hides the real cause.
    public static func write(_ frame: Data, to descriptor: Int32) throws {
        try frame.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset),
                                           raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK { throw TransportError.timedOut }
                throw TransportError.io("write()", code: code)
            }
        }
    }

    /// Reads one newline-terminated frame, returning it **without** the newline.
    ///
    /// The limit is enforced as the bytes arrive, not after: an oversized frame is refused at the
    /// moment it crosses the line, so a peer cannot make us buffer its whole idea of a message
    /// before we get to disagree with it.
    public static func readFrame(
        from descriptor: Int32,
        limit: Int = Wire.maxFrameBytes
    ) throws -> Data {
        var frame = Data()
        var chunk = [UInt8](repeating: 0, count: chunkBytes)
        while true {
            let count = chunk.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(descriptor, raw.baseAddress, raw.count)
            }
            if count == 0 {
                if frame.isEmpty { throw TransportError.closedByPeer }
                throw TransportError.truncated(bytes: frame.count)
            }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK { throw TransportError.timedOut }
                throw TransportError.io("read()", code: code)
            }
            if let newline = chunk[0 ..< count].firstIndex(of: 0x0A) {
                frame.append(contentsOf: chunk[0 ..< newline])
                // The limit counts the newline, so a body one byte short of it is legal.
                guard frame.count + 1 <= limit else {
                    throw TransportError.frameTooLarge(bytes: frame.count + 1, limit: limit)
                }
                return frame
            }
            frame.append(contentsOf: chunk[0 ..< count])
            if frame.count >= limit {
                // No terminator yet, so the frame is at least one byte longer than what has been
                // read. `bytes` is that minimum, which keeps it comparable with the branch above.
                throw TransportError.frameTooLarge(bytes: frame.count + 1, limit: limit)
            }
        }
    }
}

// MARK: - address helpers

/// Fills a `sockaddr_un`, refusing a path that does not fit rather than letting the kernel truncate
/// it — a truncated path is how a daemon binds one socket and a client connects to another.
private func unixAddress(for path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else {
        throw TransportError.pathTooLong(path: path, limit: capacity - 1)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: bytes)
    }
    return address
}

private func withSockaddr<R>(_ address: inout sockaddr_un,
                             _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, size) }
    }
}

/// Darwin sends SIGPIPE for a write to a socket the peer has closed, which would kill the daemon
/// because a client got bored. Every descriptor this file owns has it disabled.
private func silenceSIGPIPE(_ descriptor: Int32) {
    var on: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
}

private func setReadTimeout(_ descriptor: Int32, seconds: TimeInterval) {
    var timeout = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds)))
        * 1_000_000))
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
               socklen_t(MemoryLayout<timeval>.size))
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout,
               socklen_t(MemoryLayout<timeval>.size))
}

// MARK: - server

/// The daemon's front door.
public final class ControlServer: @unchecked Sendable {
    /// What arrived on a connection. A frame the transport could not turn into a `Request` is
    /// handed over as text rather than answered here, because the answer must carry the daemon's
    /// *current* lifecycle state (§6) and the transport does not know it. Inventing `idle` for a
    /// malformed frame would be a lie the client cannot tell from the truth.
    public enum Incoming: Sendable, Equatable {
        case request(Request)
        case undecodable(String)
    }

    public typealias Handler = @Sendable (Incoming) -> Response

    public enum ServerError: Error, Equatable, CustomStringConvertible {
        case alreadyRunning(path: String)
        case bindFailed(String, code: Int32)
        case pathTooLong(path: String, limit: Int)

        public var description: String {
            switch self {
            case let .alreadyRunning(path):
                "a live daemon already owns \(path)"
            case let .bindFailed(call, code):
                "could not open the control socket: \(call) failed (errno \(code))"
            case let .pathTooLong(path, limit):
                "the socket path is \(path.utf8.count) bytes, over the \(limit)-byte limit"
            }
        }
    }

    public let path: String
    private let handler: Handler
    private let readTimeout: TimeInterval
    /// Handler calls are serialised: the daemon owns one microphone and one lifecycle, so two
    /// commands arriving at once must still resolve one after the other (D7).
    private let handlerLock = NSLock()
    private let exited = DispatchSemaphore(value: 0)
    /// Guards everything below it. `start` and `stop` run on their caller's thread and `acceptLoop`
    /// on its own, so all four fields are genuinely shared -- `@unchecked Sendable` silences the
    /// compiler about that, it does not make it true. The ordering used to come from the wakeup
    /// pipe by luck rather than by construction.
    private let stateLock = NSLock()
    private var listenDescriptor: Int32 = -1
    private var wakeupRead: Int32 = -1
    private var wakeupWrite: Int32 = -1
    private var running = false

    /// The socket file is removed by whichever of `stop` and `acceptLoop` gets there second, and
    /// only once the loop has actually exited: unlinking the path while the loop is still accepting
    /// on it leaves a live listener nobody can reach.
    private var listening: (listen: Int32, wakeup: Int32)? {
        stateLock.withLock { running ? (listenDescriptor, wakeupRead) : nil }
    }

    public init(path: String,
                readTimeout: TimeInterval = ControlTimeouts.serverRead,
                handler: @escaping Handler) {
        self.path = path
        self.readTimeout = readTimeout
        self.handler = handler
    }

    /// Binds, listens, and starts accepting. Throws `alreadyRunning` when something is already
    /// listening on the path — §7's "second daemon instance attempted" row, and the reason the
    /// stale-socket check probes by connecting rather than by looking at the file.
    public func start() throws {
        let directory = (path as NSString).deletingLastPathComponent
        try? Paths.createPrivateDirectory(URL(fileURLWithPath: directory, isDirectory: true))
        try clearStaleSocket()

        var address: sockaddr_un
        do {
            address = try unixAddress(for: path)
        } catch let TransportError.pathTooLong(path, limit) {
            throw ServerError.pathTooLong(path: path, limit: limit)
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ServerError.bindFailed("socket()", code: errno) }
        silenceSIGPIPE(descriptor)

        guard withSockaddr(&address, { bind(descriptor, $0, $1) }) == 0 else {
            let code = errno
            close(descriptor)
            throw ServerError.bindFailed("bind()", code: code)
        }
        // 0600 inside a 0700 directory IS the whole access-control story — see `Paths.socket`.
        chmod(path, 0o600)
        guard listen(descriptor, 16) == 0 else {
            let code = errno
            close(descriptor)
            unlink(path)
            throw ServerError.bindFailed("listen()", code: code)
        }

        var pipeEnds: [Int32] = [-1, -1]
        guard pipe(&pipeEnds) == 0 else {
            let code = errno
            close(descriptor)
            unlink(path)
            throw ServerError.bindFailed("pipe()", code: code)
        }
        stateLock.withLock {
            wakeupRead = pipeEnds[0]
            wakeupWrite = pipeEnds[1]
            listenDescriptor = descriptor
            running = true
        }

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "dev.personal.dicta.control"
        thread.start()
    }

    /// Stops accepting and removes the socket file. Idempotent.
    ///
    /// The accept loop is woken through a pipe rather than by closing the descriptor underneath it:
    /// closing a descriptor another thread is blocked on is a race with descriptor reuse, and the
    /// symptom would be a test that passes ninety-nine times.
    public func stop() {
        // The wakeup byte is written while the lock is held, in the same critical section that
        // clears `running`. The accept loop closes these descriptors under the same lock on its way
        // out, so a write that escaped the lock could land on a descriptor the kernel had already
        // handed to somebody else -- the exact hazard this pipe exists to avoid.
        let wasRunning = stateLock.withLock { () -> Bool in
            guard running else { return false }
            running = false
            if wakeupWrite >= 0 {
                var byte: UInt8 = 1
                _ = Darwin.write(wakeupWrite, &byte, 1)
            }
            return true
        }
        guard wasRunning else { return }
        // Only unlink once the loop has confirmed it is gone. On the timeout the loop is still
        // accepting on this path, and removing the file underneath it would leave a listener no
        // client can address while `dictactl` reported "dicta is not running".
        guard exited.wait(timeout: .now() + 2) == .success else { return }
        unlink(path)
    }

    /// A socket file left behind by a crashed daemon must be removed; one belonging to a LIVE
    /// daemon must never be, or two instances would fight over the microphone. The only honest test
    /// is to try connecting — refused means nobody is home.
    private func clearStaleSocket() throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        var address: sockaddr_un
        do {
            address = try unixAddress(for: path)
        } catch let TransportError.pathTooLong(path, limit) {
            throw ServerError.pathTooLong(path: path, limit: limit)
        }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw ServerError.bindFailed("socket()", code: errno) }
        defer { close(probe) }
        if withSockaddr(&address, { connect(probe, $0, $1) }) == 0 {
            throw ServerError.alreadyRunning(path: path)
        }
        unlink(path)
    }

    /// Errors that say "not now" rather than "not ever". Fatal for the front door is the wrong
    /// reading of every one of them: the loop exits, the process stays alive, the socket file stays
    /// on disk with nobody behind it, and every later chord gets ECONNREFUSED and reports "the
    /// daemon died" -- while `KeepAlive` sees a healthy process and never restarts it. That is the
    /// unrecoverable-without-`launchctl kickstart` failure `ProcessRunner.defaultDeadline` exists
    /// to prevent, arriving through the other door. `EMFILE`/`ENFILE` are the realistic ones
    /// here: a thread and a descriptor per connection, against a per-process descriptor limit.
    private static func acceptIsRetryable(_ code: Int32) -> Bool {
        [EINTR, ECONNABORTED, EAGAIN, EWOULDBLOCK, EMFILE, ENFILE, ENOBUFS, ENOMEM]
            .contains(code)
    }

    private func acceptLoop() {
        /// Whether the loop is leaving because it was ASKED to. Anything else leaves a socket file
        /// no client can be answered on, and the path is unlinked on the way out so that `dictactl`
        /// reports "dicta is not running" -- true, and actionable -- instead of "the daemon died".
        var askedToStop = false
        while true {
            // `running` is cleared by `stop` and by this loop's own exit, so losing it here is a
            // request too -- and unlinking on it would race a `start` that has already rebound the
            // path underneath us.
            guard let (listenDescriptor, wakeupRead) = listening else {
                askedToStop = true
                break
            }
            var descriptors = [
                pollfd(fd: listenDescriptor, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeupRead, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&descriptors, 2, -1)
            if ready < 0 {
                if Self.acceptIsRetryable(errno) {
                    // Descriptor exhaustion returns immediately and would spin this thread at 100%
                    // against a condition only another thread can clear.
                    if errno != EINTR { usleep(50_000) }
                    continue
                }
                break
            }
            if descriptors[1].revents != 0 {
                askedToStop = true
                break
            }
            guard descriptors[0].revents != 0 else { continue }

            let client = accept(listenDescriptor, nil, nil)
            guard client >= 0 else {
                if Self.acceptIsRetryable(errno) {
                    if errno != EINTR, errno != ECONNABORTED { usleep(50_000) }
                    continue
                }
                break
            }
            silenceSIGPIPE(client)
            setReadTimeout(client, seconds: readTimeout)
            // Served off the accept thread, so a client that connects and says nothing cannot hold
            // up the keypress behind it for the whole read timeout.
            //
            // A real thread rather than a dispatch queue, and this is not a style choice: on Darwin
            // Swift concurrency's executor runs on the same NON-OVERCOMMIT global worker pool that
            // `DispatchQueue.global()` uses, so anything that blocks a cooperative thread — an
            // `await` on a lock, a synchronous client call, the test suite itself — can leave no
            // worker free to run the front door. Measured: with connections on the global pool, a
            // parallel test run starved round trips into their 3-second timeout. The daemon serves
            // a keypress or two a second, so a thread per connection costs nothing worth counting.
            let thread = Thread { [weak self] in
                self?.serve(client)
                close(client)
            }
            thread.name = "dev.personal.dicta.control.connection"
            thread.stackSize = 128 * 1024
            thread.start()
        }
        stateLock.withLock {
            running = false
            if listenDescriptor >= 0 { close(listenDescriptor) }
            if wakeupRead >= 0 { close(wakeupRead) }
            if wakeupWrite >= 0 { close(wakeupWrite) }
            listenDescriptor = -1
            wakeupRead = -1
            wakeupWrite = -1
        }
        // `stop` unlinks on its own path, and only after `exited` -- so this is the case it cannot
        // reach: the loop died of its own accord, `running` is already false, and `stop` would
        // return at its `guard` without touching the file.
        if !askedToStop { unlink(path) }
        exited.signal()
    }

    private func serve(_ client: Int32) {
        let incoming: Incoming
        do {
            let frame = try Framing.readFrame(from: client)
            do {
                incoming = .request(try Wire.decode(Request.self, from: frame))
            } catch {
                incoming = .undecodable(Self.explain(error))
            }
        } catch TransportError.closedByPeer {
            // The client went away before saying anything. There is nobody to answer and nothing to
            // report: this is what a cancelled keypress looks like from here.
            return
        } catch {
            incoming = .undecodable(Self.explain(error))
        }

        let response = handlerLock.withLock { handler(incoming) }
        // A response that will not fit a frame is answered with one that will, never by closing the
        // connection. The client reads a close as `closedByPeer` and reports "the daemon died" — so
        // dropping an oversized `last` here would diagnose a perfectly healthy daemon as a crashed
        // one, which is the opposite of what the size limit exists to achieve.
        let frame: Data
        do {
            frame = try Wire.encode(response)
        } catch {
            let apology = Response(
                kind: .rejected,
                state: response.state,
                attempt: response.attempt,
                message: "dicta's answer is too large to send back: \(Self.explain(error))"
            )
            guard let fallback = try? Wire.encode(apology) else { return }
            frame = fallback
        }
        try? Framing.write(frame, to: client)
    }

    /// The sentence the user ends up reading, so it says what happened rather than naming a type.
    private static func explain(_ error: any Error) -> String {
        if let transport = error as? TransportError { return transport.description }
        if let wire = error as? WireError { return wire.description }
        if error is DecodingError { return "the request is not a command this build knows" }
        return "the request could not be read"
    }
}

// MARK: - client

/// The half `dictactl` uses. Every failure here is one the user must be *told* about (§7): their
/// hands are on the keyboard, not on a log.
public enum ControlClient {
    public enum ClientError: Error, Equatable, CustomStringConvertible {
        /// No socket file at all — the daemon was never started, or was stopped deliberately.
        case daemonNotRunning(path: String)
        /// A socket file with nobody behind it. Distinct from the above because it means something
        /// different: the daemon crashed, and saying "not running" would suggest the user forgot to
        /// start it.
        case daemonCrashed(path: String)
        case timedOut(seconds: TimeInterval)
        case transport(TransportError)
        case malformedResponse(String)

        public var description: String {
            switch self {
            case let .daemonNotRunning(path):
                "dicta is not running — there is no control socket at \(path)"
            case let .daemonCrashed(path):
                "dicta is not answering — \(path) has no listener, so the daemon died"
            case let .timedOut(seconds):
                "dicta did not answer within \(String(format: "%.1f", seconds)) s"
            case let .transport(error):
                "dicta could not be reached: \(error.description)"
            case let .malformedResponse(detail):
                "dicta answered something unreadable: \(detail)"
            }
        }
    }

    /// Sends one request and reads one response. The connection is opened and closed per command:
    /// a keypress is not a session, and a persistent connection would only add a reconnect path.
    /// `readTimeout` defaults to `nil`, meaning "the one this verb deserves" — a default argument
    /// cannot read another argument, and hard-coding the short timeout here is what let a `stop`
    /// time out on a dictation that was being delivered.
    public static func send(
        _ request: Request,
        to path: String = Paths.current.socket.path,
        connectTimeout: TimeInterval = ControlTimeouts.connect,
        readTimeout: TimeInterval? = nil
    ) throws -> Response {
        let readTimeout = readTimeout ?? ControlTimeouts.read(for: request.cmd)
        var address: sockaddr_un
        do {
            address = try unixAddress(for: path)
        } catch let error as TransportError {
            throw ClientError.transport(error)
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ClientError.transport(.io("socket()", code: errno))
        }
        defer { close(descriptor) }
        silenceSIGPIPE(descriptor)

        let payload: Data
        do {
            payload = try Wire.encode(request)
        } catch let WireError.frameTooLarge(bytes, limit) {
            throw ClientError.transport(.frameTooLarge(bytes: bytes, limit: limit))
        } catch {
            throw ClientError.malformedResponse("the request could not be encoded: \(error)")
        }

        try connect(descriptor, to: &address, path: path, timeout: connectTimeout)
        setReadTimeout(descriptor, seconds: readTimeout)

        do {
            try Framing.write(payload, to: descriptor)
            let frame = try Framing.readFrame(from: descriptor)
            do {
                return try Wire.decode(Response.self, from: frame)
            } catch {
                throw ClientError.malformedResponse("\(error)")
            }
        } catch TransportError.timedOut {
            throw ClientError.timedOut(seconds: readTimeout)
        } catch TransportError.closedByPeer {
            // The daemon accepted the connection and then went away without answering — a crash
            // mid-command. `daemonCrashed` is the honest word for it.
            throw ClientError.daemonCrashed(path: path)
        } catch let error as TransportError {
            throw ClientError.transport(error)
        }
    }

    /// A `connect(2)` bounded by a timeout, so a daemon that is alive but not accepting cannot hold
    /// a keypress indefinitely.
    private static func connect(
        _ descriptor: Int32,
        to address: inout sockaddr_un,
        path: String,
        timeout: TimeInterval
    ) throws {
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(descriptor, F_SETFL, flags) }

        if withSockaddr(&address, { Darwin.connect(descriptor, $0, $1) }) == 0 { return }

        let code = errno
        switch code {
        case EINPROGRESS, EALREADY, EAGAIN:
            var waiting = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&waiting, 1, Int32(timeout * 1000))
            guard ready > 0 else { throw ClientError.timedOut(seconds: timeout) }
            var pending: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &pending, &size)
            guard pending == 0 else { throw classify(pending, path: path) }
        default:
            throw classify(code, path: path)
        }
    }

    /// `ECONNREFUSED` on a Unix socket means the path exists and nothing is listening; `ENOENT`
    /// means there is no path at all. That single distinction is the whole "crashed" versus "never
    /// started" story, and it costs nothing to keep.
    private static func classify(_ code: Int32, path: String) -> ClientError {
        switch code {
        case ENOENT, ENOTDIR: .daemonNotRunning(path: path)
        case ECONNREFUSED, ENOTSOCK: .daemonCrashed(path: path)
        default: .transport(.io("connect()", code: code))
        }
    }
}
