import DictaCore
import Foundation

/// Every attempt, appended as one JSON line: when, what was heard, what was injected, where it was
/// going and how it ended.
///
/// This is not logging for its own sake — it is the only way text survives the failures that
/// otherwise eat it. The target session closed, a replacement rule misfired, the duration cap
/// fired: in all of those the audio is gone and the transcript is the only copy. `dictactl last`
/// reads it back.
public struct HistoryEntry: Codable, Sendable, Equatable {
    public var id: RecordingID
    public var at: Date
    public var mode: String
    public var outcome: String
    public var raw: String
    public var text: String
    public var sessionID: String
    public var pane: String
    public var error: String?

    public init(
        id: RecordingID,
        at: Date = Date(),
        mode: String,
        outcome: String,
        raw: String,
        text: String,
        target: InjectionTarget,
        error: String? = nil
    ) {
        self.id = id
        self.at = at
        self.mode = mode
        self.outcome = outcome
        self.raw = raw
        self.text = text
        self.sessionID = target.sessionID
        self.pane = target.pane.rawValue
        self.error = error
    }
}

public struct History: Sendable {
    private let url: URL

    public init(url: URL = Paths.history) {
        self.url = url
    }

    public func append(_ entry: HistoryEntry) {
        guard let line = try? Wire.encode(entry) else { return }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
    }

    /// The most recent entry that produced usable text, whatever became of it afterwards — a failed
    /// injection still leaves text worth recovering.
    public func last() -> HistoryEntry? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in contents.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let entry = try? Wire.decode(HistoryEntry.self, from: data)
            else { continue }
            if !entry.raw.isEmpty { return entry }
        }
        return nil
    }
}
