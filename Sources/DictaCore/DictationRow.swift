import Foundation

// One row of `Recent Dictations`, as a value (D27, D28, D19).
//
// The panel renders these and decides nothing. What is decided here is everything that could be
// wrong: which text a row shows, whether that text is what was DELIVERED or what was merely HEARD,
// and — the one with teeth — whether there is anything to copy at all.
//
// **`copyable` is D28 made structural rather than remembered.** The rule is that the UI acts on
// `final` and only displays `recognised`: recovery is the clipboard, and the clipboard may never be
// loaded with text that was deliberately not delivered. Writing that as a branch in the view would
// make it a thing to remember; writing it as an optional makes the button ABSENT — not disabled —
// because there is nothing for it to carry.

/// One entry of §9's record, ready to draw.
public struct DictationRow: Sendable, Equatable, Identifiable {
    public var id: AttemptID
    public var at: Date
    public var outcome: AttemptOutcome
    public var mode: Mode
    /// The primary line: what was delivered, or — when nothing was — what was heard.
    public var text: String
    /// Whether `text` is the recogniser's verbatim output rather than what was typed.
    ///
    /// D26 made this an ordinary row rather than a curiosity: an abort and D15's cap now write the
    /// speech down with an empty `final`, so the words exist and were never delivered. The flag is
    /// what stops the panel presenting them as though they had been — the same sentence read as
    /// "this is what dicta typed" and as "this is what dicta heard" is two different claims.
    public var showsRecognised: Bool
    /// What the copy button puts on the clipboard, or `nil` when there is no button.
    ///
    /// **Always `final`, never `recognised`** (D28). A row showing recognised text therefore has no
    /// button, which is the structural half: the affordance cannot be pointed at the wrong field
    /// because the wrong field never reaches it.
    public var copyable: String?
    /// The buffer's own length (§9's `audioSeconds`), when the entry carries one.
    public var audioSeconds: Double?
    /// **The sentence the user was already shown**, from §9's `error`, or `nil` when there was
    /// nothing to say.
    ///
    /// The proposal asked for this as a dismissible banner over the last attempt, "carrying the
    /// same sentence the notification carried". It is a row instead, and the row is the better
    /// answer for two reasons. One event with two wordings is how a user learns to distrust both —
    /// and reading §9's own field means there is only ever one wording, by construction rather than
    /// by two strings kept in step. And a banner covers the most recent attempt only, while the
    /// reason for the one before it is exactly as worth having and exactly as hard to get: the
    /// notification is gone by the time anybody looks.
    ///
    /// Not only for failures. A filter fallback and a degraded dictionary both delivered the text
    /// and both left a reason, which is why this follows the FIELD rather than the outcome's class.
    ///
    /// **A reason that only repeats the outcome's own name is not a reason, and is dropped.**
    /// Measured against this user's real record (2026-08-24): 870 of 902 entries are `aborted`
    /// carrying `error: "aborted"`, so taking the field at face value would have put a redundant
    /// second line under almost every row in the drawer — under a row already labelled `cancelled`,
    /// which is the same word. `empty`'s "nothing was recognised" is a real sentence and survives.
    /// The comparison is against the raw value the file holds, which is what such a line always is:
    /// something wrote the outcome where a sentence belonged.
    public var reason: String?

    /// The dot beside the row.
    public var tint: Tint { outcome.tint }

    /// The outcome, in the words `AttemptOutcome.label` chose.
    ///
    /// Deliberately the outcome's OWN word rather than a blanket `cancelled` for every row whose
    /// `final` is empty. `aborted` already reads `cancelled`, which is what the plan asked for; but
    /// D15's cap lands in the same shape and is not a cancellation — telling the user their
    /// ten-minute dictation was "cancelled" would hide the one fact that explains it. This project
    /// has the rule already, in another costume: only `sessionNotFound` is allowed to be called
    /// `targetGone`.
    public var label: String { outcome.label }

    public init(_ entry: RecordEntry) {
        id = entry.id
        at = entry.at
        outcome = entry.outcome
        mode = entry.mode
        audioSeconds = entry.audioSeconds
        let said = entry.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        reason = (said.isEmpty || said == entry.outcome.rawValue) ? nil : said
        let delivered = entry.final
        if delivered.isEmpty, !entry.recognised.isEmpty {
            text = entry.recognised
            showsRecognised = true
            copyable = nil
        } else {
            text = delivered
            showsRecognised = false
            copyable = delivered.isEmpty ? nil : delivered
        }
    }

    /// The second line: when, what happened, and — when it matters — that the words above were
    /// never typed anywhere.
    public func secondary(at now: Date) -> String {
        var parts = [RelativeTime.describe(at, at: now), label]
        // Said out loud rather than left to be inferred from the outcome. The outcome says the
        // attempt did not land; this says the sentence the user is reading is raw recogniser
        // output — unreplaced, unsanitised, and not what any pane received (§9, invariant 1's
        // parenthesis).
        if showsRecognised { parts.append("recognised only") }
        // `clean` is what every ordinary attempt is, so printing it on every row spends a quarter
        // of the line saying "nothing unusual". `raw` is the one the user chose deliberately (D3)
        // and the one that explains a filtered stage that did not run.
        if mode == .raw { parts.append("raw") }
        if let audioSeconds { parts.append(Duration.short(audioSeconds)) }
        return parts.joined(separator: " · ")
    }

    /// The last `entries` of a record, newest FIRST — which is the order a drawer is read in, and
    /// the reverse of the order the journal is written in.
    public static func rows(from entries: [RecordEntry]) -> [DictationRow] {
        entries.reversed().map(DictationRow.init)
    }
}

/// How long ago, in English.
///
/// Hand-written on purpose. `RelativeDateTimeFormatter` is LOCALE-DEPENDENT, and this machine's
/// locale is not English: it would put a Cyrillic caption into a panel in a project whose rule is
/// English only with no exceptions. `Scripts/lint.sh` could not catch it either, because the
/// letters would be produced at runtime by Foundation rather than written in a source file — and
/// this very comment proves the point, since the first draft of it quoted the formatter's output
/// verbatim and the lint went red. A formatter is also untestable in the way that matters: its
/// output changes with the user's settings, so an assertion about it asserts the machine it ran on.
public enum RelativeTime {
    /// Under this, a row reads `now` rather than counting seconds nobody cares about.
    public static let momentSeconds: Double = 5

    public static func describe(_ date: Date, at now: Date) -> String {
        let elapsed = now.timeIntervalSince(date)
        // A clock moved backwards — the machine slept, or NTP stepped it — must not produce
        // "-3m ago". The entry exists, so it happened; "now" is the least wrong thing to say.
        guard elapsed > momentSeconds else { return "now" }
        if elapsed < 60 { return "\(Int(elapsed))s ago" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
        return "\(Int(elapsed / 86400))d ago"
    }
}

/// Seconds, rendered for a person.
public enum Duration {
    /// `12s` under a minute, `2:41` above it. The second form is the header timer's, so a row and
    /// the clock that was ticking while it was recorded read the same way.
    public static func short(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        guard whole >= 60 else { return "\(max(0, whole))s" }
        return clock(Double(whole))
    }

    /// `m:ss`, always — a running clock, for the menu bar and the panel's header.
    ///
    /// Truncated rather than rounded, because it counts UP: a clock that showed `0:01` before one
    /// second of speech had happened would be claiming audio that is not in the buffer, which is
    /// the same class of small lie D13 refuses at the other end of the attempt.
    public static func clock(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
