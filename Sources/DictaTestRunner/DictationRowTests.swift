import DictaCore
import DictaRecord
import DictaRuntime
import Foundation
import Testing

/// The receipt drawer, as values (Tier 1, D28, D19).
///
/// The `ForEach` is not tested and this suite does not pretend otherwise. What is tested is every
/// decision under it — which colour, which word, and above all **what may be copied** — because
/// `DictaMenu` is an executable target SwiftPM cannot import, so a rule written in the view would
/// be unreachable from here.
@Suite("dictation rows")
struct DictationRowTests {
    static let when = Date(timeIntervalSince1970: 1_700_000_000)

    static func entry(
        id: AttemptID = 1,
        outcome: AttemptOutcome = .injected,
        final: String = "hello there",
        recognised: String = "hello there",
        mode: Mode = .clean,
        audioSeconds: Double? = nil
    ) -> RecordEntry {
        RecordEntry(id: id, at: when, outcome: outcome, mode: mode,
                    recognised: recognised, final: final,
                    target: Target(sessionID: "S1", pane: .left),
                    audioSeconds: audioSeconds)
    }

    // MARK: - every outcome, exhaustively

    @Test("every outcome has a colour and a word, and a new one cannot compile without them")
    func everyOutcomeIsDrawn() {
        // The `switch` below has no `default`, which is the actual gate: a twelfth outcome — and
        // D29 added exactly that between the proposal and this suite — fails to COMPILE here rather
        // than rendering as an unmarked row nobody notices. The loop after it is the
        // cheaper half, catching an empty label.
        for outcome in AttemptOutcome.allCases {
            switch outcome {
            case .injected, .returned:
                #expect(outcome.tint == .green)
            case .filterFellBack, .dictionaryDegraded, .injectionPartial:
                #expect(outcome.tint == .amber)
            case .targetGone, .injectionFailed, .recognitionFailed, .captureFault, .capped:
                #expect(outcome.tint == .red)
            case .empty, .aborted:
                #expect(outcome.tint == .faint)
            }
            #expect(!outcome.label.isEmpty)
        }
    }

    @Test("the ordinary outcomes carry no marker, absence is faint, and every exception a symbol")
    func everyOutcomeHasItsMarker() {
        // acta's rule, "the ordinary is quiet": a dot on nearly every row is a colour the eye
        // learns to ignore, and the rare row that matters sits in that same field of dots. No
        // `default` here either, so a new outcome cannot compile without being placed.
        var symbols: [Tint: Set<String>] = [:]
        for outcome in AttemptOutcome.allCases {
            switch outcome {
            case .injected, .returned:
                #expect(outcome.marker == nil, "\(outcome.rawValue)")
            case .empty, .aborted:
                // Absence is not failure: no symbol, only the faint line.
                #expect(outcome.marker == .faint, "\(outcome.rawValue)")
            case .filterFellBack, .dictionaryDegraded, .injectionPartial, .targetGone,
                 .injectionFailed, .recognitionFailed, .captureFault, .capped:
                guard case let .symbol(name) = outcome.marker else {
                    Issue.record("\(outcome.rawValue) has no symbol")
                    continue
                }
                #expect(!name.isEmpty)
                symbols[outcome.tint, default: []].insert(name)
            }
        }
        // One symbol per tint, so the symbol says what the colour says and nothing more: amber and
        // red each have one, and they are not the same one.
        #expect(symbols[.amber]?.count == 1)
        #expect(symbols[.red]?.count == 1)
        #expect(symbols[.amber] != symbols[.red])
        #expect(Set(symbols.keys) == [.amber, .red])
    }

    @Test("a row's marker is its outcome's")
    func rowForwardsTheMarker() {
        for outcome in AttemptOutcome.allCases {
            #expect(DictationRow(Self.entry(outcome: outcome)).marker == outcome.marker)
        }
    }

