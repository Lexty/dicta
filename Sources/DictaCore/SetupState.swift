import Foundation

/// Where dictation goes, as the person chose it (D31 as amended on 2026-09-13).
///
/// The raw values are what `setup.json` and the wire carry, hyphenated like every other raw value
/// dicta writes.
public enum SetupScope: String, Codable, Sendable, CaseIterable {
    /// Nobody has chosen yet. The agterm path works as it always did; fields stay closed and no
    /// accessibility call is made. Nobody chooses it: `configure` refuses it.
    case undecided
    /// agterm's panes only.
    case agtermOnly = "agterm-only"
    /// agterm's panes, and the focused text field of any other application.
    case otherApps = "other-apps"
}

/// The choice as `setup.json` keeps it: `{"schema": 1, "scope": "other-apps", "offerSeen": true}`.
///
/// Three facts rather than one revision number, so a schema bump never asks anybody again.
/// `offerSeen` records that the one-time offer, "Dicta can now type into other apps", was answered.
///
/// Only `Encodable`: the one way in is `decode(_:)`, which judges the bytes. A synthesized
/// `Decodable` would read a newer build's schema as if it were this one's.
public struct SetupState: Encodable, Sendable, Equatable {
    /// The schema this build writes, and the newest it reads.
    public static let currentSchema = 1

    public var schema: Int
    public var scope: SetupScope
    public var offerSeen: Bool

    public init(scope: SetupScope, offerSeen: Bool, schema: Int = SetupState.currentSchema) {
        self.schema = schema
        self.scope = scope
        self.offerSeen = offerSeen
    }

    /// The bytes the store writes. Sorted keys, so the same state is always the same file.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Judges `setup.json`'s bytes. Never a default: anything this build cannot read with certainty
    /// is a `SetupLoadProblem`, because guessing a scope would either type into applications nobody
    /// chose or silence a choice somebody made (§7).
    ///
    /// The schema is read on its own and first. A newer build may have added a scope or reshaped a
    /// key, and calling that "invalid" would send the person to repair a file that is not broken.
    /// Unknown keys are ignored.
    public static func decode(_ data: Data) -> Result<SetupState, SetupLoadProblem> {
        let decoder = JSONDecoder()
        let schema: Int
        do {
            schema = try decoder.decode(SchemaOnly.self, from: data).schema
        } catch {
            return .failure(.unreadable(reason: "not a setup file: \(Self.describe(error))"))
        }
        if schema > currentSchema {
            return .failure(.newerSchema(found: schema))
        }
        guard schema >= 1 else {
            return .failure(.unreadable(reason: "schema \(schema) was never written"))
        }
        let raw: Raw
        do {
            raw = try decoder.decode(Raw.self, from: data)
        } catch {
            return .failure(.unreadable(reason: "not a setup file: \(Self.describe(error))"))
        }
        guard let scope = SetupScope(rawValue: raw.scope) else {
            return .failure(.unreadable(reason: "unknown scope \"\(raw.scope)\""))
        }
        return .success(SetupState(scope: scope, offerSeen: raw.offerSeen, schema: schema))
    }

    private struct SchemaOnly: Decodable {
        let schema: Int
    }

    private struct Raw: Decodable {
        let scope: String
        let offerSeen: Bool
    }

    /// A decoding error in one line: which key, and what was wrong with it. The default description
    /// of a `DecodingError` is a nested dump nobody reads in a log.
    private static func describe(_ error: Error) -> String {
        switch error as? DecodingError {
        case let .keyNotFound(key, _):
            "\"\(key.stringValue)\" is missing"
        case let .typeMismatch(_, context), let .valueNotFound(_, context):
            "\"\(context.codingPath.map(\.stringValue).joined(separator: "."))\" has the wrong type"
        case .dataCorrupted:
            "invalid JSON"
        case nil:
            "\(error)"
        @unknown default:
            "\(error)"
        }
    }
}

/// Why `setup.json` could not be used. Reported in the log and the snapshot, standing until a
/// replacement succeeds; the reader never overwrites the file (D31, §7).
public enum SetupLoadProblem: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    /// Invalid JSON, a missing or mistyped key, or a scope this build does not know.
    case unreadable(reason: String)
    /// Written by a newer build. Not broken, but not this build's to interpret.
    case newerSchema(found: Int)

    public var description: String {
        switch self {
        case let .unreadable(reason):
            "setup.json is unreadable: \(reason)"
        case let .newerSchema(found):
            "setup.json has schema \(found), newer than this build's \(SetupState.currentSchema)"
        }
    }
}

/// What start-up decided about the choice, and everything the log needs to say about how.
///
/// Produced by `SetupStore.bootstrap` in DictaRuntime, and kept here as a plain value so that the
/// log lines describing it are a pure decision too (`StartupLines`).
public struct SetupBootstrap: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// Read from an existing `setup.json`.
        case file
        /// No file existed; decided by `SetupMigration` from these facts, and written.
        case migrated(flag: Bool, record: SetupMigration.RecordFact)
        /// The file exists and cannot be used; nothing was written.
        case unreadable(SetupLoadProblem)
    }

    /// The state in force for this run. For an unreadable file, `SetupStore.whileUnreadable`.
    public var state: SetupState
    public var source: Source
    /// `--focused-fields` was given, and an existing file — readable or not — decided instead.
    public var flagIgnored: Bool
    /// The migrated state could not be written. It still applies for this run.
    public var saveError: String?

    public init(state: SetupState, source: Source, flagIgnored: Bool, saveError: String?) {
        self.state = state
        self.source = source
        self.flagIgnored = flagIgnored
        self.saveError = saveError
    }
}

/// What a daemon with no `setup.json` decides, and writes (D31). Used only while the file does not
/// exist; afterwards the file decides and the flag is ignored.
public enum SetupMigration {
    /// What the record (§9) says about whether anybody has dictated here before.
    public enum RecordFact: Sendable, Equatable {
        /// Read successfully, with this many entries. No file reads as zero.
        case lines(Int)
        /// The read failed. Counted as an update, never a fresh install: somebody whose record
        /// cannot be read has most likely dictated, and must not find agterm dictation waiting on
        /// a window.
        case unreadable
    }

    /// The flag, then whether the record holds any line. Having agterm installed is not taken as
    /// intent, so it is not an input.
    public static func initial(flag: Bool, record: RecordFact) -> SetupState {
        if flag {
            return SetupState(scope: .otherApps, offerSeen: true)
        }
        switch record {
        case .unreadable:
            return SetupState(scope: .agtermOnly, offerSeen: false)
        case let .lines(count):
            return SetupState(scope: count > 0 ? .agtermOnly : .undecided, offerSeen: false)
        }
    }

    /// The fact from a read of the record. Every entry counts, whatever its outcome: an aborted
    /// attempt is still somebody having dictated.
    public static func recordFact(_ read: Result<[RecordEntry], any Error>) -> RecordFact {
        switch read {
        case let .success(entries): .lines(entries.count)
        case .failure: .unreadable
        }
    }
}
