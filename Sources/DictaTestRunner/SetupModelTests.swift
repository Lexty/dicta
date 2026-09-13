import DictaCore
import Foundation
import Testing

/// Every decision the setup window makes, asserted as values (D27, D31, D19).
///
/// The window itself is SwiftUI in an executable target the runner cannot import, so what it may
/// decide is exactly what is tested here: when it opens by itself, which screen a state gets, what
/// each button, a close and becoming key send, and what the checklist says.
@Suite("setup model")
struct SetupModelTests {
    static let unreadable = SetupLoadProblem.unreadable(reason: "invalid JSON")
    static let newer = SetupLoadProblem.newerSchema(found: 2)
    static let writeFailed = "setup.json could not be saved: renaming over it failed"

    static func snapshot(
        _ scope: SetupScope, offerSeen: Bool = false, loadProblem: SetupLoadProblem? = nil,
        saveError: String? = nil, state: LifecycleState = .idle, terminal: Bool? = true,
        faculties: Faculties? = nil, hold: HoldSnapshot? = .armed(keys: ["the right Control key"])
    ) -> StatusSnapshot {
        StatusSnapshot(
            state: state,
            setup: SetupSnapshot(scope: scope, offerSeen: offerSeen, loadProblem: loadProblem,
                                 saveError: saveError),
            faculties: faculties ?? Faculties(microphone: true, models: true, terminal: terminal,
                                              scope: loadProblem == nil ? scope : .agtermOnly,
                                              accessibility: scope == .otherApps ? true : nil),
            hold: hold)
    }

    static func model(_ snapshot: StatusSnapshot?, first: Bool = false,
                      requested: Bool = false) -> SetupModel {
        SetupModel(snapshot: snapshot, firstSnapshotOfThisLaunch: first,
                   accessibilityRequested: requested)
    }

    static let configureOtherApps = Request(cmd: .configure, scope: .otherApps, offerSeen: true)
    static let configureAgtermOnly = Request(cmd: .configure, scope: .agtermOnly, offerSeen: true)
    static let configureOfferSeen = Request(cmd: .configure, offerSeen: true)
    static let check = Request(cmd: .accessibility, prompt: false)
    static let prompt = Request(cmd: .accessibility, prompt: true)

    // MARK: - the latch

    @Test("the latch is true once, on the first snapshot, even when that snapshot is busy")
    func theLatchFiresOnceEvenWhenBusy() {
        var latch = FirstSnapshotLatch()
        // An `.end` frame or an update with nothing in it is not a snapshot, and consumes nothing.
        #expect(latch.observe(nil) == false)
        #expect(latch.observe(StatusSnapshot(state: .recording)) == true)
        #expect(latch.observe(StatusSnapshot(state: .idle)) == false)
    }

    @Test("the latch never fires again, across a reconnect and a window close")
    func theLatchNeverResets() {
        var latch = FirstSnapshotLatch()
        #expect(latch.observe(Self.snapshot(.undecided)) == true)
        // The link drops (an `.end`, then nothing), the daemon comes back and sends its first
        // snapshot on the new stream; the window is closed in between. None of it is a new launch.
        #expect(latch.observe(nil) == false)
        #expect(latch.observe(Self.snapshot(.undecided)) == false)
        #expect(latch.observe(Self.snapshot(.undecided)) == false)
    }

    // MARK: - opening by itself

    @Test("no snapshot never opens the window")
    func noSnapshotNeverOpens() {
        #expect(Self.model(nil, first: true).shouldAutoOpen == false)
        #expect(Self.model(StatusSnapshot(state: .idle), first: true).shouldAutoOpen == false)
    }

    @Test("a snapshot that is not the launch's first never opens the window")
    func onlyTheFirstSnapshotOpens() {
        #expect(Self.model(Self.snapshot(.undecided), first: true).shouldAutoOpen == true)
        #expect(Self.model(Self.snapshot(.undecided), first: false).shouldAutoOpen == false)
    }

