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
    /// bounded by `ProcessRunner.worstCaseCallSeconds` -- and `daemonCeilingsFitTheClientTimeout`
    /// asserts the sum still fits here, so the two cannot drift apart again.
    ///
    /// Long is the right direction to be wrong in. `connect` and the frame write catch a daemon
    /// that is dead or gone in well under a second; this timeout is only ever reached by a daemon
    /// that accepted the command and is grinding on it, and giving up on that one is what costs an
    /// utterance.
    ///
    /// Recounted twice, and both recounts moved it up. 120 sat under its own daemon's budget; 180
    /// was `patience` (60) + `inferenceCeiling` (30) + twelve subprocesses at the five-second
    /// deadline (60), which undercounted twice over -- a call can spend the deadline **plus** both
    /// grace periods (`worstCaseCallSeconds`, 8 s), and a session lookup that sweeps windows makes
    /// sixteen of them rather than twelve. 60 + 30 + 16 × 8 is 218. Do not read that arithmetic off
    /// this comment either; read the constants, which is what the assertion does.
    public static let pipelineRead: TimeInterval = 240.0
    /// How long the server waits for a connected client to say something. Bounds a client that
    /// connects and then wanders off.
    public static let serverRead: TimeInterval = 2.0
    /// How long the daemon waits for the user to actually speak, when `dictate` names no timeout
    /// of its own (D29).
    ///
    /// A minute, because this is a person deciding what to say, not a machine working. It is
    /// bounded at all for one reason: a script that called `dictate` and was then ignored must not
    /// wait for ever, or the user's `⌃⌥C` appears to have hung and the only way out is to find the
    /// process.
    public static let dictateWait: TimeInterval = 60.0
    /// How long a `watch` client waits between frames before deciding the daemon is gone (D27).
    ///
    /// **This value had to be invented rather than reused, and that is the whole point of the
    /// entry.** Every other number here means "how long may ONE answer take", and a watcher is not
    /// waiting for an answer: it is waiting for the user to press a key, which they may not do
    /// until tomorrow. A stream silent for an hour because nobody dictated is perfectly healthy,
    /// and no timeout above says so — `clientRead` would call such a daemon dead within three
    /// seconds.
    ///
    /// So it is generous, and it is not a heartbeat interval: the daemon sends nothing when nothing
    /// happens. What actually detects a dead peer is the write that fails, in whichever direction
    /// moves first. This bounds the case where the daemon's process is gone without its socket
    /// having been closed — a `SIGKILL` with a descriptor inherited by a child, say — which no
    /// write from the client's side would otherwise reveal.
    public static let watchIdle: TimeInterval = 3600.0

    /// How many `watch` connections the daemon serves at once (D27).
    ///
    /// The number is small because the expected population is one — the menu-bar UI — and a second
    /// is a developer looking. It exists at all because a watcher **breaks the premise every other
    /// connection here rests on**. `ControlServer` serves each connection on its own real `Thread`,
    /// and the comment justifying that says outright: "the daemon serves a keypress or two a
    /// second, so a thread per connection costs nothing worth counting". Momentary connections make
    /// that true. A watcher lives for hours, so "how many can exist" stops being answered by "they
    /// are all over in milliseconds" and has to be answered here.
    ///
    /// Over the cap the daemon REFUSES with an ordinary short `Response`, never by dropping the
    /// connection — see `WatchEvent`.
    public static let maxWatchers = 4

    /// The read timeout a verb deserves. Every verb a CHORD can send gets the pipeline's ceiling.
    ///
    /// `stop` and `toggle` are the two that carry the pipeline themselves — `toggle` because the
    /// start-or-stop decision belongs to the daemon (D7), so the client cannot know which direction
    /// it will resolve. `start` performs no work of its own and is bounded by them anyway:
    /// `ControlServer.serve` serialises it, so it can be QUEUED BEHIND a pipeline that is still
    /// running. Three seconds there reproduces the misreport `pipelineRead` exists to remove.
    ///
    /// `abort` is the one verb `serve` does NOT serialise (`Command.isServedConcurrently`), so it
    /// is not queued behind anything — and it keeps the long ceiling regardless, because the work
    /// it does itself is not free: a cancel emits `.announce(.blocked)` and `.notify(reason)`, two
    /// `agtermctl` subprocesses, each of which may spend `ProcessRunner.worstCaseCallSeconds`. It
    /// is also the one control the user reaches for when nothing seems to be happening, i.e.
    /// exactly when the machine is slow — and `dictactl abort` giving up, saying "dicta did not
    /// answer within 3.0 s" and firing a desktop notification about a daemon that is at that moment
    /// cancelling their attempt is the misreport in its most confusing form.
    ///
    /// `status` and `last` keep the short one deliberately — they are typed by hand, they cost no
    /// utterance, and a diagnostic that hangs for two minutes is worse than one that is re-run.
    public static func read(for command: Command) -> TimeInterval {
        switch command {
        case .stop, .toggle, .start, .abort: pipelineRead
        // Typed by hand, and still the long read: both are serialised, so either can queue behind a
        // `stop` that is recognising, and a `configure` also writes and syncs a file.
        case .configure, .accessibility: pipelineRead
        // The handshake, not the stream. `watch`'s first frame is an ordinary accept-or-refuse
        // `Response` and arrives as fast as the daemon can take its lock; `watchIdle` governs
        // everything after it, and is applied by the watching client rather than looked up here —
        // a single number per verb cannot express "short, then long".
        case .watch: clientRead
        // The daemon's wait, plus the ceiling on everything it does AFTER the user stops speaking.
        // A caller that names its own `--timeout` overrides this from `dictactl`, because a read
        // timeout shorter than the wait it asked for would report a daemon that is doing exactly
        // what it was told to.
        case .dictate: dictateWait + pipelineRead
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
                // Zero with bytes still to write sets no `errno`, so the value below would be some
                // earlier call's -- and an `EINTR` left lying around there would spin this loop for
                // ever, on a thread that may be holding the daemon's handler lock. `FileHistory`
                // treats the same return as a refusal to make progress; so does this.
                if written == 0 { throw TransportError.io("write()", code: ENOSPC) }
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK { throw TransportError.timedOut }
                throw TransportError.io("write()", code: code)
            }
        }
    }

    /// Reads one frame from a connection that carries MANY, keeping whatever arrived after it.
    ///
    /// `readFrame` below discards the tail of the chunk it read past the newline, and says so: with
    /// one frame per connection those bytes belong to nobody. On a `watch` stream they belong to
    /// the next event — two frames written back-to-back arrive in a single `read` — and discarding
    /// them would silently drop the newer state, which is the one thing the stream exists to carry.
    /// Hence a second reader rather than a flag: the two have genuinely different contracts, and
    /// the one-frame reader's discarding is load-bearing where it is used.
    public static func readStreamedFrame(
        from descriptor: Int32,
        buffer: inout Data,
        limit: Int = Wire.maxFrameBytes
    ) throws -> Data {
        var chunk = [UInt8](repeating: 0, count: chunkBytes)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let frame = Data(buffer[buffer.startIndex ..< newline])
                // The limit counts the newline, so a body one byte short of it is legal.
                guard frame.count + 1 <= limit else {
                    throw TransportError.frameTooLarge(bytes: frame.count + 1, limit: limit)
                }
                buffer = Data(buffer[buffer.index(after: newline)...])
                return frame
            }
            // Refused at the moment it crosses the line, so a peer cannot make us buffer its whole
            // idea of a message before we get to disagree with it.
            guard buffer.count < limit else {
                throw TransportError.frameTooLarge(bytes: buffer.count, limit: limit)
            }
            let count = chunk.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(descriptor, raw.baseAddress, raw.count)
            }
            if count == 0 {
                if buffer.isEmpty { throw TransportError.closedByPeer }
                throw TransportError.truncated(bytes: buffer.count)
            }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK { throw TransportError.timedOut }
                throw TransportError.io("read()", code: code)
            }
            buffer.append(contentsOf: chunk[0 ..< count])
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
    ///
    /// With ONE exception, and it is a requirement rather than a relaxation:
    /// `Command.isServedConcurrently` — `abort`. The handler performs the whole tail of an attempt
    /// inline, so an abort that waited here would be decided only after the dictation it means to
    /// cancel had been typed. See the comment on that property for why both orders are safe.
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
    /// The live `watch` streams (D27), keyed so one can be removed without identity games. Guarded
    /// by `stateLock` like everything else here, and bounded by `ControlTimeouts.maxWatchers`.
    private var watchers: [Int: Watcher] = [:]
    private var nextWatcherID = 0

    /// One `watch` stream's outbox.
    ///
    /// It holds at most ONE event, and that is the coalescing rule rather than an optimisation: a
    /// UI wants the daemon's state now, never the history of how it got there, and a reader that
    /// fell behind must not be handed a queue to replay. `post` overwrites; the writer thread picks
    /// up whatever is there when it next looks.
    ///
    /// An `NSCondition` rather than a semaphore because two different things wake the writer — a
    /// new event, and the end of the stream — and they must be distinguishable when both are
    /// pending. The writer is the connection's own thread, which already exists and is already a
    /// real `Thread`; nothing new is spawned per watcher.
    private final class Watcher {
        private let condition = NSCondition()
        private var pending: WatchEvent?
        private var ending: WatchEvent?
        private var done = false

        /// The newest state. Replaces anything not yet written.
        func post(_ event: WatchEvent) {
            condition.lock()
            defer { condition.unlock() }
            guard !done else { return }
            pending = event
            condition.signal()
        }

        /// Ends the stream after at most one more update. Idempotent.
        func finish(_ event: WatchEvent) {
            condition.lock()
            defer { condition.unlock() }
            guard !done, ending == nil else { return }
            ending = event
            condition.signal()
        }

        /// Blocks until there is a frame to write, or the stream is over (`nil`).
        func next() -> WatchEvent? {
            condition.lock()
            defer { condition.unlock() }
            while pending == nil, ending == nil, !done { condition.wait() }
            if let event = pending {
                pending = nil
                return event
            }
            if let event = ending {
                ending = nil
                done = true
                return event
            }
            return nil
        }

        /// Wakes the writer with nothing to say, so it can leave.
        func cancel() {
            condition.lock()
            defer { condition.unlock() }
            done = true
            condition.signal()
        }
    }

    /// The socket file is removed by whichever of `stop` and `acceptLoop` gets there second, and
    /// only once the loop has actually exited: unlinking the path while the loop is still accepting
    /// on it leaves a live listener nobody can reach.
    private var listening: (listen: Int32, wakeup: Int32)? {
        stateLock.withLock { running ? (listenDescriptor, wakeupRead) : nil }
    }

    /// Called, on the accept thread, when the loop leaves WITHOUT having been asked to.
    ///
    /// Everything `acceptIsRetryable` does not name -- `EBADF`, `EINVAL`, `ENOTSOCK` -- breaks the
    /// loop. Closing the descriptors and unlinking the path is the right half of that: it makes
    /// `dictactl` say "dicta is not running", which is true. The other half is that the PROCESS is
    /// still alive, sitting in `RunLoop.main.run()`, so `KeepAlive` sees a healthy daemon and never
    /// restarts it -- every chord dead until somebody runs `launchctl kickstart` by hand. That is
    /// verbatim the unrecoverable failure the comment on `acceptIsRetryable` says this file exists
    /// to prevent, reached through the non-retryable door instead. The owner is given the chance to
    /// end the process so launchd can put it back.
    private let onUnexpectedExit: (@Sendable () -> Void)?

    public init(path: String,
                readTimeout: TimeInterval = ControlTimeouts.serverRead,
                onUnexpectedExit: (@Sendable () -> Void)? = nil,
                handler: @escaping Handler) {
        self.path = path
        self.readTimeout = readTimeout
        self.onUnexpectedExit = onUnexpectedExit
        self.handler = handler
    }

    /// Binds, listens, and starts accepting. Throws `alreadyRunning` when something is already
    /// listening on the path — §7's "second daemon instance attempted" row, and the reason the
    /// stale-socket check probes by connecting rather than by looking at the file.
    public func start() throws {
        let directory = (path as NSString).deletingLastPathComponent
        // `repairingMode: false`: the path is a flag's value, and a directory the user pointed at
        // is not one to re-permission. A directory created HERE is still 0700, which is the case
        // that matters -- the default one is dicta's own, and `Paths.support` repairs its mode by
        // the routes that do own it.
        try? Paths.createPrivateDirectory(URL(fileURLWithPath: directory, isDirectory: true),
                                          repairingMode: false)
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
        // Every watcher is TOLD the stream is over, rather than discovering it when the socket
        // closes underneath them (D27). A client reads a close as `closedByPeer` and reports that
        // the daemon died — so without this, an orderly `launchctl bootout` would put "dicta
        // crashed" in front of the user every single time, which is both false and the exact
        // alarm the UI exists to avoid raising.
        let live = stateLock.withLock { Array(watchers.values) }
        for watcher in live { watcher.finish(.end("the daemon is shutting down")) }
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
        // After `exited`, so an owner that ends the process cannot strand a `stop` waiting on it.
        if !askedToStop { onUnexpectedExit?() }
    }

    /// Hands the newest state to every live `watch` stream (D27).
    ///
    /// Safe to call from any thread and from inside a transition's aftermath: it takes `stateLock`
    /// only long enough to copy the list, and each `post` is a lock and a signal over one pointer.
    /// It never blocks on a socket — the writing happens on each watcher's own connection thread —
    /// so a wedged UI cannot slow a dictation down. That property is the reason this is a fan-out
    /// to outboxes rather than a loop of writes.
    /// How many `watch` streams are live. Exposed because registration happens on the connection's
    /// own thread, so a test that published immediately after connecting would be asserting on a
    /// race; and because "how many watchers are there" is the question the cap exists to answer.
    public var watcherCount: Int { stateLock.withLock { watchers.count } }

    public func publish(_ event: WatchEvent) {
        let live = stateLock.withLock { Array(watchers.values) }
        for watcher in live { watcher.post(event) }
    }

    /// Registers a watcher if there is room. `nil` means the cap is reached, and the caller answers
    /// with an ordinary refusal rather than by closing the connection.
    private func registerWatcher() -> (id: Int, watcher: Watcher)? {
        stateLock.withLock {
            guard running, watchers.count < ControlTimeouts.maxWatchers else { return nil }
            nextWatcherID += 1
            let watcher = Watcher()
            watchers[nextWatcherID] = watcher
            return (nextWatcherID, watcher)
        }
    }

    private func removeWatcher(_ id: Int) {
        stateLock.withLock { _ = watchers.removeValue(forKey: id) }
    }

    /// Writes frames to one watcher until the stream ends or the peer goes away.
    ///
    /// This runs on the connection's own thread, which would otherwise have returned. Nothing is
    /// read from the socket after the handshake: the client says nothing more, and a peer that has
    /// gone away is discovered by the write that fails — `EPIPE`, with `SIGPIPE` already silenced
    /// on this descriptor. A watcher that is simply idle costs one parked thread and no syscalls.
    private func stream(to client: Int32, watcher: Watcher) {
        while let event = watcher.next() {
            guard let frame = try? Wire.encode(event) else { continue }
            do {
                try Framing.write(frame, to: client)
            } catch {
                // The peer is gone. A dead watcher is not an event and is not retried: it is
                // dropped, and the client reconnects if it still cares.
                return
            }
            if event.kind == .end { return }
        }
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

        // `watch` is claimed BEFORE the handler runs, because the cap is a property of this server
        // and not of the daemon behind it — the handler has no idea how many sockets are open. Over
        // the cap the connection is answered and closed like any refused command; the stream simply
        // never starts.
        var registration: (id: Int, watcher: Watcher)?
        if case let .request(request) = incoming, request.cmd == .watch {
            registration = registerWatcher()
            if registration == nil {
                let refusal = Response(
                    kind: .rejected,
                    state: .idle,
                    message: "dicta is already serving \(ControlTimeouts.maxWatchers) watchers"
                )
                if let frame = try? Wire.encode(refusal) {
                    try? Framing.write(frame, to: client)
                }
                return
            }
        }
        // Registered above, so it is removed on every path out of here — including the ones that
        // return early below.
        defer { if let registration { removeWatcher(registration.id) } }

        // Serialised, except for the one verb whose whole point is to overtake the command in
        // flight (`Command.isServedConcurrently`). Taking the lock for `abort` too is what made
        // §6's `processing × abort → cancel` unreachable from a chord.
        let response = Self.overtakes(incoming)
            ? handler(incoming)
            : handlerLock.withLock { handler(incoming) }
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
        do {
            try Framing.write(frame, to: client)
        } catch {
            return
        }

        // Everything above is one frame in, one frame out — the shape every other verb has and
        // keeps. The stream begins only here, only for `watch`, and only once the daemon has
        // accepted: a refusal is an ordinary `Response` the client has already read.
        if let registration, response.kind == .accepted {
            stream(to: client, watcher: registration.watcher)
        }
    }

    /// Whether this frame may overtake the command in flight.
    ///
    /// A frame the server could not decode never does. It is answered like any other, but its verb
    /// is by definition unknown — and "may this run beside a live attempt?" is a question only a
    /// known verb can answer.
    private static func overtakes(_ incoming: Incoming) -> Bool {
        guard case let .request(request) = incoming else { return false }
        return request.cmd.isServedConcurrently
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
        /// The daemon answered the `watch` handshake with a refusal — the watcher cap, today. A
        /// distinct case because it is the one failure here that is not a fault: the daemon is
        /// healthy, it is answering, and it said no. A UI reporting it as unreachable would be
        /// wrong in the direction that matters.
        case watchRefused(String)

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
            case let .watchRefused(reason):
                "dicta refused to be watched: \(reason)"
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

    /// Opens a `watch` stream and delivers events until it ends (D27).
    ///
    /// **Blocks for the lifetime of the stream, so it must be called on a real `Thread`** — the
    /// same rule the server serves connections under, and for the same measured reason: on Darwin,
    /// Swift
    /// concurrency's executor shares the non-overcommit pool `DispatchQueue.global()` draws from,
    /// and that pool does not grow when its threads block. A watcher parked on a cooperative thread
    /// for hours is one worker that will never come back.
    ///
    /// `onEvent` runs on that thread. Callers that touch a UI hop to the main queue themselves;
    /// doing it here would make the transport know what its caller is.
    ///
    /// Returns normally when the daemon ends the stream, and throws when it could not be reached or
    /// the connection broke. The difference matters to the caller: the first is "the daemon stopped
    /// and said so", the second is "something went wrong", and a UI that showed the same thing for
    /// both would be the false crash report `WatchEvent` exists to prevent.
    public static func watch(
        to path: String = Paths.current.socket.path,
        connectTimeout: TimeInterval = ControlTimeouts.connect,
        idleTimeout: TimeInterval = ControlTimeouts.watchIdle,
        onEvent: (WatchEvent) -> Void
    ) throws {
        var address: sockaddr_un
        do {
            address = try unixAddress(for: path)
        } catch let error as TransportError {
            throw ClientError.transport(error)
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ClientError.transport(.io("socket()", code: errno)) }
        defer { close(descriptor) }
        silenceSIGPIPE(descriptor)

        guard let payload = try? Wire.encode(Request(cmd: .watch)) else {
            throw ClientError.malformedResponse("the watch request could not be encoded")
        }

        try connect(descriptor, to: &address, path: path, timeout: connectTimeout)
        // The handshake is one answer and deserves the ordinary short timeout; the STREAM is a
        // different question and gets `watchIdle` below. One number per verb cannot say both.
        setReadTimeout(descriptor, seconds: ControlTimeouts.read(for: .watch))

        var accepted: Response?
        do {
            try Framing.write(payload, to: descriptor)
            let frame = try Framing.readFrame(from: descriptor)
            let response = try Wire.decode(Response.self, from: frame)
            guard response.kind == .accepted else {
                throw ClientError.watchRefused(response.message ?? "dicta refused the watch")
            }
            accepted = response
        } catch let error as ClientError {
            throw error
        } catch TransportError.timedOut {
            throw ClientError.timedOut(seconds: ControlTimeouts.read(for: .watch))
        } catch TransportError.closedByPeer {
            throw ClientError.daemonCrashed(path: path)
        } catch let error as TransportError {
            throw ClientError.transport(error)
        } catch {
            throw ClientError.malformedResponse("\(error)")
        }

        // **The handshake's snapshot IS the stream's first event, and dropping it was a defect.**
        // The daemon publishes on TRANSITIONS, so a watcher that attaches to an idle daemon is told
        // nothing until somebody dictates. Measured 2026-08-24 (F9b): `dictactl watch` against a
        // healthy idle daemon printed nothing for as long as it was left running, and after a
        // daemon restart the menu-bar strip went on saying "dicta is not answering" over a
        // connection that had been live for minutes — a lie that sustains itself, since the user
        // does not dictate at a strip that says dicta is dead.
        //
        // Nothing had to be added to the wire for it. `Response.snapshot` is filled by the same
        // function `status` uses, precisely so the UI's first frame and its second cannot disagree
        // (see `Response.snapshot`); the client was being handed the answer and throwing it away.
        // The synthesised event carries no `sequence`, which is already the vocabulary for "not a
        // transition" — the daemon uses it for readiness changes and never drops one.
        if let snapshot = accepted?.snapshot {
            onEvent(WatchEvent.update(snapshot))
        }

        setReadTimeout(descriptor, seconds: idleTimeout)
        // A stream, so the reader must keep what arrived after the newline: `Framing.readFrame`
        // discards it, which is correct when a connection carries exactly one frame and wrong here.
        // Two events written back-to-back land in one `read`, and dropping the tail would silently
        // lose the newer one — the one that matters, since the newest state is the whole point.
        var buffered = Data()
        while true {
            let event: WatchEvent
            do {
                let frame = try Framing.readStreamedFrame(from: descriptor, buffer: &buffered)
                event = try Wire.decode(WatchEvent.self, from: frame)
            } catch TransportError.closedByPeer {
                // The daemon vanished without ending the stream: a crash, not a shutdown.
                throw ClientError.daemonCrashed(path: path)
            } catch TransportError.timedOut {
                throw ClientError.timedOut(seconds: idleTimeout)
            } catch let error as TransportError {
                throw ClientError.transport(error)
            } catch {
                throw ClientError.malformedResponse("\(error)")
            }
            onEvent(event)
            if event.kind == .end { return }
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
