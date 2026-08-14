/// DictaCore is pure: no I/O, no subprocesses, no clock of its own. Every decision the spec makes
/// lands here as a value, and its test lands in DictaTestRunner (D19).
///
/// `Wire`, `Paths` and `Sanitizer` arrived in Task 2 and `StateMachine` in Task 3; Tasks 7 and 11
/// add the record schema and the replacement engine.
public enum DictaCore {
    /// The source-level version, and nothing more. It is deliberately NOT what identifies a build:
    /// `RecordEntry` carries no version field and `Response` carries none either, so an entry
    /// cannot be read back against the binary that wrote it from here. What can answer that is
    /// `DictaBuildRevision` in the bundle's `Info.plist`, which `bundle.sh` stamps with
    /// `git describe`.
    public static let version = "0.1.0"
}
