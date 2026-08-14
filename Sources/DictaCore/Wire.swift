import Foundation

// The control protocol between `dictactl` and the daemon: one JSON object per line, in each
// direction, then the connection closes. Flat structs with optional fields rather than enums with
// associated values, so that a frame stays readable — and typeable — by hand:
//
//     echo '{"cmd":"status"}' \
//         | nc -U ~/Library/Application\ Support/dev.personal.dicta/control.sock
//
// The vocabulary is §6's, not a looser one: states and commands are enums, so an unknown value is a
// decode error at the edge rather than a string the daemon has to re-interpret in five places.

/// What the client asks for. `toggle` is the one the chords call (D7): start-or-stop is resolved
/// inside the daemon, atomically, because `status | grep idle && start || stop` is two round trips
/// with a race between them in which one keypress can both start and stop.
public enum Command: String, Codable, Sendable, CaseIterable {
    case status
    case toggle
    case start
    case stop
    case abort
    case last
}

/// Which text the user asked for — decided by the chord that STOPS the recording (D3), not by the
/// one that starts it. It selects exactly one thing: whether the **filtered** stage runs (§2).
public enum Mode: String, Codable, Sendable, CaseIterable {
    /// Run the text through the filter, when one is configured.
    case clean
    /// Skip the **filtered** stage and nothing else. Not "unsanitised", not "unreplaced".
    case raw
}

/// The lifecycle of an attempt (§6). `warming` is a distinct state rather than an implementation
/// detail: it is what lets D13 hold, and what lets a client tell "coming up" from "ready".
public enum LifecycleState: String, Codable, Sendable, CaseIterable {
    case idle
    case warming
    case recording
    case processing
    case injecting
}

/// How the daemon treated a command, in the terms §6 draws the line in: a rejection is audible, a
/// no-op is silent. These are separate values rather than one flag read two ways, because the
/// difference is a sound the user hears — pressing stop again because nothing visibly happened is
/// normal behaviour, and an alarming noise would punish it.
public enum CommandOutcome: String, Codable, Sendable, CaseIterable {
    /// The command took effect.
    case accepted
    /// The command was refused and the user is told why, with `Basso`.
    case rejected
    /// The command was legitimate here and did nothing. Silent, deliberately.
    case noop

    /// Whether the daemon plays the rejection sound. Accepted commands are announced by the state's
    /// own feedback (`Pop`, `Tink`) and only once capture confirms it is running (D13) — never by
    /// the response itself.
    public var isAudible: Bool { self == .rejected }
}

/// A monotonic attempt id, never reused (§2). Present on the wire so that a command naming a spent
/// attempt is *recognisable* as spent rather than guessed at from the state alone.
public typealias AttemptID = Int

/// A pane of an agterm session, as `agtermctl tree --json` names the surface kind.
///
/// Deliberately a closed enum: an unrecognised kind fails to decode, which is the fail-closed
/// behaviour D6 asks for. Accepting an unknown pane would be D4's forbidden substitution wearing a
/// different hat.
public enum Pane: String, Codable, Sendable, CaseIterable {
    case left
    case right
    case scratch
}

/// Where an attempt's text goes: a session id plus a pane (§5). The two halves are **not** equally
/// accurate — the session id is keypress-accurate, the pane is live focus roughly 40 ms later — and
/// this type exists so that both are carried together and re-validated together before injection.
public struct Target: Codable, Sendable, Equatable {
    public var sessionID: String
    public var pane: Pane

    public init(sessionID: String, pane: Pane) {
        self.sessionID = sessionID
        self.pane = pane
    }
}

