import DictaCore
import Foundation
import Testing

/// Where dicta keeps its files. The tests run against a temporary home rather than the real
/// one, which is the whole reason `Paths` takes its home as a value instead of reading it globally.
@Suite("paths")
struct PathsTests {
    static func temporaryHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dicta-paths-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("everything lives under one Application Support directory named after the bundle id")
    func everythingIsUnderSupport() {
        let paths = Paths(home: URL(fileURLWithPath: "/Users/nobody"))
        #expect(paths.support.path ==
            "/Users/nobody/Library/Application Support/dev.personal.dicta")
        for file in [paths.socket, paths.record, paths.dictionary, paths.config, paths.setup] {
            #expect(file.deletingLastPathComponent().path == paths.support.path,
                    "\(file.lastPathComponent) is not in the support directory")
        }
    }

    @Test("the files have distinct, stable names")
    func fileNames() {
        let paths = Paths(home: URL(fileURLWithPath: "/Users/nobody"))
        #expect(paths.socket.lastPathComponent == "control.sock")
        #expect(paths.record.lastPathComponent == "record.jsonl")
        #expect(paths.dictionary.lastPathComponent == "replacements.conf")
        #expect(paths.config.lastPathComponent == "config.json")
        #expect(paths.setup.lastPathComponent == "setup.json")
        let names = [paths.socket, paths.record, paths.dictionary, paths.config, paths.setup]
            .map(\.lastPathComponent)
        #expect(Set(names).count == names.count)
    }

    @Test("the setup choice has a file of its own, not D9b's config.json")
    func setupIsNotConfig() {
        // config.json is reserved for the filter command of D9b. Sharing it would make the daemon a
        // second writer of a file a person edits by hand, and a filter edit could lose a choice.
        let paths = Paths(home: URL(fileURLWithPath: "/Users/nobody"))
        #expect(paths.setup.path
            == "/Users/nobody/Library/Application Support/dev.personal.dicta/setup.json")
        #expect(paths.setup != paths.config)
    }

    @Test("the socket path fits in sun_path")
    func socketFitsInSunPath() {
        // A Unix socket address is 104 bytes on Darwin, silently truncated past that — which would
        // make the daemon bind one path and the client connect to another.
        let real = Paths.current.socket.path
        #expect(real.utf8.count < 104, "\(real) is \(real.utf8.count) bytes")
    }

    @Test("the support directory is created on demand")
    func createdOnDemand() throws {
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        #expect(!FileManager.default.fileExists(atPath: paths.support.path))

        let created = try paths.createSupportDirectory()

        #expect(created == paths.support)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: paths.support.path,
                                               isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test("creating it twice is not an error")
    func creationIsIdempotent() throws {
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        _ = try paths.createSupportDirectory()
        _ = try paths.createSupportDirectory()
    }

    @Test("the support directory is private to this user")
    func directoryIsPrivate() throws {
        // The trust boundary is the filesystem and nothing else: there is no token on the socket,
        // because any process running as this user can already act as this user. That argument
        // only holds while the directory is 0700.
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        _ = try paths.createSupportDirectory()

        let attributes = try FileManager.default.attributesOfItem(atPath: paths.support.path)
        let mode = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(mode.int16Value == 0o700)
    }

    @Test("a directory that is already there has its mode repaired, not trusted")
    func anExistingDirectoryIsRepaired() throws {
        // `createDirectory` IGNORES `attributes` entirely when the directory already exists: it
        // succeeds, returns, and the mode it was handed is never applied. So the 0700 above held
        // only for a directory dicta itself created on a machine with a strict umask -- one
        // restored from a backup, left by an earlier build, or made under a loose umask kept
        // whatever it had, for ever, and the sentence about the socket carrying no token was a
        // comment rather than a fact.
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        _ = try paths.createSupportDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: paths.support.path)

        _ = try paths.createSupportDirectory()

        let attributes = try FileManager.default.attributesOfItem(atPath: paths.support.path)
        let mode = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(mode.int16Value == 0o700)
    }

    @Test("the default home is the current user's, and is not baked in at build time")
    func defaultHome() {
        #expect(Paths.current.home == FileManager.default.homeDirectoryForCurrentUser)
        #expect(Paths.bundleID == "dev.personal.dicta")
    }
}
