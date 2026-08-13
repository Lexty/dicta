import Foundation

public enum Paths {
    public static let bundleID = "dev.personal.dicta"

    /// The control socket. The trust boundary is the filesystem and nothing else: a `0600` socket
    /// inside a `0700` directory owned by the current uid. No token — any process running as this
    /// user can already act as this user. An absent socket means "the daemon is not running", which
    /// is why nothing here launches on demand.
    public static var socket: String {
        support.appendingPathComponent("control.sock").path
    }

    public static var support: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(bundleID)", isDirectory: true)
    }

    /// Every attempt, successful or not, with both the raw and the cleaned text. This is how text
    /// survives the failures that would otherwise eat it: the target session closed, a replacement
    /// rule misfired, the run hit the duration cap.
    public static var history: URL {
        state.appendingPathComponent("history.jsonl")
    }

    public static var state: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/dicta", isDirectory: true)
    }

    public static var config: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".config/dicta", isDirectory: true)
    }
}
