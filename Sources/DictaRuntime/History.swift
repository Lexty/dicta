import DictaCore
import DictaRecord
import Foundation

// The record's I/O half (§9): one file, opened for append, one `write` per entry.
//
// This is a seam like the other six, for the same reason and one more. Like them, it makes the rule
// worth asserting drivable without the world: §7's "history append fails" row -- still inject, then
// complain loudly -- cannot be produced from a real filesystem on demand without filling a disk.
// extra reason is that a test writing into the user's real record would be a test that corrupts the
// thing it is checking, so the daemon takes its history as a parameter and never reaches for
// `Paths.current` on its own.
//
// Why `O_APPEND` and one `write` rather than a `FileHandle` kept open: POSIX makes the seek-to-end
// and the write of an `O_APPEND` descriptor atomic with respect to other writers, so two processes
// appending -- the daemon, and anything a future task adds -- cannot interleave halves of a line.
// A `FileHandle` held open across an attempt would also survive a `logrotate`-style truncation as a
// descriptor pointing at nothing, and the whole file is written once per dictation, so keeping it
// open buys nothing.

/// The record, behind an interface a fake can satisfy completely.
public protocol History: Sendable {
    /// Appends one entry. Throws rather than swallowing: §7 requires the failure to be *loud*, and
    /// a writer that reported success would make property 2 fail silently -- which is the exact
    /// thing property 2 is about.
    func append(_ entry: RecordEntry) throws
    /// One entry per attempt, oldest first, with superseded lines collapsed (§9).
    func entries() throws -> [RecordEntry]
}

public extension History {
    /// What `dictactl last` asks about.
    func last() throws -> RecordEntry? {
        try entries().last
    }
}

public enum HistoryError: Error, Equatable, CustomStringConvertible {
    case cannotOpen(path: String, code: Int32)
    case cannotWrite(path: String, code: Int32)
    case cannotRead(path: String, reason: String)

    public var description: String {
        switch self {
        case let .cannotOpen(path, code):
            "the record at \(path) could not be opened: \(Self.strerror(code))"
        case let .cannotWrite(path, code):
            "the record at \(path) could not be written: \(Self.strerror(code))"
        case let .cannotRead(path, reason):
            "the record at \(path) could not be read: \(reason)"
        }
    }

    private static func strerror(_ code: Int32) -> String {
        String(cString: Foundation.strerror(code))
    }
}

/// The real record: `~/Library/Application Support/dev.personal.dicta/record.jsonl` by default.
public struct FileHistory: History, Sendable {
    public let url: URL

    public init(url: URL = Paths.current.record) {
        self.url = url
    }

    public func append(_ entry: RecordEntry) throws {
        let line = try Record.encode(entry)
        // Created on demand, `0700`, like the rest of the support directory: the record holds
        // every word the user has dictated, which is the most private file dicta owns.
        try? Paths.createPrivateDirectory(url.deletingLastPathComponent())
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard descriptor >= 0 else {
            throw HistoryError.cannotOpen(path: url.path, code: errno)
        }
        defer { close(descriptor) }
        try write(line, to: descriptor)
    }

    /// One `write` for the whole line in the ordinary case, so a concurrent appender cannot land
    /// between its halves. A short write is retried from where it stopped -- the alternative is
    /// giving up with a torn line on disk and no entry, and the reader tolerates a torn line.
    private func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Foundation.write(descriptor,
                                              buffer.baseAddress!.advanced(by: offset),
                                              buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw HistoryError.cannotWrite(path: url.path, code: errno)
                }
                // A zero-byte write with bytes still to go makes no progress, so retrying is an
                // infinite loop rather than a retry. §7 wants this failure LOUD; a daemon spinning
                // silently inside an append is the one shape it must never take.
                guard written > 0 else {
                    throw HistoryError.cannotWrite(path: url.path, code: ENOSPC)
                }
                offset += written
            }
        }
    }

    public func entries() throws -> [RecordEntry] {
        // Delegated, so the project has exactly ONE thing that turns bytes on disk into entries.
        // Two readers would eventually disagree about the superseding rule or about a torn tail,
        // and the disagreement would be between what `dictactl last` says and what the panel shows.
        //
        // The ERROR TYPE is translated rather than passed through: `HistoryError` is this seam's
        // contract, and a caller matching on it — §7's "the record cannot be read" row — would stop
        // matching if the reader's own error escaped. Delegating an implementation is not the same
        // as delegating an interface.
        do {
            return try RecordReader.all(in: url)
        } catch let error as RecordReader.ReaderError {
            throw HistoryError.cannotRead(path: url.path, reason: "\(error)")
        }
    }

    /// The last `count` attempts, without parsing the journal from the start (D27).
    ///
    /// Not on the `History` protocol: the daemon has no use for it, and a seam grows a method only
    /// when something behind it needs one. The menu-bar UI reads this file directly and read-only —
    /// it is a second reader of the record, never a second writer.
    public func tail(_ count: Int) throws -> RecordReader.Reading {
        try RecordReader.tail(of: url, entries: count)
    }

    /// Every line, including ones a later line supersedes. What "append-only" looks like from
    /// outside, and what a test asserting it has to be able to see.
    public func lines() throws -> [RecordEntry] {
        Record.lines(in: try contents())
    }

    private func contents() throws -> Data {
        // An absent file is an empty record, not an error: it is what a fresh install looks like,
        // and `dictactl last` on it should say "nothing yet" rather than fail.
        guard FileManager.default.fileExists(atPath: url.path) else { return Data() }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw HistoryError.cannotRead(path: url.path, reason: "\(error)")
        }
    }
}
