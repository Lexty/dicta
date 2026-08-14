import DictaCore

/// DictaIPC holds both halves of the Unix-socket transport, deliberately in one module so the
/// client's framing rules and the server's cannot drift apart.
///
/// `ControlSocket.swift` is the whole of it: `Framing`, `ControlServer` and `ControlClient`.
public enum DictaIPC {
    /// The transport speaks JSON lines. Bumped only when the framing changes, not when a command
    /// is added — client and daemon ship together and are always in lockstep.
    public static let wireVersion = 1
}