/// One line from the client.
///
/// Note what is absent: a pane. The installed agterm does not export `$AGT_PANE` to keymap commands
/// (F3), so the client genuinely cannot know it, and a field for it would only invite a guess. The
/// daemon resolves the pane from the live tree and reports it back on the `Response` (D6, §5).
public struct Request: Codable, Sendable, Equatable {
    public var cmd: Command
    /// `$AGT_SESSION_ID`, expanded by agterm at the instant the chord fired.
    public var sessionID: String?
    /// `$AGT_SOCKET`, so a non-default agterm instance still resolves.
    public var agtermSocket: String?
    /// Which text to deliver, on the command that stops an attempt (D3).
    public var mode: Mode?
    /// The attempt this command is about, when the caller knows it. A chord does not: the daemon
    /// owns the id, so `toggle` names none.
    public var attempt: AttemptID?
    /// `last --recognised`: print the recogniser's verbatim output rather than what was injected.
    /// Reading text back is not injection, so the sanitiser does not apply to it (§9), and the two
    /// fields differing is the whole way a replacement misfire is diagnosed.
    public var verbatim: Bool?

    public init(
        cmd: Command,
        sessionID: String? = nil,
        agtermSocket: String? = nil,
        mode: Mode? = nil,
        attempt: AttemptID? = nil,
        verbatim: Bool? = nil
    ) {
        self.cmd = cmd
        self.sessionID = sessionID
        self.agtermSocket = agtermSocket
        self.mode = mode
        self.attempt = attempt
        self.verbatim = verbatim
    }
}

/// One line back. Every response carries the state the daemon is in **after** the command, so the
/// client never has to ask a second question to find out what happened — the same reasoning that
/// produced D7.
public struct Response: Codable, Sendable, Equatable {
    public var kind: CommandOutcome
    public var state: LifecycleState
    public var attempt: AttemptID?
    /// The resolved target, once both halves are known.
    public var target: Target?
    /// The reason, in the words the user sees.
    public var message: String?
    /// Text the command was asked to produce — `last` and nothing else so far. Reading text back is
    /// not injection, so invariant 1 does not apply to it (§9).
    public var text: String?

    public init(
        kind: CommandOutcome,
        state: LifecycleState,
        attempt: AttemptID? = nil,
        target: Target? = nil,
        message: String? = nil,
        text: String? = nil
    ) {
        self.kind = kind
        self.state = state
        self.attempt = attempt
        self.target = target
        self.message = message
        self.text = text
    }
}

public enum WireError: Error, Equatable, CustomStringConvertible {
    case frameTooLarge(bytes: Int, limit: Int)
    case emptyFrame

    public var description: String {
        switch self {
        case let .frameTooLarge(bytes, limit):
            "frame of \(bytes) bytes exceeds the \(limit)-byte limit"
        case .emptyFrame:
            "empty frame — the peer closed the connection without answering"
        }
    }
}

/// JSON-lines framing, shared by both ends. `DictaIPC` owns the socket; this owns what a frame
/// *is*, so the size limit cannot be enforced in one direction and forgotten in the other.
public enum Wire {
    /// The largest frame either end will produce or accept, including its terminating newline.
    ///
    /// Ten minutes of speech — the duration cap (D15) — is on the order of 10 KB of text, so this
    /// is roughly six times the longest legitimate frame. It exists to bound what a confused or
    /// hostile peer can make the other end buffer, not to constrain dictation. §7 gives recogniser
    /// output longer than this its own row: no injection, and the byte length reaches the record.
    public static let maxFrameBytes = 64 * 1024

    /// Encodes one frame, newline-terminated. Throws rather than truncating: a truncated frame is
    /// invalid JSON at the far end, which would report as a protocol error and hide the real cause.
    public static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        guard data.count <= maxFrameBytes else {
            throw WireError.frameTooLarge(bytes: data.count, limit: maxFrameBytes)
        }
        return data
    }

    /// Decodes one frame, with or without its trailing newline. The size check runs **before**
    /// parsing, so an oversized frame costs nothing to reject.
    public static func decode<T: Decodable>(_ type: T.Type, from frame: Data) throws -> T {
        guard frame.count <= maxFrameBytes else {
            throw WireError.frameTooLarge(bytes: frame.count, limit: maxFrameBytes)
        }
        var body = frame
        while let last = body.last, last == 0x0A || last == 0x0D {
            body.removeLast()
        }
        guard !body.isEmpty, body.contains(where: { $0 != 0x20 && $0 != 0x09 }) else {
            throw WireError.emptyFrame
        }
        return try JSONDecoder().decode(type, from: body)
    }
}
