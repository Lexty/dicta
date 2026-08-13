import Foundation

/// The control protocol between `dictactl` and the daemon: one JSON object per line, in each
/// direction, then the connection closes. Flat structs with optional fields rather than enums with
/// associated values, so that a line stays readable — and typeable — by hand:
///
///     echo '{"cmd":"status"}' | nc -U ~/Library/Application\ Support/dev.personal.dicta/control.sock
public struct Request: Codable, Sendable, Equatable {
    public var cmd: String
    public var sessionID: String?
    public var socket: String?
    public var mode: StopMode?
    public var raw: Bool?

    public init(
        cmd: String,
        sessionID: String? = nil,
        socket: String? = nil,
        mode: StopMode? = nil,
        raw: Bool? = nil
    ) {
        self.cmd = cmd
        self.sessionID = sessionID
        self.socket = socket
        self.mode = mode
        self.raw = raw
    }
}

public struct Response: Codable, Sendable, Equatable {
    public var ok: Bool
    /// The daemon's state AFTER the command. Every response carries it, so the client never has to
    /// ask a second question to find out what happened.
    public var state: String
    public var id: RecordingID?
    public var message: String?
    public var text: String?

    public init(
        ok: Bool,
        state: String,
        id: RecordingID? = nil,
        message: String? = nil,
        text: String? = nil
    ) {
        self.ok = ok
        self.state = state
        self.id = id
        self.message = message
        self.text = text
    }
}

/// Which text the user asked for — decided when the recording is STOPPED, not when it starts.
public enum StopMode: String, Codable, Sendable, Equatable {
    /// Run the transcript through the filter (if one is configured) before injecting.
    case clean
    /// Inject the transcript as the recogniser produced it.
    case raw
}

public enum Pane: String, Codable, Sendable, Equatable {
    case left
    case right
    case scratch
}

/// Where the text will go. Captured when recording STARTS, so that wandering off to another
/// session mid-sentence cannot redirect the text — and re-validated before injection, because by
/// then the session may be gone.
public struct InjectionTarget: Codable, Sendable, Equatable {
    public var sessionID: String
    public var pane: Pane
    /// agterm's control socket (`$AGT_SOCKET`), so a non-default agterm instance still resolves.
    public var socket: String?

    public init(sessionID: String, pane: Pane, socket: String? = nil) {
        self.sessionID = sessionID
        self.pane = pane
        self.socket = socket
    }
}

public typealias RecordingID = Int

public enum Wire {
    public static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
