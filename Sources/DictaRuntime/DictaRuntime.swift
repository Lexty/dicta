import DictaCore
import DictaIPC

/// DictaRuntime is everything that touches the world: the agterm adapter, capture, recognition,
/// the filter seam, the record writer. Each of those sits behind a seam with a fake, so the whole
/// lifecycle is drivable with no microphone, no model and no terminal (D19).
///
/// Task 1 puts only the module marker here. Task 5 adds the seams and their fakes, Task 6 the
/// daemon.
public enum DictaRuntime {
    /// Kept as a library rather than folded into the `Dicta` executable for one mechanical reason:
    /// SwiftPM cannot import an executable target, so code living there is unreachable from the
    /// test runner.
    public static let isLibrary = true
}
