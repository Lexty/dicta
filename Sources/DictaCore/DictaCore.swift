/// DictaCore is pure: no I/O, no subprocesses, no clock of its own. Every decision the spec makes
/// lands here as a value, and its test lands in DictaTestRunner (D19).
///
/// `Wire`, `Paths` and `Sanitizer` arrived in Task 2 and `StateMachine` in Task 3; Tasks 7 and 11
/// add the record schema and the replacement engine.
public enum DictaCore {
    /// Reported by `dictactl status` and stamped into the record, so an entry can be read back
    /// against the build that wrote it.
    public static let version = "0.1.0"
}
