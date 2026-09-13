import DictaCore
import DictaRuntime
import Foundation
import Testing

/// The daemon's claim to be the one running (§7), against real lock files in a temporary directory.
///
/// Each contender opens the file for itself, as a second process would: `flock(2)` locks belong to
/// an open file description, so two `open`s in one process contend exactly as two daemons do.
@Suite("daemon lock")
struct DaemonLockTests {
    static func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dicta-lock-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("daemon.lock")
    }

    static func discard(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("a second contender is refused as already running while the first holds the lock")
    func aSecondContenderIsRefused() throws {
        let url = try Self.scratch()
        defer { Self.discard(url) }
        let owner = try DaemonLock.acquire(at: url)
        #expect(throws: DaemonLock.Failure.alreadyRunning(path: url.path)) {
            _ = try DaemonLock.acquire(at: url)
        }
        // Refused again, not merely once: the loser closed its own descriptor and took nothing.
        #expect(throws: DaemonLock.Failure.alreadyRunning(path: url.path)) {
            _ = try DaemonLock.acquire(at: url)
        }
        withExtendedLifetime(owner) {}
    }

    @Test("contenders starting together: exactly one takes the lock, every other is refused")
    func contendersStartingTogether() throws {
        let url = try Self.scratch()
        defer { Self.discard(url) }
        let contenders = 16
        let results = Results()
        let start = DispatchSemaphore(value: 0)
        let done = DispatchGroup()
        for _ in 0..<contenders {
            done.enter()
            Thread {
                start.wait()
                results.add(Result { try DaemonLock.acquire(at: url) })
                done.leave()
            }.start()
        }
        for _ in 0..<contenders { start.signal() }
        #expect(done.wait(timeout: .now() + 10) == .success)

        let all = results.all
        #expect(all.count == contenders)
        #expect(all.filter { (try? $0.get()) != nil }.count == 1)
        for case let .failure(error) in all {
            #expect(error as? DaemonLock.Failure == .alreadyRunning(path: url.path))
        }
    }

    @Test("once the owner lets go the next daemon takes it, and the file is never removed")
    func releasedLockIsTakenAgain() throws {
        let url = try Self.scratch()
        defer { Self.discard(url) }
        let owner = try DaemonLock.acquire(at: url)
        let inode = try Self.inode(url)
        owner.release()
        owner.release()
        #expect(FileManager.default.fileExists(atPath: url.path))

        let next = try DaemonLock.acquire(at: url)
        #expect(try Self.inode(url) == inode, "a second inode is a second lock two owners can hold")
        withExtendedLifetime(next) {}
    }

    @Test("a lock dropped without release, as a daemon that exits drops it, is taken again")
    func droppedLockIsTakenAgain() throws {
        let url = try Self.scratch()
        defer { Self.discard(url) }
        do {
            _ = try DaemonLock.acquire(at: url)
        }
        let next = try DaemonLock.acquire(at: url)
        withExtendedLifetime(next) {}
    }

    @Test("the lock's descriptor is closed on exec, so no child can keep it held")
    func closeOnExec() throws {
        let url = try Self.scratch()
        defer { Self.discard(url) }
        let owner = try DaemonLock.acquire(at: url)
        #expect(owner.isCloseOnExec)
        #expect(try Self.mode(url) == 0o600)
    }

    @Test("an existing lock file in a read-only directory is still taken")
    func readOnlyDirectoryWithALockFile() throws {
        let url = try Self.scratch()
        defer { Self.discard(url) }
        DaemonLock.acquireAndRelease(url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: url.deletingLastPathComponent().path)
        let owner = try DaemonLock.acquire(at: url)
        withExtendedLifetime(owner) {}
    }

    @Test("a lock that cannot be created is a failure of its own, never already running")
    func cannotOpenIsNotAlreadyRunning() throws {
        let url = try Self.scratch()
        defer { Self.discard(url) }
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: url.deletingLastPathComponent().path)
        #expect(throws: DaemonLock.Failure.cannotOpen(path: url.path, code: EACCES)) {
            _ = try DaemonLock.acquire(at: url)
        }
    }

    @Test("a lock file nobody may open, in a writable directory, is cannot-open, not a pass")
    func unopenableLockFileInAWritableDirectory() throws {
        // The directory would take a setup.json write, so nothing but the lock stops two starts
        // from both migrating: the failure has to be one start-up refuses on.
        let url = try Self.scratch()
        defer { Self.discard(url) }
        FileManager.default.createFile(atPath: url.path, contents: nil,
                                       attributes: [.posixPermissions: 0o000])
        #expect(throws: DaemonLock.Failure.cannotOpen(path: url.path, code: EACCES)) {
            _ = try DaemonLock.acquire(at: url)
        }
        #expect(throws: DaemonLock.Failure.cannotOpen(path: url.path, code: EACCES)) {
            _ = try DaemonLock.acquire(at: url)
        }
    }

    @Test("a flock that fails for another reason is cannot-lock, and releases its descriptor")
    func flockFailureIsCannotLock() throws {
        let url = try Self.scratch()
        defer { Self.discard(url) }
        #expect(throws: DaemonLock.Failure.cannotLock(path: url.path, code: ENOLCK)) {
            _ = try DaemonLock.acquire(at: url, flock: { _, _ in
                errno = ENOLCK
                return -1
            })
        }
        // Nothing of the failed attempt is left holding the file.
        let next = try DaemonLock.acquire(at: url)
        withExtendedLifetime(next) {}
    }

    @Test("start-up refuses on any lock failure before it builds, reads or writes anything")
    func startupTakesTheLockFirst() throws {
        // `main.swift` is not reachable behaviourally, so the policy is read from it; the compiler
        // holds the call site, because `bootstrap` cannot be called without a `DaemonLock`.
        // What must not precede the refusal: the store and its bootstrap, the focused-field switch
        // and the one frontmost source -- a loser that reached any of them would have left a trace
        // or built an adapter.
        let main = try BundleTests.text(at: "Sources/Dicta/main.swift")
        let acquire = try #require(
            main.range(of: "daemonLock = try DaemonLock.acquire(at: Paths.current.daemonLock)"))
        #expect(main.contains("let daemonLock: DaemonLock\n"), "the lock may be absent")
        // Exactly one catch, taking every failure, and it exits: no failure resumes start-up.
        let afterAcquire = main[acquire.upperBound...]
        let block = try #require(afterAcquire.range(of: "\n}\n"))
        let handler = afterAcquire[..<block.upperBound]
        #expect(handler.components(separatedBy: "catch").count == 2, "\(handler)")
        #expect(handler.contains("} catch {"))
        #expect(handler.contains("exit(EXIT_FAILURE)"))
        for later in ["SetupStore(", ".bootstrap(", "FocusedFieldSwitch(", "SystemFrontmost()",
                      "Daemon(", "HoldTrigger("] {
            let found = try #require(main.range(of: later), "\(later) is not in main.swift")
            #expect(block.upperBound < found.lowerBound, "\(later) comes before the refusal")
        }
        #expect(main.contains("owner: daemonLock)"))
        // The descriptor is never let go while the daemon runs.
        #expect(!main.contains("daemonLock.release()"))
    }

    // MARK: -

    final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Result<DaemonLock, any Error>] = []
        func add(_ result: Result<DaemonLock, any Error>) {
            lock.withLock { results.append(result) }
        }
        var all: [Result<DaemonLock, any Error>] { lock.withLock { results } }
    }

    static func inode(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.systemFileNumber] as? NSNumber).uint64Value
    }

    static func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue
    }
}

private extension DaemonLock {
    /// Leaves a lock file behind, as a daemon that ran once does.
    static func acquireAndRelease(_ url: URL) {
        (try? acquire(at: url))?.release()
    }
}