    @Test("a busy first snapshot forfeits the automatic open",
          arguments: [LifecycleState.warming, .recording, .processing, .injecting])
    func aBusyFirstSnapshotForfeits(state: LifecycleState) {
        #expect(Self.model(Self.snapshot(.undecided, state: state), first: true).shouldAutoOpen
            == false)
    }

    /// One pending-or-not case, with what `shouldAutoOpen` answers on an idle first snapshot.
    struct OpenCase: CustomTestStringConvertible, Sendable {
        var scope: SetupScope
        var offerSeen: Bool
        var loadProblem: SetupLoadProblem?
        var opens: Bool

        var testDescription: String {
            "\(scope.rawValue), offer \(offerSeen ? "seen" : "not seen")"
                + (loadProblem.map { ", \($0)" } ?? "")
        }
    }

    static let openCases: [OpenCase] = [
        OpenCase(scope: .undecided, offerSeen: false, opens: true),
        OpenCase(scope: .undecided, offerSeen: true, opens: true),
        OpenCase(scope: .agtermOnly, offerSeen: false, opens: true),
        OpenCase(scope: .agtermOnly, offerSeen: true, opens: false),
        OpenCase(scope: .otherApps, offerSeen: false, opens: false),
        OpenCase(scope: .otherApps, offerSeen: true, opens: false),
        OpenCase(scope: .agtermOnly, offerSeen: true, loadProblem: unreadable, opens: true),
        OpenCase(scope: .agtermOnly, offerSeen: false, loadProblem: unreadable, opens: true),
        OpenCase(scope: .agtermOnly, offerSeen: true, loadProblem: newer, opens: true),
    ]

    @Test("an idle first snapshot opens the window only for a choice, the offer or a problem",
          arguments: openCases)
    func autoOpenFollowsWhatIsPending(_ open: OpenCase) {
        let snapshot = Self.snapshot(open.scope, offerSeen: open.offerSeen,
                                     loadProblem: open.loadProblem)
        #expect(Self.model(snapshot, first: true).shouldAutoOpen == open.opens)
    }

    @Test("a save error neither opens the window alone nor suppresses an open otherwise due",
          arguments: openCases)
    func aSaveErrorChangesNoAutoOpen(_ open: OpenCase) {
        // A failed first bootstrap save still opens the first-run screen, and a failed write over
        // a settled choice is no reason to take focus.
        let snapshot = Self.snapshot(open.scope, offerSeen: open.offerSeen,
                                     loadProblem: open.loadProblem, saveError: Self.writeFailed)
        #expect(Self.model(snapshot, first: true).shouldAutoOpen == open.opens)
    }

    // MARK: - the screen for each state

    @Test("a load problem is the problem screen, whatever the save error says")
    func aLoadProblemIsTheProblemScreen() {
        for problem in [Self.unreadable, Self.newer] {
            for saveError in [nil, Self.writeFailed] {
                let found = Self.model(Self.snapshot(.agtermOnly, offerSeen: true,
                                                     loadProblem: problem, saveError: saveError))
                #expect(found.screen == .problem(problem, showsAgtermOnly: true))
                let missing = Self.model(Self.snapshot(.agtermOnly, loadProblem: problem,
                                                       saveError: saveError, terminal: false))
                #expect(missing.screen == .problem(problem, showsAgtermOnly: false))
            }
        }
    }

    @Test("undecided is the fresh screen, offering agterm only when agterm was found")
    func undecidedIsFresh() {
        #expect(Self.model(Self.snapshot(.undecided)).screen == .fresh(showsAgtermOnly: true))
        #expect(Self.model(Self.snapshot(.undecided, terminal: false)).screen
            == .fresh(showsAgtermOnly: false))
        // Not yet looked for is not found.
        #expect(Self.model(Self.snapshot(.undecided, terminal: nil)).screen
            == .fresh(showsAgtermOnly: false))
    }

    @Test("agterm only is the one-time offer until it is seen, then an ordinary enable screen")
    func agtermOnlyIsTheOffer() {
        let first = Self.model(Self.snapshot(.agtermOnly, offerSeen: false))
        #expect(first.screen == .offer(firstTime: true))
        #expect(first.heading == "Dicta can now type into other apps")
        let later = Self.model(Self.snapshot(.agtermOnly, offerSeen: true))
        #expect(later.screen == .offer(firstTime: false))
        #expect(!later.heading.contains("now"))
    }

    @Test("other apps is the checklist, with a way back to agterm only")
    func otherAppsIsTheChecklist() {
        let model = Self.model(Self.snapshot(.otherApps, offerSeen: true))
        guard case .checklist = model.screen else {
            Issue.record("other-apps drew \(model.screen)")
            return
        }
        #expect(model.controls == [.useOnlyWithAgterm])
    }

    @Test("no snapshot, or one without setup, is unavailable and sends nothing")
    func noSetupIsUnavailable() {
        for model in [Self.model(nil), Self.model(StatusSnapshot(state: .idle))] {
            #expect(model.screen == .unavailable)
            #expect(model.controls.isEmpty)
            #expect(model.effectOfClosing.isNothing)
            #expect(model.effectOfBecomingKey.isNothing)
            for control in SetupControl.allCases {
                #expect(model.effect(of: control).isNothing, "\(control)")
            }
        }
    }

    // MARK: - what each button sends

    @Test("fresh: Set up dictation chooses other apps, Use only with agterm chooses agterm only")
    func freshPayloads() {
        let model = Self.model(Self.snapshot(.undecided))
        #expect(model.controls == [.setUpDictation, .useOnlyWithAgterm])
        #expect(model.effect(of: .setUpDictation) == SetupEffect(request: Self.configureOtherApps))
        #expect(model.effect(of: .useOnlyWithAgterm)
            == SetupEffect(request: Self.configureAgtermOnly))
        // Closed without a choice: nothing is recorded, and it asks again next launch.
        #expect(model.effectOfClosing.isNothing)
    }

    @Test("fresh without agterm draws no agterm-only link, and a stale click on it sends nothing")
    func freshWithoutAgtermHasNoAgtermLink() {
        let model = Self.model(Self.snapshot(.undecided, terminal: false))
        #expect(model.controls == [.setUpDictation])
        #expect(model.effect(of: .useOnlyWithAgterm).isNothing)
    }

    @Test("the first-time offer: Enable chooses other apps, Keep and close record the offer seen")
    func firstOfferPayloads() {
        let model = Self.model(Self.snapshot(.agtermOnly, offerSeen: false))
        #expect(model.controls == [.enable, .keepAgtermOnly])
        #expect(model.effect(of: .enable) == SetupEffect(request: Self.configureOtherApps))
        #expect(model.effect(of: .keepAgtermOnly) == SetupEffect(request: Self.configureOfferSeen))
        #expect(model.effectOfClosing == SetupEffect(request: Self.configureOfferSeen))
    }

    @Test("the later offer: Enable chooses other apps, and closing sends nothing")
    func laterOfferPayloads() {
        let model = Self.model(Self.snapshot(.agtermOnly, offerSeen: true))
        #expect(model.controls == [.enable])
        #expect(model.effect(of: .enable) == SetupEffect(request: Self.configureOtherApps))
        #expect(model.effect(of: .keepAgtermOnly).isNothing)
        #expect(model.effectOfClosing.isNothing)
    }

    @Test("the problem screen sends what the fresh screen sends")
    func problemPayloads() {
        let model = Self.model(Self.snapshot(.agtermOnly, offerSeen: false,
                                             loadProblem: Self.unreadable))
        #expect(model.controls == [.setUpDictation, .useOnlyWithAgterm])
        #expect(model.effect(of: .setUpDictation) == SetupEffect(request: Self.configureOtherApps))
        #expect(model.effect(of: .useOnlyWithAgterm)
            == SetupEffect(request: Self.configureAgtermOnly))
        // Not the offer, though the scope in force is agterm only with the offer unseen.
        #expect(model.effect(of: .keepAgtermOnly).isNothing)
        #expect(model.effectOfClosing.isNothing)
    }

    @Test("the checklist: Allow Access prompts, the settings pane checks, agterm only goes back")
    func checklistPayloads() {
        let missing = Faculties(microphone: true, models: true, terminal: true, scope: .otherApps,
                                accessibility: false)
        let model = Self.model(Self.snapshot(.otherApps, offerSeen: true, faculties: missing))
        #expect(model.effect(of: .allowAccess) == SetupEffect(request: Self.prompt))
        #expect(model.effect(of: .useOnlyWithAgterm)
            == SetupEffect(request: Self.configureAgtermOnly))
        #expect(model.effectOfClosing.isNothing)

        let requested = Self.model(Self.snapshot(.otherApps, offerSeen: true, faculties: missing),
                                   requested: true)
        #expect(requested.effect(of: .openAccessibilitySettings)
            == SetupEffect(request: Self.check, url: SetupModel.accessibilitySettings))
        #expect(SetupModel.accessibilitySettings.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        // Once asked, the prompting button is gone, so a stale click on it cannot prompt again.
        #expect(requested.effect(of: .allowAccess).isNothing)
    }

    @Test("a control this screen does not draw sends nothing")
    func undrawnControlsSendNothing() {
        let snapshots = [Self.snapshot(.undecided), Self.snapshot(.agtermOnly),
                         Self.snapshot(.agtermOnly, offerSeen: true),
                         Self.snapshot(.agtermOnly, loadProblem: Self.newer),
                         Self.snapshot(.otherApps, offerSeen: true)]
        for snapshot in snapshots {
            let model = Self.model(snapshot)
            var drawn = Set(model.controls)
            if case let .checklist(rows) = model.screen {
                drawn.formUnion(rows.compactMap(\.control))
            }
            for control in SetupControl.allCases where !drawn.contains(control) {
                #expect(model.effect(of: control).isNothing, "\(control) on \(model.screen)")
            }
        }
    }

    @Test("becoming key checks the grant only under other apps, and never prompts")
    func becomingKeyChecksOnlyUnderOtherApps() {
        for scope in SetupScope.allCases {
            let model = Self.model(Self.snapshot(scope, offerSeen: true))
            #expect(model.effectOfBecomingKey
                == (scope == .otherApps ? SetupEffect(request: Self.check) : .nothing),
                "\(scope)")
        }
        // A load problem is agterm only in force: nobody may look at the grant.
        #expect(Self.model(Self.snapshot(.agtermOnly, loadProblem: Self.unreadable))
            .effectOfBecomingKey.isNothing)
    }

    @Test("becoming key right after Allow Access was clicked still never prompts")
    func becomingKeyAfterAllowAccessNeverPrompts() {
        // The system dialog hands focus back to the window: that is a check, not a second dialog.
        let missing = Faculties(microphone: true, models: true, terminal: true, scope: .otherApps,
                                accessibility: false)
        for requested in [false, true] {
            let model = Self.model(Self.snapshot(.otherApps, offerSeen: true, faculties: missing),
                                   requested: requested)
            #expect(model.effectOfBecomingKey == SetupEffect(request: Self.check))
            #expect(model.effectOfBecomingKey.request?.prompt == false)
        }
    }

    // MARK: - the checklist rows

    static func rows(_ faculties: Faculties, hold: HoldSnapshot? = nil,
                     requested: Bool = false) -> [ChecklistRow] {
        let model = Self.model(Self.snapshot(.otherApps, offerSeen: true, faculties: faculties,
                                             hold: hold),
                               requested: requested)
        guard case let .checklist(rows) = model.screen else { return [] }
        return rows
    }

    static func row(_ item: ChecklistRow.Item, in rows: [ChecklistRow]) -> ChecklistRow? {
        rows.first { $0.item == item }
    }

    @Test("the accessibility row offers Allow Access, then the settings pane once asked, then done")
    func accessibilityRow() throws {
        for granted in [nil, false] as [Bool?] {
            let faculties = Faculties(microphone: true, models: true, terminal: true,
                                      scope: .otherApps, accessibility: granted)
            let before = try #require(Self.row(.accessibility, in: Self.rows(faculties)))
            #expect(before.status == .needed)
            #expect(before.control == .allowAccess)
            #expect(before.detail
                == "Lets Dicta type the words it heard into the app you are using.")
            let after = try #require(Self.row(.accessibility,
                                              in: Self.rows(faculties, requested: true)))
            #expect(after.status == .needed)
            #expect(after.control == .openAccessibilitySettings)
        }
        let granted = Faculties(microphone: true, models: true, terminal: true, scope: .otherApps,
                                accessibility: true)
        let done = try #require(Self.row(.accessibility, in: Self.rows(granted, requested: true)))
        #expect(done.status == .done)
        #expect(done.control == nil)
    }

    @Test("the models row: loaded is done, missing offers the fetch, unknown waits")
    func modelsRow() throws {
        let cases: [(Bool?, ChecklistRow.Status, SetupControl?)] = [
            (true, .done, nil), (false, .needed, .fetchModels), (nil, .waiting, nil),
        ]
        for (models, status, control) in cases {
            let faculties = Faculties(microphone: true, models: models, terminal: true,
                                      scope: .otherApps, accessibility: true)
            let row = try #require(Self.row(.models, in: Self.rows(faculties)))
            #expect(row.status == status)
            #expect(row.control == control)
        }
        let missing = Faculties(microphone: true, models: false, terminal: true, scope: .otherApps,
                                accessibility: true)
        let model = Self.model(Self.snapshot(.otherApps, offerSeen: true, faculties: missing))
        #expect(model.effect(of: .fetchModels) == SetupEffect(action: .fetchModels))
    }

    @Test("the microphone row: denied opens settings, unknown waits for the start-up request")
    func microphoneRow() throws {
        let denied = Faculties(microphone: false, models: true, terminal: true, scope: .otherApps,
                               accessibility: true)
        let deniedRow = try #require(Self.row(.microphone, in: Self.rows(denied)))
        #expect(deniedRow.status == .needed)
        #expect(deniedRow.control == .openMicrophoneSettings)
        #expect(Self.model(Self.snapshot(.otherApps, offerSeen: true, faculties: denied))
            .effect(of: .openMicrophoneSettings) == SetupEffect(action: .openMicrophoneSettings))

        let unknown = Faculties(microphone: nil, models: true, terminal: true, scope: .otherApps,
                                accessibility: true)
        let waiting = try #require(Self.row(.microphone, in: Self.rows(unknown)))
        #expect(waiting.status == .waiting)
        // The request is the daemon's, made at start-up; the window has nothing to offer for it.
        #expect(waiting.control == nil)
        #expect(waiting.detail == "Waiting for the microphone permission asked at start-up.")

        let granted = Faculties(microphone: true, models: true, terminal: true, scope: .otherApps,
                                accessibility: true)
        #expect(Self.row(.microphone, in: Self.rows(granted))?.status == .done)
    }

    static let working = Faculties(microphone: true, models: true, terminal: true,
                                   scope: .otherApps, accessibility: true)

    @Test("the hold row names the armed keys, custom ones included, and the gesture")
    func holdRowNamesTheKeys() throws {
        let pair = try #require(Self.row(.holdKey, in: Self.rows(
            Self.working, hold: HoldSnapshot.of(armHoldTrigger: true, keys: [])))).detail
        #expect(pair.hasPrefix("The right Control key or the right Command key."), "\(pair)")
        #expect(pair.hasSuffix("Hold it in any text field, wait for the sound, speak, let go."))

        let custom = try #require(Self.row(.holdKey, in: Self.rows(
            Self.working, hold: HoldSnapshot.of(armHoldTrigger: true, keys: [.rightOption]))))
            .detail
        #expect(custom.contains("right Option key"), "\(custom)")
        #expect(!custom.contains("Control") && !custom.contains("Command"), "\(custom)")
    }

    @Test("under --no-hold the hold row says no key is armed, and names no gesture")
    func holdRowDisabled() throws {
        let row = try #require(Self.row(.holdKey, in: Self.rows(Self.working, hold: .disabled)))
        #expect(row.detail.contains("No hold key is armed"))
        #expect(row.detail.contains("--no-hold"))
        #expect(!row.detail.contains("Hold it"))
    }

    @Test("a hold that was not reported names no gesture at all")
    func holdRowAbsent() {
        let rows = Self.rows(Self.working, hold: nil)
        #expect(Self.row(.holdKey, in: rows) == nil)
        #expect(rows.allSatisfy { !$0.detail.contains("Hold it") })
    }

    // MARK: - a save error, inline

    @Test("a save error is shown inline on the screen the table picks, with that screen's controls",
          arguments: [
              snapshot(.undecided), snapshot(.agtermOnly), snapshot(.agtermOnly, offerSeen: true),
              snapshot(.otherApps, offerSeen: true),
              snapshot(.agtermOnly, loadProblem: unreadable),
              snapshot(.agtermOnly, offerSeen: true, loadProblem: newer),
          ])
    func aSaveErrorIsInline(_ base: StatusSnapshot) {
        var failed = base
        failed.setup?.saveError = Self.writeFailed
        let without = Self.model(base)
        let with = Self.model(failed)
        #expect(with.screen == without.screen)
        #expect(with.controls == without.controls)
        #expect(with.heading == without.heading)
        #expect(with.saveError == Self.writeFailed)
        #expect(without.saveError == nil)
    }

    // MARK: - the copy

    @Test("no copy the window can show promises every field")
    func noCopyPromisesEveryField() {
        // Search fields, combo boxes and unknown elements are refused (D31): "every field" is a
        // promise the product does not keep.
        let faculties: [Faculties] = [
            Self.working,
            Faculties(microphone: nil, models: nil, terminal: false, scope: .otherApps),
            Faculties(microphone: false, models: false, terminal: true, scope: .otherApps,
                      accessibility: false),
        ]
        var snapshots: [StatusSnapshot?] = [nil, StatusSnapshot(state: .idle)]
        for scope in SetupScope.allCases {
            for offerSeen in [false, true] {
                snapshots.append(Self.snapshot(scope, offerSeen: offerSeen))
                snapshots.append(Self.snapshot(scope, offerSeen: offerSeen, terminal: false))
            }
        }
        for problem in [Self.unreadable, Self.newer] {
            snapshots.append(Self.snapshot(.agtermOnly, loadProblem: problem,
                                           saveError: Self.writeFailed))
        }
        for facts in faculties {
            for hold in [nil, .disabled, HoldSnapshot.of(armHoldTrigger: true, keys: [])] {
                snapshots.append(Self.snapshot(.otherApps, offerSeen: true, faculties: facts,
                                               hold: hold))
            }
        }
        var copy = SetupControl.allCases.map(\.title)
        for snapshot in snapshots {
            for requested in [false, true] {
                let model = Self.model(snapshot, requested: requested)
                copy.append(model.heading)
                copy += model.body
                copy += model.controls.map(\.title)
                if case let .checklist(rows) = model.screen {
                    copy += rows.flatMap { [$0.title, $0.detail] }
                }
            }
        }
        for text in copy {
            #expect(!text.lowercased().contains("every field"), "\(text)")
            #expect(!text.lowercased().contains("any field"), "\(text)")
        }
    }
}
