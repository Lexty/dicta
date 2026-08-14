import Foundation

/// Where dicta keeps its four files.
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
    public static func createPrivateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
