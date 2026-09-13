import DictaCore
import Foundation
import Testing

/// Where dictation goes, as the person chose it (D31 as amended on 2026-09-13): the value kept in
/// `setup.json`, how its bytes are judged, and what a daemon with no file decides.
///
/// All of it is pure, so the store (`SetupStore`) and start-up only ever do the I/O around a
/// decision these tests already hold (D19).
@Suite("setup state")
struct SetupStateTests {
    static let when = Date(timeIntervalSince1970: 1_789_000_000)

    static func entry(id: AttemptID, outcome: AttemptOutcome = .injected) -> RecordEntry {
        RecordEntry(id: id, at: when, outcome: outcome, mode: .clean,
                    target: Target(sessionID: "S1", pane: .left))
    }

    // MARK: - the migration, used only while setup.json does not exist

    @Test("the flag seeds other-apps with the offer seen, whatever the record holds",
          arguments: [SetupMigration.RecordFact.lines(0), .lines(1), .lines(250), .unreadable])
    func theFlagSeedsOtherApps(record: SetupMigration.RecordFact) {
        // A user already running with --focused-fields chose it once already; asking again, or
        // offering what they have, would be the update taking something away.
        #expect(SetupMigration.initial(flag: true, record: record)
            == SetupState(scope: .otherApps, offerSeen: true))
    }

    @Test("without the flag, a record with any line is an update: agterm only, offer not seen",
          arguments: [SetupMigration.RecordFact.lines(1), .lines(2), .lines(10_000)])
    func aRecordWithLinesIsAnUpdate(record: SetupMigration.RecordFact) {
        #expect(SetupMigration.initial(flag: false, record: record)
            == SetupState(scope: .agtermOnly, offerSeen: false))
    }

    @Test("without the flag, a record that cannot be read is an update too, never a fresh install")
    func anUnreadableRecordIsAnUpdate() {
        // Reading it as empty would treat somebody who has dictated for months as a stranger and
        // leave their agterm dictation waiting on a window.
        #expect(SetupMigration.initial(flag: false, record: .unreadable)
            == SetupState(scope: .agtermOnly, offerSeen: false))
    }

    @Test("without the flag, no lines or no record at all is a fresh install: undecided")
    func noLinesIsFresh() {
        // Having agterm installed is not taken as intent, so nothing here asks about agterm.
        #expect(SetupMigration.initial(flag: false, record: .lines(0))
            == SetupState(scope: .undecided, offerSeen: false))
    }

    @Test("a successful read with no entries is zero lines")
    func recordFactFromAnEmptyRead() {
        #expect(SetupMigration.recordFact(.success([])) == .lines(0))
    }

    @Test("one line is counted, and an aborted attempt is a line like any other")
    func recordFactCountsAnAbortedLine() {
        #expect(SetupMigration.recordFact(.success([Self.entry(id: 1, outcome: .aborted)]))
            == .lines(1))
        #expect(SetupMigration.recordFact(.success([Self.entry(id: 1)])) == .lines(1))
    }

    @Test("a successful read with many lines counts every one")
    func recordFactCountsManyLines() {
        let entries = (1...40).map { Self.entry(id: AttemptID($0), outcome: .empty) }
        #expect(SetupMigration.recordFact(.success(entries)) == .lines(40))
        #expect(SetupMigration.initial(flag: false, record: SetupMigration.recordFact(
            .success(entries))).scope == .agtermOnly)
    }

    @Test("a failed read is unreadable, not empty")
    func recordFactFromAFailedRead() {
        struct CannotRead: Error {}
        #expect(SetupMigration.recordFact(.failure(CannotRead())) == .unreadable)
    }

    // MARK: - the file's bytes

    @Test("the scopes keep their raw values, which are what setup.json and the wire carry")
    func rawValues() {
        #expect(SetupScope.undecided.rawValue == "undecided")
        #expect(SetupScope.agtermOnly.rawValue == "agterm-only")
        #expect(SetupScope.otherApps.rawValue == "other-apps")
        #expect(SetupScope.allCases.count == 3)
        #expect(SetupState.currentSchema == 1)
    }

    @Test("every state survives the round trip",
          arguments: SetupScope.allCases, [false, true])
    func roundTrip(scope: SetupScope, offerSeen: Bool) throws {
        let state = SetupState(scope: scope, offerSeen: offerSeen)
        #expect(try SetupState.decode(state.encoded()) == .success(state))
    }

    @Test("the encoding is the documented one: schema, scope and offerSeen")
    func encodingIsTheDocumentedOne() throws {
        let data = try SetupState(scope: .otherApps, offerSeen: true).encoded()
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["schema", "scope", "offerSeen"])
        #expect(object["schema"] as? Int == 1)
        #expect(object["scope"] as? String == "other-apps")
        #expect(object["offerSeen"] as? Bool == true)
    }

    @Test("the documented example reads as written")
    func theDocumentedExampleReads() {
        let data = Data(#"{"schema": 1, "scope": "other-apps", "offerSeen": true}"#.utf8)
        #expect(SetupState.decode(data) == .success(SetupState(scope: .otherApps, offerSeen: true)))
    }

    @Test("unknown keys are ignored on read")
    func unknownKeysAreIgnored() {
        let data = Data(#"{"schema":1,"scope":"agterm-only","offerSeen":false,"later":[1,2]}"#.utf8)
        #expect(SetupState.decode(data)
            == .success(SetupState(scope: .agtermOnly, offerSeen: false)))
    }

    @Test("invalid JSON is unreadable, never a default")
    func invalidJSONIsUnreadable() {
        for text in ["{", "", "not json", "[]", #"{"schema":1}"#,
                     #"{"schema":1,"scope":"other-apps"}"#,
                     #"{"schema":"1","scope":"other-apps","offerSeen":true}"#,
                     #"{"schema":1,"scope":"other-apps","offerSeen":"yes"}"#,
                     #"{"schema":0,"scope":"other-apps","offerSeen":true}"#] {
            guard case let .failure(.unreadable(reason)) = SetupState.decode(Data(text.utf8)) else {
                Issue.record("\(text) was not unreadable: \(SetupState.decode(Data(text.utf8)))")
                continue
            }
            #expect(!reason.isEmpty)
        }
    }

    @Test("an unknown scope is unreadable, naming the scope, and distinct from invalid JSON")
    func unknownScopeIsUnreadable() {
        let unknown = SetupState.decode(
            Data(#"{"schema":1,"scope":"everywhere","offerSeen":true}"#.utf8))
        let invalid = SetupState.decode(Data("{".utf8))
        guard case let .failure(.unreadable(reason)) = unknown else {
            Issue.record("an unknown scope was \(unknown)")
            return
        }
        #expect(reason.contains("everywhere"))
        #expect(unknown != invalid)
    }

    @Test("a schema newer than this build is its own problem, whatever else the file holds")
    func newerSchemaIsItsOwnProblem() {
        // Checked before the rest: a newer build may have added a scope or reshaped a key, and
        // calling that "invalid" would send the person to repair a file that is not broken.
        let newer = [#"{"schema":2,"scope":"other-apps","offerSeen":true}"#,
                     #"{"schema":7,"scope":"somewhere-new"}"#]
        #expect(SetupState.decode(Data(newer[0].utf8)) == .failure(.newerSchema(found: 2)))
        #expect(SetupState.decode(Data(newer[1].utf8)) == .failure(.newerSchema(found: 7)))
        let problems: [SetupLoadProblem] = [
            .newerSchema(found: 2),
            .unreadable(reason: "x"),
        ]
        #expect(problems[0] != problems[1])
    }

    @Test("a load problem says what is wrong, for the log and the window")
    func problemDescriptions() {
        #expect("\(SetupLoadProblem.newerSchema(found: 3))".contains("3"))
        #expect("\(SetupLoadProblem.unreadable(reason: "bad bytes"))".contains("bad bytes"))
    }

    @Test("a load problem survives the wire, where the snapshot will carry it")
    func problemRoundTrips() throws {
        for problem in [SetupLoadProblem.newerSchema(found: 4), .unreadable(reason: "why")] {
            let data = try JSONEncoder().encode(problem)
            #expect(try JSONDecoder().decode(SetupLoadProblem.self, from: data) == problem)
        }
    }
}
