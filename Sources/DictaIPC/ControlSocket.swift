import DictaCore
import Foundation

/// The daemon's Unix-socket front door. One JSON line in, one JSON line out, connection closed.
///
/// Blocking accept on a dedicated thread rather than non-blocking `DispatchSource` plumbing: the
/// client is a keypress, so there is never meaningful concurrency to manage, and the simpler shape
/// has fewer descriptor-ownership mistakes available to it.
public final class ControlServer: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case alreadyRunning(String)
        case bindFailed(String, Int32)

        public var description: String {
            switch self {
            case .alreadyRunning(let path):
                "демон уже запущен (живой сокет \(path))"
            case .bindFailed(let what, let errno):
                "не удалось поднять сокет: \(what) errno=\(errno)"
            }
        }
    }

    private let path: String
    private let handler: @Sendable (Request) async -> Response
    private var listenFD: Int32 = -1
    private var thread: Thread?
    private var stopping = false

    public init(path: String = Paths.socket, handler: @escaping @Sendable (Request) async -> Response) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try clearStaleSocket()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.bindFailed("socket()", errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw Failure.bindFailed("путь к сокету слишком длинный", 0)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else {
            close(fd)
            throw Failure.bindFailed("bind()", errno)
        }
        // 0600 in a 0700 directory IS the whole access-control story — see Paths.socket.
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw Failure.bindFailed("listen()", errno)
        }
        listenFD = fd

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "dev.personal.dicta.control"
        thread.start()
        self.thread = thread
    }

    public func stop() {
        stopping = true
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(path)
    }

    /// A socket file left behind by a crashed daemon must be removed — but a socket belonging to a
    /// LIVE daemon must never be, or two instances would fight over the microphone. The only honest
    /// test is to try connecting: refused means nobody is listening.
    private func clearStaleSocket() throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw Failure.bindFailed("socket() probe", errno) }
        defer { close(probe) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: Array(path.utf8))
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, size) }
        }
        if connected == 0 {
            throw Failure.alreadyRunning(path)
        }
        unlink(path)
    }

    private func acceptLoop() {
        while !stopping, listenFD >= 0 {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else {
                if stopping { return }
                continue
            }
            serve(client)
            close(client)
        }
    }

    private func serve(_ client: Int32) {
        guard let line = readLine(from: client) else { return }
        let response: Response
        if let request = try? Wire.decode(Request.self, from: line) {
            response = await_(request)
        } else {
            response = Response(ok: false, state: "unknown", message: "не разобрал запрос")
        }
        if let data = try? Wire.encode(response) {
            data.withUnsafeBytes { raw in
                _ = write(client, raw.baseAddress, raw.count)
            }
        }
    }

    /// Bridges the blocking accept thread to the async handler. The thread exists to be blocked;
    /// nothing else is waiting on it.
    private func await_(_ request: Request) -> Response {
        let box = ResponseBox()
        let semaphore = DispatchSemaphore(value: 0)
        let handler = self.handler
        Task {
            box.value = await handler(request)
            semaphore.signal()
        }
        semaphore.wait()
        return box.value ?? Response(ok: false, state: "unknown", message: "нет ответа")
    }

    private func readLine(from fd: Int32) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < 64 * 1024 {
            let n = read(fd, &byte, 1)
            if n <= 0 { break }
            if byte == 0x0A { break }
            data.append(byte)
        }
        return data.isEmpty ? nil : data
    }
}

private final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Response?

    var value: Response? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// The client half, used by `dictactl`. Lives here next to the server so the two framing rules
/// cannot drift apart, and is duplicated into no other target.
public enum ControlClient {
    public enum Failure: Error, CustomStringConvertible {
        case notRunning
        case ioFailed(String)

        public var description: String {
            switch self {
            case .notRunning: "демон dicta не запущен"
            case .ioFailed(let what): "сбой обмена с демоном: \(what)"
            }
        }
    }

    public static func send(_ request: Request, to path: String = Paths.socket) throws -> Response {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.ioFailed("socket()") }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: Array(path.utf8))
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard connected == 0 else { throw Failure.notRunning }

        let payload = try Wire.encode(request)
        let written = payload.withUnsafeBytes { raw in
            write(fd, raw.baseAddress, raw.count)
        }
        guard written == payload.count else { throw Failure.ioFailed("write()") }

        var data = Data()
        var byte: UInt8 = 0
        while data.count < 64 * 1024 {
            let n = read(fd, &byte, 1)
            if n <= 0 { break }
            if byte == 0x0A { break }
            data.append(byte)
        }
        guard !data.isEmpty else { throw Failure.ioFailed("пустой ответ") }
        return try Wire.decode(Response.self, from: data)
    }
}