    @Test("returned is not cancelled, and the FIELD is what says so")
    func returnedIsNotCancelled() {
        // The pair that gets reasoned about backwards, which is why they are asserted side by side.
        // Both are attempts where nothing was typed into a pane — but `returned` produced a full
        // `final` and handed it over (D29), and `aborted` produced none (D26). The outcome's NAME
        // suggests they are alike; the `final` field is what actually separates them, and every
        // affordance below follows the field.
        let returned = DictationRow(Self.entry(outcome: .returned, final: "take this"))
        let cancelled = DictationRow(Self.entry(outcome: .aborted, final: "",
                                                recognised: "take this"))
        #expect(returned.tint == .green)
        #expect(returned.label == "returned to caller")
        #expect(returned.copyable == "take this")
        #expect(!returned.showsRecognised)
        // ... and its counterpart offers nothing at all.
        #expect(cancelled.label == "cancelled")
        #expect(cancelled.copyable == nil)
        #expect(cancelled.showsRecognised)
        #expect(cancelled.text == "take this")
    }

    @Test("returned says what it did rather than borrowing injected's word")
    func returnedHasItsOwnWord() {
        // dicta handed the text to a script and cannot know what the script did with it.
        // "Delivered" is true; "arrived somewhere the user can see it" is not established, so the
        // row must not read the same as one that typed into a pane the user is looking at.
        #expect(AttemptOutcome.returned.label != AttemptOutcome.injected.label)
    }

    // MARK: - what may be copied (D28, structurally)

    @Test("the clipboard is offered `final` and never `recognised`")
    func copyIsAlwaysFinal() {
        for outcome in AttemptOutcome.allCases {
            let delivered = DictationRow(Self.entry(outcome: outcome, final: "delivered",
                                                    recognised: "heard"))
            // Whatever went wrong, the copyable text is the one that was PREPARED for injection —
            // replaced, filtered, sanitised. `recognised` is raw recogniser output and can carry
            // the newline D8 makes dangerous; the UI displays it and never hands it over.
            #expect(delivered.copyable == "delivered")

            let nothing = DictationRow(Self.entry(outcome: outcome, final: "",
                                                  recognised: "heard"))
            // Absent rather than disabled: there is no branch that could point the button at the
            // wrong field, because the wrong field never reaches it.
            #expect(nothing.copyable == nil)
        }
    }

    @Test("a row with neither text shows a placeholder and offers nothing")
    func emptyRow() {
        let row = DictationRow(Self.entry(outcome: .empty, final: "", recognised: ""))
        #expect(row.text.isEmpty)
        #expect(row.copyable == nil)
        #expect(!row.showsRecognised)
    }

    // MARK: - the label is the outcome's own word

    @Test("a capped attempt is not called cancelled just because it delivered nothing")
    func cappedKeepsItsOwnWord() {
        // D26 made abort and D15's cap land in the SAME shape: speech written down, `final` empty.
        // The plan's sentence — "labelled cancelled" — was written when only abort could do that.
        // Calling a ten-minute dictation stopped by the cap "cancelled" would hide the one fact
        // that explains it, which is this project's own rule about `targetGone` in another costume.
        let capped = DictationRow(Self.entry(outcome: .capped, final: "", recognised: "a long one"))
        #expect(capped.showsRecognised)
        #expect(capped.copyable == nil)
        #expect(capped.label == "stopped at the cap")
        #expect(capped.label != AttemptOutcome.aborted.label)
    }

    @Test("a row says out loud that what you are reading was never typed anywhere")
    func recognisedOnlyIsDeclared() {
        let row = DictationRow(Self.entry(outcome: .aborted, final: "", recognised: "heard this"))
        let line = row.secondary(at: Self.when)
        // The outcome says the attempt did not land. This says the sentence above it is raw
        // recogniser output — unreplaced, unsanitised, and not what any pane received.
        #expect(line.contains("recognised only"))
        let delivered = DictationRow(Self.entry(outcome: .injected))
        #expect(!delivered.secondary(at: Self.when).contains("recognised only"))
    }

    // MARK: - the reason

    @Test("a row carries the sentence the user was already shown, and does not invent a second one")
    func rowCarriesTheReason() {
        // §9's `error` is defined as "the reason the user was shown, when there was one", so taking
        // it verbatim is what makes one event have one wording. The proposal asked for this as a
        // dismissible banner over the last attempt; a row is better because the reason for the
        // attempt BEFORE the last one is exactly as worth having, and by then the notification is
        // long gone.
        var entry = Self.entry(outcome: .targetGone, final: "hello there")
        entry.error = "the left pane of S1 is gone"
        #expect(DictationRow(entry).reason == "the left pane of S1 is gone")

        // Not only for failures: a filter fallback delivered the text and still left a reason.
        var degraded = Self.entry(outcome: .filterFellBack)
        degraded.error = "the filter did not run"
        #expect(DictationRow(degraded).reason == "the filter did not run")

        // Nothing to say is `nil` rather than an empty line in the panel.
        #expect(DictationRow(Self.entry()).reason == nil)
        var blank = Self.entry()
        blank.error = ""
        #expect(DictationRow(blank).reason == nil)
    }

