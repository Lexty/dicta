import DictaCore
import DictaRuntime
import Foundation
import Testing

/// The one writer of `setup.json` (D31 as amended on 2026-09-13), driven against real files in a
/// temporary directory.
///
/// Real files rather than a fake filesystem, because what is worth catching is on disk: a byte-for-
/// byte original that must survive, a mode, a temporary file left behind. The steps a disk will not
/// fail on demand — `fsync`, `link(2)`, `rename(2)` — are failed through the store's fault seam,
/// which fails the named step exactly as the system call would and lets every other step run for
/// real.
@Suite("setup store")
struct SetupStoreTests {
    static func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dicta-setup-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("setup.json")
    }

    /// Removes the directory `scratch()` made for `url`.
    static func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    static func bytes(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    static func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// What each unreadable kind looks like on disk, and the problem it must load as.
    static let unreadableFiles: [(String, @Sendable (SetupLoadProblem) -> Bool)] = [
        ("{", { if case .unreadable = $0 { true } else { false } }),
        (#"{"schema":1,"scope":"everywhere","offerSeen":true}"#,
         { if case let .unreadable(reason) = $0 { reason.contains("everywhere") } else { false } }),
        (#"{"schema":2,"scope":"other-apps","offerSeen":true}"#, { $0 == .newerSchema(found: 2) }),
    ]

    /// Every step the store passed through, and an `errno` for the ones a test wants to fail.
    final class Steps: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [SetupStore.Step] = []
        private var failing: [SetupStore.Step: Int32] = [:]
        private var before: (@Sendable (SetupStore.Step) -> Void)?

        init(failing: [SetupStore.Step: Int32] = [:],
             before: (@Sendable (SetupStore.Step) -> Void)? = nil) {
            self.failing = failing
            self.before = before
        }

        var passed: [SetupStore.Step] { lock.withLock { seen } }

        func fail(_ step: SetupStore.Step?, code: Int32 = EIO) {
            lock.withLock { failing = step.map { [$0: code] } ?? [:] }
        }

        func store(_ url: URL) -> SetupStore {
            SetupStore(url: url) { step in
                let (code, before) = self.lock.withLock {
                    () -> (Int32?, (@Sendable (SetupStore.Step) -> Void)?) in
                    self.seen.append(step)
                    return (self.failing[step], self.before)
                }
                before?(step)
                return code
            }
        }
    }

    // MARK: - reading

    @Test("an absent setup.json loads as absent")
    func absentLoadsAsAbsent() throws {
        let url = try Self.scratch()
        defer { Self.discard(url) }
        #expect(SetupStore(url: url).load() == .absent)
        #expect(!Self.exists(url))
    }

    @Test("a valid setup.json loads as the state it holds")
    func validLoads() throws {
        let url = try Self.scratch()
        defer { Self.discard(url) }
        try Data(#"{"schema":1,"scope":"agterm-only","offerSeen":true}"#.utf8).write(to: url)
        #expect(SetupStore(url: url).load()
            == .loaded(SetupState(scope: .agtermOnly, offerSeen: true)))
    }

    @Test("each unreadable kind loads as its problem, and the file is byte-identical afterwards")
    func unreadableLoadsAsItsProblem() throws {
        for (text, matches) in Self.unreadableFiles {
            let url = try Self.scratch()
            defer { Self.discard(url) }
            try Data(text.utf8).write(to: url)
            let store = SetupStore(url: url)
            guard case let .unreadable(problem) = store.load() else {
                Issue.record("\(text) did not load as unreadable: \(store.load())")
                continue
            }
            #expect(matches(problem), "\(text) loaded as \(problem)")
            _ = store.bootstrap(flag: true, record: .lines(0))
            #expect(Self.bytes(url) == Data(text.utf8), "reading \(text) changed it")
            #expect(!Self.exists(store.temporaryURL))
            #expect(!Self.exists(store.backupURL))
        }
    }

    @Test("a setup.json that cannot be opened is unreadable, never absent")
    func unopenableIsUnreadable() throws {
        // A directory standing where the file should be: present, and not readable as a file.
        // Reading it as absent would re-migrate over somebody's choice.
        let url = try Self.scratch()
        defer { Self.discard(url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        guard case .unreadable(.unreadable) = SetupStore(url: url).load() else {
            Issue.record("a directory at setup.json loaded as \(SetupStore(url: url).load())")
            return
        }
    }

    @Test("a setup.json that is a symbolic link to nothing is unreadable, never migrated over")
    func danglingSymlinkIsUnreadable() throws {
        // `agent-seed.sh` counts it as present and drops the seed, so the daemon must not read it
        // as absent and migrate without one.
        let url = try Self.scratch()
        defer { Self.discard(url) }
        let nowhere = url.deletingLastPathComponent().appendingPathComponent("gone")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: nowhere)
        let steps = Steps()
        let store = steps.store(url)
        guard case .unreadable(.unreadable) = store.load() else {
            Issue.record("a dangling symlink at setup.json loaded as \(store.load())")
            return
        }
        let bootstrap = store.bootstrap(flag: true, record: .lines(0))
        #expect(steps.passed.isEmpty)
        #expect(bootstrap.state == SetupStore.whileUnreadable)
        #expect(bootstrap.flagIgnored)

        // Choosing again replaces it; a link to nothing has no original to keep.
        let chosen = SetupState(scope: .otherApps, offerSeen: true)
        try store.write(chosen)
        #expect(store.load() == .loaded(chosen))
        #expect(store.loadProblem == nil)
        #expect(!Self.exists(store.backupURL))
    }

    // MARK: - saving

    @Test("a save writes setup.json.tmp at 0600, syncs it, and renames it over setup.json")
    func saveGoesThroughTheTemporaryFile() throws {
        let url = try Self.scratch()
        defer { Self.discard(url) }
        let state = SetupState(scope: .otherApps, offerSeen: true)
        let temporary = url.appendingPathExtension("tmp")
        let seenAtRename = Steps(before: { step in
            guard step == .rename else { return }
            // Immediately before the rename, the new bytes are in the temporary file, already
            // private, and setup.json does not hold them yet.
            #expect(Self.bytes(temporary) == (try? state.encoded()))
            #expect((try? Self.mode(temporary)) == 0o600)
            #expect(!Self.exists(url))
        })
        let store = seenAtRename.store(url)
        try store.save(state)
        #expect(seenAtRename.passed == [.writeTemporary, .sync, .rename])
        #expect(store.load() == .loaded(state))
        #expect(try Self.mode(url) == 0o600)
        #expect(!Self.exists(store.temporaryURL))
    }

    @Test("a save ends at 0600 even over a looser file and a temporary file a crash left behind")
    func saveTightensTheMode() throws {
        let url = try Self.scratch()
        defer { Self.discard(url) }
        let store = SetupStore(url: url)
        try Data("old".utf8).write(to: url)
        try Data("torn".utf8).write(to: store.temporaryURL)
        for file in [url, store.temporaryURL] {
            try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                  ofItemAtPath: file.path)
        }
        try store.save(SetupState(scope: .agtermOnly, offerSeen: true))
        #expect(try Self.mode(url) == 0o600)
        #expect(store.load() == .loaded(SetupState(scope: .agtermOnly, offerSeen: true)))
    }

    @Test("a save into a read-only directory throws with a reason, and the previous file stays")
    func saveIntoReadOnlyDirectoryThrows() throws {
        let url = try Self.scratch()
        defer { Self.discard(url) }
        let directory = url.deletingLastPathComponent()
        let previous = try SetupState(scope: .agtermOnly, offerSeen: false).encoded()
        try previous.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: directory.path)
        }
        let store = SetupStore(url: url)
        do {
            try store.save(SetupState(scope: .otherApps, offerSeen: true))
            Issue.record("a save into a read-only directory succeeded")
        } catch let error as SetupStoreError {
            #expect(error == .failed(step: .writeTemporary, path: store.temporaryURL.path,
                                     code: EACCES))
            #expect("\(error)".contains("setup.json"))
            #expect("\(error)".contains("Permission denied"))
        }
        #expect(Self.bytes(url) == previous)
        #expect(!Self.exists(store.temporaryURL))
    }

    @Test("a failure at any step of a save throws and leaves the previous file intact",
          arguments: [SetupStore.Step.writeTemporary, .sync, .rename])
    func saveFailingAtAStep(step: SetupStore.Step) throws {
        let url = try Self.scratch()
        defer { Self.discard(url) }
        let previous = try SetupState(scope: .agtermOnly, offerSeen: false).encoded()
        try previous.write(to: url)
        let steps = Steps(failing: [step: EIO])
        let store = steps.store(url)
        #expect(throws: SetupStoreError.self) {
            try store.save(SetupState(scope: .otherApps, offerSeen: true))
        }
        #expect(steps.passed.last == step, "the write went on past a failed \(step)")
        #expect(Self.bytes(url) == previous)
        #expect(!Self.exists(store.temporaryURL))
    }

    // MARK: - replacing an unreadable file

    @Test("a replacement keeps the unreadable original as setup.json.unreadable, then writes")
    func replaceKeepsTheOriginal() throws {
        let url = try Self.scratch()
        defer { Self.discard(url) }
        let original = Data("{".utf8)
        try original.write(to: url)
        let steps = Steps()
        let store = steps.store(url)
        let state = SetupState(scope: .otherApps, offerSeen: true)
        try store.replace(state)
        #expect(steps.passed == [.writeTemporary, .sync, .removeBackup, .link, .rename])
        #expect(Self.bytes(store.backupURL) == original)
        #expect(store.load() == .loaded(state))
        #expect(try Self.mode(url) == 0o600)
        #expect(!Self.exists(store.temporaryURL))
    }

    @Test("a replacement removes an older setup.json.unreadable rather than keeping two originals")
    func replaceReplacesAnOlderBackup() throws {
        let url = try Self.scratch()
        defer { Self.discard(url) }
        let store = SetupStore(url: url)
        try Data("older".utf8).write(to: store.backupURL)
        try Data("{\"schema\":".utf8).write(to: url)
        try store.replace(SetupState(scope: .agtermOnly, offerSeen: true))
        #expect(Self.bytes(store.backupURL) == Data("{\"schema\":".utf8))
        #expect(store.load() == .loaded(SetupState(scope: .agtermOnly, offerSeen: true)))
    }

    @Test("a replacement never has a moment without setup.json")
    func replaceNeverRemovesTheAuthoritativePath() throws {
        let url = try Self.scratch()
        defer { Self.discard(url) }
        try Data("{".utf8).write(to: url)
        let watched = Steps(before: { step in
            #expect(Self.exists(url), "setup.json was missing before \(step)")
        })
        try watched.store(url).replace(SetupState(scope: .otherApps, offerSeen: true))
        #expect(Self.exists(url))
    }

    @Test("a failed replacement step leaves setup.json byte-identical, and never migrates",
          arguments: SetupStore.Step.allCases)
    func replaceFailingAtAStep(step: SetupStore.Step) throws {
        let url = try Self.scratch()
        defer { Self.discard(url) }
        let original = Data("{".utf8)
        try original.write(to: url)
        let steps = Steps(failing: [step: EIO])
        let store = steps.store(url)
        do {
            try store.replace(SetupState(scope: .otherApps, offerSeen: true))
            Issue.record("a replacement failing at \(step) succeeded")
        } catch let error as SetupStoreError {
            guard case .failed(step, _, EIO) = error else {
                Issue.record("failing at \(step) threw \(error)")
                return
            }
        }
        #expect(steps.passed.last == step, "the replacement went on past a failed \(step)")
        #expect(Self.bytes(url) == original)
        #expect(!Self.exists(store.temporaryURL))

        // A restart after the failure, with a legacy --focused-fields still in the agent: the file
        // is still unreadable, behaves as agterm only, and nothing re-migrates over it.
        let restarted = SetupStore(url: url)
        let bootstrap = restarted.bootstrap(flag: true, record: .lines(0))
        #expect(bootstrap.state == SetupState(scope: .agtermOnly, offerSeen: false))
        guard case .unreadable = bootstrap.source else {
            Issue.record("after a failed \(step), bootstrap was \(bootstrap.source)")
            return
        }
        #expect(restarted.loadProblem != nil)
        #expect(Self.bytes(url) == original)
    }

    // MARK: - start-up

    @Test("with no setup.json, bootstrap writes each migration row",
          arguments: [(true, SetupMigration.RecordFact.lines(0)), (true, .unreadable),
                      (false, .lines(3)), (false, .unreadable), (false, .lines(0))])
    func bootstrapWritesTheMigration(flag: Bool, record: SetupMigration.RecordFact) throws {
        let url = try Self.scratch()
        defer { Self.discard(url) }
        let store = SetupStore(url: url)
        let bootstrap = store.bootstrap(flag: flag, record: record)
        let expected = SetupMigration.initial(flag: flag, record: record)
        #expect(bootstrap == SetupBootstrap(state: expected,
                                            source: .migrated(flag: flag, record: record),
                                            flagIgnored: false, saveError: nil))
        #expect(store.load() == .loaded(expected))
        #expect(store.loadProblem == nil)
        #expect(store.saveError == nil)
    }

    @Test("an existing setup.json decides, and bootstrap says the flag was ignored")
    func bootstrapIgnoresTheFlagOverAFile() throws {
        let url = try Self.scratch()
        defer { Self.discard(url) }
        let chosen = SetupState(scope: .agtermOnly, offerSeen: true)
        try chosen.encoded().write(to: url)
        let before = Self.bytes(url)
        let withFlag = SetupStore(url: url).bootstrap(flag: true, record: .lines(0))
        #expect(withFlag == SetupBootstrap(state: chosen, source: .file, flagIgnored: true,
                                           saveError: nil))
        let withoutFlag = SetupStore(url: url).bootstrap(flag: false, record: .lines(0))
        #expect(withoutFlag.flagIgnored == false)
        #expect(withoutFlag.state == chosen)
        #expect(Self.bytes(url) == before)
    }

    @Test("an unreadable setup.json at start-up writes nothing and reports the problem")
    func bootstrapOverUnreadableWritesNothing() throws {
        for (text, matches) in Self.unreadableFiles {
            let url = try Self.scratch()
            defer { Self.discard(url) }
            try Data(text.utf8).write(to: url)
            let steps = Steps()
            let store = steps.store(url)
            let bootstrap = store.bootstrap(flag: false, record: .lines(0))
            #expect(steps.passed.isEmpty, "bootstrap over \(text) wrote: \(steps.passed)")
            #expect(bootstrap.state == SetupStore.whileUnreadable)
            #expect(bootstrap.state.scope == .agtermOnly)
            guard case let .unreadable(problem) = bootstrap.source else {
                Issue.record("bootstrap over \(text) was \(bootstrap.source)")
                continue
            }
            #expect(matches(problem))
            #expect(store.loadProblem == problem)
            #expect(bootstrap.saveError == nil)
            #expect(Self.bytes(url) == Data(text.utf8))
            #expect(!Self.exists(store.backupURL))
        }
    }

    @Test("a failed first save is a save error, and the migrated state still applies")
    func bootstrapWithAFailedFirstSave() throws {
        let url = try Self.scratch()
        defer { Self.discard(url) }
        let steps = Steps(failing: [.sync: EIO])
        let store = steps.store(url)
        let bootstrap = store.bootstrap(flag: true, record: .lines(0))
        #expect(bootstrap.state == SetupState(scope: .otherApps, offerSeen: true))
        #expect(bootstrap.source == .migrated(flag: true, record: .lines(0)))
        let reason = try #require(bootstrap.saveError)
        #expect(reason.contains("syncing"))
        #expect(store.saveError == reason)
        #expect(store.loadProblem == nil)
        #expect(store.load() == .absent)
    }

    // MARK: - the configure-style write

    @Test("an unreadable setup.json removed by hand before the choice is replaced still saves")
    func aReplacementOfAVanishedFileSaves() throws {
        let url = try Self.scratch()
        defer { Self.discard(url) }
        try Data("{".utf8).write(to: url)
        let steps = Steps()
        let store = steps.store(url)
        _ = store.bootstrap(flag: false, record: .lines(0))
        #expect(store.loadProblem != nil)
        try FileManager.default.removeItem(at: url)

        let chosen = SetupState(scope: .agtermOnly, offerSeen: true)
        try store.write(chosen)
        #expect(steps.passed.contains(.link), "the write did not replace")
        #expect(!Self.exists(store.backupURL))
        #expect(store.load() == .loaded(chosen))
        #expect(store.loadProblem == nil)
        #expect(store.saveError == nil)
    }

    @Test("after a failed replacement the problem stands, and the next write replaces again")
    func aFailedReplacementIsRetriedAsAReplacement() throws {
        let url = try Self.scratch()
        defer { Self.discard(url) }
        let original = Data("{".utf8)
        try original.write(to: url)
        let steps = Steps(failing: [.link: EACCES])
        let store = steps.store(url)
        _ = store.bootstrap(flag: false, record: .lines(0))
        let problem = try #require(store.loadProblem)

        #expect(throws: SetupStoreError.self) {
            try store.write(SetupState(scope: .otherApps, offerSeen: true))
        }
        #expect(store.loadProblem == problem)
        let reason = try #require(store.saveError)
        #expect(reason.contains("setup.json.unreadable"))
        #expect(Self.bytes(url) == original)

        steps.fail(nil)
        let chosen = SetupState(scope: .agtermOnly, offerSeen: true)
        try store.write(chosen)
        #expect(steps.passed.filter { $0 == .link }.count == 2, "the retry did not replace")
        #expect(Self.bytes(store.backupURL) == original)
        #expect(store.load() == .loaded(chosen))
        #expect(store.loadProblem == nil)
        #expect(store.saveError == nil)
    }

    @Test("with no load problem a write saves, and a success clears the last save error")
    func aWriteWithoutAProblemSaves() throws {
        let url = try Self.scratch()
        defer { Self.discard(url) }
        let steps = Steps(failing: [.rename: ENOSPC])
        let store = steps.store(url)
        _ = store.bootstrap(flag: false, record: .lines(0))
        #expect(store.saveError != nil)

        #expect(throws: SetupStoreError.self) {
            try store.write(SetupState(scope: .otherApps, offerSeen: true))
        }
        #expect(store.loadProblem == nil)
        #expect(store.saveError?.contains("No space left on device") == true)

        steps.fail(nil)
        let chosen = SetupState(scope: .otherApps, offerSeen: true)
        try store.write(chosen)
        #expect(!steps.passed.contains(.link))
        #expect(!Self.exists(store.backupURL))
        #expect(store.load() == .loaded(chosen))
        #expect(store.saveError == nil)
    }
}
