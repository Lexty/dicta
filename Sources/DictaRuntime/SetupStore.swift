import DictaCore
import Foundation

// `setup.json`'s I/O half (D31 as amended on 2026-09-13). What the bytes mean, and what a daemon
// with no file decides, are `SetupState` and `SetupMigration` in `DictaCore`; this is only the
// reading and writing around those decisions, and the two facts that outlive one call: a load
// problem standing until a replacement succeeds, and the last failed write.
//
// The daemon is the file's one writer. A write never truncates `setup.json` in place: it goes
// through `setup.json.tmp`, synced, then `rename(2)`, so a reader sees the old state or the new one
// and never half of either. A replacement of an unreadable file additionally hard-links the
// original to `setup.json.unreadable` before the rename, so there is no moment without the
// authoritative path, and a failure at any step before the rename leaves `setup.json`
// byte-identical — which is what keeps a restart from re-migrating a file somebody failed to fix.
// That is the operational failure contract, not a power-loss transaction: there is no journal.

/// What reading `setup.json` found.
public enum SetupLoad: Sendable, Equatable {
    /// No file: the only case in which the migration runs.
    case absent
    case loaded(SetupState)
    /// Present, and not this build's to interpret. Never overwritten by the reader.
    case unreadable(SetupLoadProblem)
}

/// Why a write of `setup.json` failed: the step, the path it acted on, and `errno`.
public enum SetupStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    case failed(step: SetupStore.Step, path: String, code: Int32)

    public var description: String {
        switch self {
        case let .failed(step, path, code):
            "setup.json could not be saved: \(step.rawValue) \(path) failed: "
                + String(cString: strerror(code))
        }
    }
}

/// What the daemon needs of the store once start-up is over: a person's choice written, and the two
/// facts that outlive a write. A protocol so a daemon test can observe the order `configure` keeps
/// -- persist, then the gate, then publish -- from inside the write, and fail one on demand.
public protocol SetupPersisting: AnyObject, Sendable {
    /// Writes `state` as `configure` does, replacing while a load problem stands; throws why not.
    func write(_ state: SetupState) throws
    /// The load problem standing until a replacement succeeds.
    var loadProblem: SetupLoadProblem? { get }
    /// The last failed write, cleared by the next one that succeeds.
    var saveError: String? { get }
}

/// The one writer of `setup.json`.
///
/// A class, and locked, because the two facts it keeps — the standing load problem and the last
/// save error — are what decide whether the next write saves or replaces, and a daemon reads them
/// from the snapshot while a `configure` may be writing.
public final class SetupStore: SetupPersisting, @unchecked Sendable {
    /// The named steps a write goes through, in order. A replacement runs all five; a save skips
    /// the two that keep the original.
    public enum Step: String, Sendable, CaseIterable {
        case writeTemporary = "writing"
        case sync = "syncing"
        case removeBackup = "removing the old backup"
        case link = "keeping the original as"
        case rename = "renaming over"
    }

    /// What an unreadable file behaves as: agterm only, so no accessibility call is made (§7).
    public static let whileUnreadable = SetupState(scope: .agtermOnly, offerSeen: false)

    public let url: URL
    public var temporaryURL: URL { url.appendingPathExtension("tmp") }
    public var backupURL: URL { url.appendingPathExtension("unreadable") }

    private let fault: @Sendable (Step) -> Int32?
    private let lock = NSLock()
    private var standingProblem: SetupLoadProblem?
    private var lastSaveError: String?

    /// No default URL, for the reason `Daemon.Configuration.activeTargetFile` has none: the obvious
    /// one is the live daemon's choice, and a test that forgot the parameter would overwrite it.
    public convenience init(url: URL) {
        self.init(url: url, fault: { _ in nil })
    }

    /// The filesystem seam. `fault` is asked before each step; an `errno` it returns fails that
    /// step exactly as the system call would have, and `nil` lets the real call run. It exists
    /// because a failed `fsync` or `link(2)` cannot be produced on demand from a real disk.
    public init(url: URL, fault: @escaping @Sendable (Step) -> Int32?) {
        self.url = url
        self.fault = fault
    }

    /// The load problem `bootstrap` found, standing until a replacement succeeds.
    public var loadProblem: SetupLoadProblem? {
        lock.withLock { standingProblem }
    }

    /// The reason the last write failed, cleared by the next write that succeeds. Never replaces
    /// the load problem: a failed replacement leaves both.
    public var saveError: String? {
        lock.withLock { lastSaveError }
    }

    // MARK: - reading

