import Foundation

/// Where `agtermctl` is, and it is not "wherever the shell would find it".
///
/// A LaunchAgent's `PATH` is not a login shell's (§12), so the absolute paths come first and `PATH`
/// is only the fallback. That is an operational fact rather than a preference, and it lives here —
/// in the module every client links — because there are now **two** processes that shell out to
/// agterm for different reasons: the daemon, which resolves and types, and the menu-bar UI, which
/// asks a live tree what a session is CALLED so the target line reads `claude-code · left` instead
/// of a UUID. Two copies of this list would be two chances to fix a path in one of them.
///
/// It is not in `DictaRuntime` for the ordinary reason: that module links FluidAudio, and the menu
/// binary must not be able to reach the capture stack at all (D27, invariant 8).
public enum AgtermTool {
    public static let candidatePaths = ["/opt/homebrew/bin/agtermctl", "/usr/local/bin/agtermctl"]

    /// The first `agtermctl` that exists, or `nil` when there is none anywhere — which is a
    /// startup-time diagnosis, not something to discover on the first chord.
    ///
    /// The candidate list is a parameter so this has a test: on the machine that runs the suite,
    /// `/opt/homebrew/bin/agtermctl` exists, and a lookup that always finds it asserts nothing.
    public static func locate(
        candidates: [String] = AgtermTool.candidatePaths,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let searchPath = (environment["PATH"] ?? "").split(separator: ":").map {
            "\($0)/agtermctl"
        }
        return (candidates + searchPath).first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }
}