    @Test("a reason that only repeats the outcome is not a reason")
    func reasonNeverEchoesTheOutcome() {
        // Measured against the real record rather than imagined: 870 of 902 entries there are
        // `aborted` carrying `error: "aborted"`. Taken at face value that is a redundant second
        // line under nearly every row in the drawer — and under a row already labelled `cancelled`,
        // which is the same word said twice.
        var echoed = Self.entry(outcome: .aborted, final: "", recognised: "heard")
        echoed.error = AttemptOutcome.aborted.rawValue
        #expect(DictationRow(echoed).reason == nil)
        // Whitespace around it does not make it a sentence either.
        echoed.error = "  aborted \n"
        #expect(DictationRow(echoed).reason == nil)
        // The hyphenated raw values are what land in the file, so those are what this compares.
        var gone = Self.entry(outcome: .targetGone)
        gone.error = AttemptOutcome.targetGone.rawValue
        #expect(DictationRow(gone).reason == nil)
        // And a real sentence survives, including the short one `empty` actually writes.
        var empty = Self.entry(outcome: .empty, final: "", recognised: "")
        empty.error = "nothing was recognised"
        #expect(DictationRow(empty).reason == "nothing was recognised")
    }

    @Test("a failed row still offers its text, because the reason is not the recovery")
    func aFailedRowIsStillCopyable() {
        // The row that matters most in this whole drawer: the dictation that went nowhere. It reads
        // red and names why, and the words are still on the clipboard in one click — which is the
        // entire recovery story (D28) and the reason the record is written before injection is
        // attempted (invariant 10).
        var entry = Self.entry(outcome: .targetGone, final: "the sentence that never arrived")
        entry.error = "the left pane of S1 is gone"
        let row = DictationRow(entry)
        #expect(row.tint == .red)
        #expect(row.copyable == "the sentence that never arrived")
        #expect(row.reason != nil)
    }

    // MARK: - the second line

    @Test("the second line carries what happened, when, and how long was spoken")
    func secondaryLine() {
        let row = DictationRow(Self.entry(outcome: .injected, audioSeconds: 12.4))
        let line = row.secondary(at: Self.when.addingTimeInterval(240))
        #expect(line == "typed · 4m ago · 12s")
    }