    /// Reads and judges the file. Changes nothing, on disk or in the store.
    public func load() -> SetupLoad {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .absent
        } catch {
            let reason = (error as NSError).localizedFailureReason ?? "\(error)"
            return .unreadable(.unreadable(reason: "it cannot be read: \(reason)"))
        }
        switch SetupState.decode(data) {
        case let .success(state): return .loaded(state)
        case let .failure(problem): return .unreadable(problem)
        }
    }

    // MARK: - start-up

    /// Reads the file, or migrates when there is none, and records what it found. Only an absent
    /// file is ever written here: an unreadable one is reported and kept, and the flag is ignored
    /// whenever any file exists.
    public func bootstrap(flag: Bool, record: SetupMigration.RecordFact) -> SetupBootstrap {
        lock.withLock {
            switch load() {
            case let .loaded(state):
                standingProblem = nil
                return SetupBootstrap(state: state, source: .file, flagIgnored: flag,
                                      saveError: nil)
            case let .unreadable(problem):
                standingProblem = problem
                return SetupBootstrap(state: Self.whileUnreadable, source: .unreadable(problem),
                                      flagIgnored: flag, saveError: nil)
            case .absent:
                standingProblem = nil
                let state = SetupMigration.initial(flag: flag, record: record)
                do {
                    try save(state)
                    lastSaveError = nil
                } catch {
                    lastSaveError = "\(error)"
                }
                return SetupBootstrap(state: state, source: .migrated(flag: flag, record: record),
                                      flagIgnored: false, saveError: lastSaveError)
            }
        }
    }

    // MARK: - writing

    /// A person's choice, written the way `configure` writes it: through `replace` while a load
    /// problem stands — a retry after a failed replacement included — and through `save` otherwise.
    /// A failure is rethrown and kept as the save error; it never touches the load problem.
    public func write(_ state: SetupState) throws {
        try lock.withLock {
            do {
                if standingProblem != nil {
                    try replace(state)
                    standingProblem = nil
                } else {
                    try save(state)
                }
                lastSaveError = nil
            } catch {
                lastSaveError = "\(error)"
                throw error
            }
        }
    }

    /// Writes `state` to `setup.json.tmp` with mode 0600, syncs it, and renames it over
    /// `setup.json`. Every step's failure ends the write; the previous file is untouched.
    public func save(_ state: SetupState) throws {
        try writeSyncedTemporary(state)
        try finish()
    }

    /// Replaces an unreadable `setup.json` without a moment in which it is missing: the new state
    /// is written and synced, an older `setup.json.unreadable` is removed, `setup.json` is
    /// hard-linked to `setup.json.unreadable`, and only then is the temporary file renamed over it.
    public func replace(_ state: SetupState) throws {
        try writeSyncedTemporary(state)
        do {
            try step(.removeBackup, backupURL.path, tolerating: ENOENT) {
                unlink(backupURL.path)
            }
            // A file that has vanished since it was found unreadable has nothing left to keep.
            try step(.link, backupURL.path, tolerating: ENOENT) {
                Darwin.link(url.path, backupURL.path)
            }
        } catch {
            unlink(temporaryURL.path)
            throw error
        }
        try finish()
    }

    private func writeSyncedTemporary(_ state: SetupState) throws {
        let data = try state.encoded()
        let path = temporaryURL.path
        // Created when missing, never re-permissioned: a support directory somebody made read-only
        // must fail this write (§7, H42 (b)), not be quietly made writable again by it.
        try? Paths.createPrivateDirectory(url.deletingLastPathComponent(), repairingMode: false)
        var descriptor: Int32 = -1
        defer { if descriptor >= 0 { close(descriptor) } }
        do {
            try step(.writeTemporary, path) {
                descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
                guard descriptor >= 0 else { return -1 }
                // `open`'s mode applies only when it creates the file; a temporary file a crash
                // left behind keeps whatever mode it had.
                guard fchmod(descriptor, 0o600) == 0 else { return -1 }
                return Self.writeAll(data, to: descriptor)
            }
            try step(.sync, path) { fsync(descriptor) }
        } catch {
            unlink(path)
            throw error
        }
    }

    private func finish() throws {
        do {
            try step(.rename, url.path) { rename(temporaryURL.path, url.path) }
        } catch {
            unlink(temporaryURL.path)
            throw error
        }
    }

    /// Runs one named step: the fault seam first, then the system call, whose `-1` is read from
    /// `errno`.
    private func step(_ step: Step, _ path: String, tolerating tolerated: Int32? = nil,
                      _ call: () -> Int32) throws {
        if let code = fault(step) {
            throw SetupStoreError.failed(step: step, path: path, code: code)
        }
        guard call() == 0 else {
            let code = errno
            if code == tolerated { return }
            throw SetupStoreError.failed(step: step, path: path, code: code)
        }
    }

    /// `0`, or `-1` with `errno` set. A short write is retried from where it stopped.
    private static func writeAll(_ data: Data, to descriptor: Int32) -> Int32 {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Foundation.write(descriptor, buffer.baseAddress!.advanced(by: offset),
                                               buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                guard written > 0 else {
                    errno = ENOSPC
                    return -1
                }
                offset += written
            }
            return 0
        }
    }
}
