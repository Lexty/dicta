import DictaCore
import Foundation

// The daemon's claim to be the one running (§7), taken before start-up reads or writes anything a
// second instance could also write.
//
// The control socket used to be the only claim, and it is made too late for that: `setup.json` is
// bootstrapped before the socket is bound, and a connect probe owns nothing. Two daemons starting
// together while no `setup.json` exists -- a flagless manual start beside a LaunchAgent that still
// carries `--focused-fields` -- would both pass the probe, both migrate, and the last to write
// would win, whatever the one that went on to bind had decided. An exclusive `flock(2)` on a file
// that is never removed is a claim the kernel keeps for exactly as long as the process lives, and
// gives up when it dies however it dies.

/// An exclusive, non-blocking `flock(2)` on `Paths.daemonLock`, held until released or the process
/// ends.
public final class DaemonLock: @unchecked Sendable {
    /// Why the lock was not taken. Only `alreadyRunning` means another daemon; the other two are
    /// this process failing to ask, and are told apart so the log does not blame a daemon that
    /// does not exist.
    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        /// Another process holds it.
        case alreadyRunning(path: String)
        /// The lock file could not be opened or created.
        case cannotOpen(path: String, code: Int32)
        /// `flock` failed for a reason other than somebody holding it.
        case cannotLock(path: String, code: Int32)

        public var description: String {
            switch self {
            case let .alreadyRunning(path):
                "another dicta daemon is already running: it holds \(path)"
            case let .cannotOpen(path, code):
                "the daemon lock \(path) could not be opened: " + String(cString: strerror(code))
            case let .cannotLock(path, code):
                "the daemon lock \(path) could not be taken: " + String(cString: strerror(code))
            }
        }
    }

    public let url: URL
    private let lock = NSLock()
    /// **Guarded by `lock`.** `-1` once released.
    private var descriptor: Int32

    private init(url: URL, descriptor: Int32) {
        self.url = url
        self.descriptor = descriptor
    }

    /// Takes the lock at `url`, creating the file and its directory when missing, or throws why.
    ///
    /// Opened read-only: `flock` needs no write access, and a lock file that already exists in a
    /// support directory somebody made read-only (§7, H42 (b)) is still a lock this daemon can
    /// take. The directory is created but never re-permissioned, for `SetupStore`'s reason.
    ///
    /// Close-on-exec, so a child the daemon runs -- `agtermctl`, `osascript` -- never inherits the
    /// descriptor and so can never keep the lock held after the daemon has exited.
    ///
    /// `flock`, when given, replaces the system call: a seam only because a failure other than
    /// contention cannot be produced on demand from a real disk. An optional rather than a default
    /// closure, because Swift reads `flock` inside one as the `struct flock` of `<sys/fcntl.h>`.
    public static func acquire(at url: URL,
                               flock lockCall: ((Int32, Int32) -> Int32)? = nil) throws
        -> DaemonLock {
        try? Paths.createPrivateDirectory(url.deletingLastPathComponent(), repairingMode: false)
        let path = url.path
        let descriptor = open(path, O_RDONLY | O_CREAT | O_CLOEXEC, mode_t(Paths.privateFileMode))
        guard descriptor >= 0 else { throw Failure.cannotOpen(path: path, code: errno) }
        let operation = LOCK_EX | LOCK_NB
        while (lockCall?(descriptor, operation) ?? flock(descriptor, operation)) != 0 {
            let code = errno
            if code == EINTR { continue }
            close(descriptor)
            throw code == EWOULDBLOCK
                ? Failure.alreadyRunning(path: path)
                : Failure.cannotLock(path: path, code: code)
        }
        return DaemonLock(url: url, descriptor: descriptor)
    }

    /// Gives the lock up by closing the descriptor. The file stays: removing it would let the next
    /// daemon lock a new inode while a process that opened the old one still believed it held the
    /// lock. Idempotent. The daemon never calls it; a test does, to play a daemon that exited.
    public func release() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            close(descriptor)
            descriptor = -1
        }
    }

    /// Whether the descriptor is closed on `exec`, for the test that holds the rule above.
    public var isCloseOnExec: Bool {
        lock.withLock {
            guard descriptor >= 0 else { return false }
            return fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0
        }
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }
}