    @Test("the second line's parts put the outcome's word first and never repeat it in the details")
    func secondaryParts() {
        let later = Self.when.addingTimeInterval(240)
        for outcome in AttemptOutcome.allCases {
            let row = DictationRow(Self.entry(outcome: outcome, audioSeconds: 12.4))
            let parts = row.secondaryParts(at: later)
            // `AttemptOutcome.label` stays the word's only source.
            #expect(parts.outcome == outcome.label)
            #expect(!parts.details.contains(outcome.label))
            #expect(parts.details == ["4m ago", "12s"])
            #expect(row.secondary(at: later)
                == ([parts.outcome] + parts.details).joined(separator: " · "))
        }
        // Every detail, in today's order: when, recognised only, raw, how long.
        let everything = DictationRow(Self.entry(outcome: .capped, final: "", recognised: "heard",
                                                 mode: .raw, audioSeconds: 600))
        let parts = everything.secondaryParts(at: later)
        #expect(parts.outcome == "stopped at the cap")
        #expect(parts.details == ["4m ago", "recognised only", "raw", "10:00"])
        #expect(everything.secondary(at: later)
            == "stopped at the cap · 4m ago · recognised only · raw · 10:00")
        // Without a duration there is nothing after the time.
        #expect(DictationRow(Self.entry()).secondaryParts(at: Self.when).details == ["now"])
    }

    @Test("`raw` is named and `clean` is not")
    func modeIsShownOnlyWhenChosen() {
        let raw = DictationRow(Self.entry(mode: .raw)).secondary(at: Self.when)
        #expect(raw.contains("raw"))
        // `clean` is what every ordinary attempt is (D3), so printing it on every row spends a
        // quarter of a 300 pt line saying "nothing unusual".
        let clean = DictationRow(Self.entry(mode: .clean)).secondary(at: Self.when)
        #expect(!clean.contains("clean"))
    }

    @Test("relative time is written here rather than formatted, because a formatter speaks Russian")
    func relativeTime() {
        let now = Self.when
        #expect(RelativeTime.describe(now, at: now) == "now")
        #expect(RelativeTime.describe(now.addingTimeInterval(-30), at: now) == "30s ago")
        #expect(RelativeTime.describe(now.addingTimeInterval(-240), at: now) == "4m ago")
        #expect(RelativeTime.describe(now.addingTimeInterval(-7200), at: now) == "2h ago")
        #expect(RelativeTime.describe(now.addingTimeInterval(-3 * 86400), at: now) == "3d ago")
        // A clock moved backwards — the machine slept, NTP stepped it — must not print "-3m ago".
        // The entry exists, so it happened; "now" is the least wrong thing to say.
        #expect(RelativeTime.describe(now.addingTimeInterval(600), at: now) == "now")
    }

    @Test("a duration reads the same way in a row as it does in the header's clock")
    func durations() {
        #expect(Duration.short(12.4) == "12s")
        #expect(Duration.short(0) == "0s")
        #expect(Duration.short(161) == "2:41")
    }

    // MARK: - order

    @Test("the drawer reads newest first, which is the reverse of the journal")
    func newestFirst() {
        let rows = DictationRow.rows(from: [Self.entry(id: 1), Self.entry(id: 2),
                                            Self.entry(id: 3)])
        #expect(rows.map(\.id) == [3, 2, 1])
    }

    @Test("the rows the panel shows come off a real record through the bounded reader")
    func endToEndFromDisk() throws {
        let url = try RecordReaderTests.scratch()
        try RecordReaderTests.write([
            RecordReaderTests.entry(id: 1),
            RecordReaderTests.entry(id: 2, outcome: .aborted, final: "", recognised: "dropped"),
            RecordReaderTests.entry(id: 3, outcome: .returned),
        ], to: url)
        let reading = try RecordReader.tail(of: url, entries: 5)
        let rows = DictationRow.rows(from: reading.entries)
        #expect(rows.map(\.id) == [3, 2, 1])
        #expect(rows[0].tint == .green)
        #expect(rows[1].copyable == nil)
        #expect(rows[2].copyable == "hello")
    }

    // MARK: - the drawer's state

    @Test("only a read that found nothing says Nothing yet")
    func onlyAnEmptyReadSaysNothingYet() {
        let rows = DictationRow.rows(from: [Self.entry(id: 1)])
        #expect(RecentState.read([]).saysNothingYet)
        #expect(!RecentState.read(rows).saysNothingYet)
        #expect(!RecentState.unread.saysNothingYet)
        // A failure with nothing to keep is still not an empty record.
        #expect(!RecentState.failed(reason: "it could not be opened", lastGood: []).saysNothingYet)
    }

    @Test("an unread drawer draws no rows and no failure")
    func unreadDrawsNothing() {
        #expect(RecentState.unread.rows.isEmpty)
        #expect(RecentState.unread.failure == nil)
    }

    @Test("a failure keeps the last good rows and carries its reason")
    func failureKeepsTheLastGoodRows() {
        let rows = DictationRow.rows(from: [Self.entry(id: 1), Self.entry(id: 2)])
        let failed = RecentState.read(rows).afterFailure(reason: "it could not be opened")
        #expect(failed == .failed(reason: "it could not be opened", lastGood: rows))
        #expect(failed.rows == rows)
        #expect(failed.failure == "The record could not be read: it could not be opened")

        // A second failure keeps the same rows and says the newer reason.
        let again = failed.afterFailure(reason: "Operation not permitted")
        #expect(again == .failed(reason: "Operation not permitted", lastGood: rows))

        // Failing before anything was read keeps nothing, and claims nothing either.
        #expect(RecentState.unread.afterFailure(reason: "x") == .failed(reason: "x", lastGood: []))
    }

    @Test("a read after a failure clears it and replaces the rows")
    func readClearsTheFailure() {
        let old = DictationRow.rows(from: [Self.entry(id: 1)])
        let new = DictationRow.rows(from: [Self.entry(id: 1), Self.entry(id: 2)])
        let recovered = RecentState.failed(reason: "x", lastGood: old).afterRead(new)
        #expect(recovered == .read(new))
        #expect(recovered.failure == nil)
        #expect(recovered.rows == new)
        #expect(RecentState.unread.afterRead([]) == .read([]))
    }

    // MARK: - the target line

    @Test("the target line names the session and ALWAYS names the pane")
    func caption() {
        let target = Target(sessionID: "DFC6C3B8-1234-5678-9ABC-DEF012345678", pane: .left)
        #expect(target.caption(name: "claude-code") == "claude-code · left")
        // The pane is the half a user is most likely to have got wrong — focus moves between panes
        // and the session does not — so it is never dropped in favour of a friendlier name.
        #expect(target.caption(name: nil) == "DFC6C3B8… · left")
        // A short id is not decorated with an ellipsis it did not earn.
        #expect(Target(sessionID: "S1", pane: .right).caption(name: nil) == "S1 · right")
    }

    @Test("a focused field's target line names the application, and nothing a session could")
    func fieldCaption() {
        let code = Target.focusedField(FieldTarget(bundleID: "com.microsoft.VSCode",
                                                   appName: "Code", pid: 4242))
        #expect(code.caption(name: nil) == "Code")
        // A session name belongs to agterm's tree; handed one here, it cannot describe a field.
        #expect(code.caption(name: "claude-code") == "Code")
        #expect(code.sessionID == nil)
        // An application with no name still gets a caption someone can compare: an empty target
        // line is worse than an identifier.
        #expect(Target.focusedField(FieldTarget(bundleID: "dev.example.tool", appName: "", pid: 7))
            .caption(name: nil) == "dev.example.tool")
        #expect(Target.focusedField(FieldTarget(bundleID: nil, appName: "", pid: 7))
            .caption(name: nil) == "pid 7")
        #expect(Target(sessionID: "S1", pane: .left).sessionID == "S1")
    }

    @Test("the name reader and the target resolver read the same tree")
    func oneTreeTwoReaders() throws {
        // The drift guard for a decoder that is deliberately a SECOND one: `Agterm`'s parser lives
        // in `DictaRuntime`, which links FluidAudio and which the menu binary must not reach (D27,
        // invariant 8). Both are run over the ONE fixture that is itself checked against what the
        // installed agterm prints, so a change in the tree's shape cannot be fixed in one of them
        // and forgotten in the other.
        let tree = AgtermTests.oneLeftPane
        let names = SessionNames.names(inTree: tree)
        #expect(names["S1"] == "s")
        let resolved = try AgtermTests.agterm(AgtermTests.StubRunner(tree: tree))
            .resolveTarget(sessionID: "S1")
        #expect(resolved == Target(sessionID: "S1", pane: .left))
    }

    @Test("a tree that cannot be read costs a name and never an error")
    func namesFailQuietly() {
        // This decoder decides nothing — it labels a line — so its failure mode is to return
        // nothing and let the caller show the session id. `Agterm`'s answer aims keystrokes and
        // fails closed instead (D6); the two are allowed to differ precisely there.
        #expect(SessionNames.names(inTree: "").isEmpty)
        #expect(SessionNames.names(inTree: "not json at all").isEmpty)
        #expect(SessionNames.names(inTree: #"{"ok":false,"error":"no"}"#).isEmpty)
        #expect(SessionNames.names(inTree: #"{"ok":true,"result":{"tree":{}}}"#).isEmpty)
    }

    @Test("a session with no name of its own is left to be shown by id")
    func namelessSessions() {
        // Both shapes agterm can produce for "this one has no name": the key absent, and the key
        // present and empty. An empty caption would be worse than a UUID — it is a target line with
        // nothing on the left of the separator, which reads as a bug rather than as a missing name.
        let tree = #"{"ok":true,"result":{"tree":{"workspaces":["#
            + #"{"sessions":[{"id":"A"},{"id":"B","name":""},{"id":"C","name":"claude-code"}]},"#
            + #"{"sessions":[{"id":"D","name":"second-workspace"}]}]}}}"#
        let names = SessionNames.names(inTree: tree)
        #expect(names["A"] == nil)
        #expect(names["B"] == nil)
        #expect(names["C"] == "claude-code")
        // Every workspace is read, not only the active one: the caption is for an attempt that is
        // already running, and D4 says its session is where it was, not where focus has since gone.
        #expect(names["D"] == "second-workspace")
    }
}
