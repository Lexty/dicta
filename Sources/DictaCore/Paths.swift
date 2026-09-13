import Foundation

/// Where dicta keeps its files.
///
/// All of them sit in one directory under `~/Library/Application Support`, named after the bundle
/// id — the same identity the microphone TCC grant attaches to (D11). One directory rather than
/// the XDG-ish spread of `~/.config` and `~/.local/state` the deleted skeleton used: there is one
/// owner, one thing to back up, and one thing to delete.
///
/// The home directory is a stored value rather than a global read, so a test can point the whole
/// layout at a temporary directory without touching the real one.
public struct Paths: Sendable, Equatable {
    public static let bundleID = "dev.personal.dicta"

    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// The real layout, for the current user.
    public static var current: Paths { Paths() }

    public var support: URL {
        home.appendingPathComponent("Library/Application Support/\(Self.bundleID)",
                                    isDirectory: true)
    }

    /// The control socket. The trust boundary is the filesystem and nothing else: a socket inside a
    /// `0700` directory owned by the current uid. No token — any process running as this user can
    /// already act as this user. An absent socket means "the daemon is not running", which is why
    /// nothing here launches one on demand.
    public var socket: URL { support.appendingPathComponent("control.sock") }

    /// Every attempt, successful or not, one line each (§9). This is the only route by which text
    /// survives the failures that would otherwise eat it (D17, invariant 10).
    public var record: URL { support.appendingPathComponent("record.jsonl") }

    /// The Tier 0 replacement dictionary (D9a). Hand-edited, so it is a `.conf` and not JSON.
    public var dictionary: URL { support.appendingPathComponent("replacements.conf") }

    /// Everything else that is configurable — the filter command of D9b, when step 4 arrives.
    public var config: URL { support.appendingPathComponent("config.json") }

    /// Where dictation goes, as the person chose it (D31): `SetupState`, written by the daemon
    /// alone. A file of its own rather than a key in `config`, which is D9b's and hand-edited.
    public var setup: URL { support.appendingPathComponent("setup.json") }

    /// Held by the running daemon for its whole life (`DaemonLock`), and taken before it reads or
    /// writes `setup.json`. Here rather than beside the socket, whose path `--control` moves: two
    /// daemons on two sockets still share this `setup.json`, so they must share this lock. Never
    /// removed -- a second inode at the same path would be a second lock two owners could hold.
    public var daemonLock: URL { support.appendingPathComponent("daemon.lock") }

    /// Creates the support directory if it is missing, and returns it. Idempotent, so a caller may
    /// invoke it on every start without checking first.
    @discardableResult
    public func createSupportDirectory() throws -> URL {
        try Self.createPrivateDirectory(support)
        return support
    }

    /// Creates `directory` at `0700`, with intermediates. Every file dicta owns is created on
    /// demand, by whichever of the socket, the record and the parked target gets there first —
    /// each from a URL a test can redirect, so none of them can simply call
    /// `createSupportDirectory()`. What they CAN share is this, and they must: `0700` is not
    /// decoration, it is the premise of the socket carrying no token (see `socket`), and it was
    /// open-coded at three call sites with the canonical one reachable from nothing but a test.
    ///
    /// The `chmod` after the create is not belt-and-braces. `createDirectory` **ignores
    /// `attributes` entirely when the directory already exists** -- it succeeds and returns, and
    /// the mode it was handed is never applied. So a support directory that arrived any other way
    /// (restored from a backup, left by an earlier build, created under a loose umask) kept
    /// whatever mode it had, for ever, with nothing here noticing. The premise above would then be
    /// a sentence in a comment rather than a fact about the filesystem.
    /// `repairingMode` is what decides whether that `chmod` runs at all, and it is false for one
    /// caller alone: the directory holding the control socket, whose path a user can name with
    /// `--control`. Repairing a directory dicta owns is maintenance; re-permissioning one the user
    /// merely pointed at is not. `Dicta --control ~/dicta.sock` would otherwise chmod `$HOME` to
    /// 0700 -- silently, since the call site cannot even see the failure it swallows.
    public static func createPrivateDirectory(_ directory: URL, repairingMode: Bool = true) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard repairingMode else { return }
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: directory.path)
    }

    /// The mode every file dicta writes is created with: readable and writable by this uid alone.
    /// The socket is `chmod 0600` and the record is opened `0o600`; anything written with
    /// `Data.write` lands at `0644` unless it is told otherwise, which is the one way a file here
    /// ends up more readable than the directory holding it.
    public static let privateFileMode = 0o600
}
