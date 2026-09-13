import DictaCore
import SwiftUI

// Tier 1: the live target line, the two controls that end an attempt, and the receipt drawer.
//
// Wiring, like every other view here. What a row shows, what it is labelled, and whether it has
// anything to copy is `DictationRow` in `DictaCore`, where the test runner can reach it; the
// caption of the target line is `Target.caption(name:)` for the same reason. This file turns those
// into pixels and owns exactly one decision of its own — how long the copy button says `copied`.

/// Where the text is going, while it is still going somewhere.
///
/// D4 made visible. This is the one moment when noticing the wrong pane is free: after the
/// keystrokes it is somebody else's prompt, and the record can only say where it went.
struct TargetLine: View {
    let caption: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(caption)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}

/// `Stop and type` and `Abort`, present ONLY while an attempt is live.
///
/// **Absent when idle, not disabled** (D30). There is no Start here and there cannot be: a click
/// carries no session to aim at, so the panel can end an attempt a trigger began and can never
/// begin one itself. A greyed-out `Stop` would suggest the panel is where dictations are managed,
/// and the next question would be why the Start beside it is greyed out too.
struct AttemptControls: View {
    let stop: () -> Void
    let abort: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: stop) {
                Text("Stop and type").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            // `.large`, matching acta's primary action exactly. Read off `ActaApp.swift`, not
            // off the proposal's table, when the vocabulary was checked against the code it claims
            // to describe (2026-08-24) — dicta had shipped the default size, which is the kind of
            // drift a written-down vocabulary exists to catch and a proposal cannot.
            .controlSize(.large)
            .tint(.red)
            Button("Abort", action: abort)
                .buttonStyle(.borderless)
        }
    }
}

/// The last few attempts, newest first.
struct RecentDictations: View {
    let state: RecentState
    let now: Date
    let copy: (String) -> Void

    /// Which row's button is currently saying it worked. One at a time, because two ticks on screen
    /// at once would leave the user unsure which one they actually clicked.
    @State private var copied: AttemptID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Dictations")
                .font(.caption)
                .foregroundStyle(.secondary)
            // acta's idiom for a list it failed to read: the failure above, the list kept below it.
            // The rows are the last good read's, and those attempts happened whatever the file
            // says now. Unread draws nothing here at all: no read has claimed anything yet.
            if let failure = state.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Tint.amber.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.saysNothingYet {
                Text("Nothing yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(state.rows) { row in
                    RecentRow(row: row, now: now, copied: copied == row.id) { text in
                        copy(text)
                        copied = row.id
                        Task {
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            if copied == row.id { copied = nil }
                        }
                    }
                }
            }
        }
    }
}

struct RecentRow: View {
    let row: DictationRow
    let now: Date
    let copied: Bool
    let copy: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                primary
                secondLine
                // The sentence the user was already shown, from §9's own `error` field — so this
                // and the notification cannot word one event two ways. Tinted like the marker,
                // because an amber reason ("typed, filter skipped") and a red one ("the target is
                // gone") are different news and the row should not make them look alike.
                if let reason = row.reason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(row.tint.color)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            copyButton
        }
    }

    /// What happened, then when — laid out as acta lays out its recordings' second line.
    ///
    /// **There is no dot column: colour marked the ordinary.** A delivery is most rows, so its
    /// green dot was a colour the eye learned to ignore. Now an ordinary outcome draws its word in
    /// the secondary colour and nothing else; an exception draws a 9 pt symbol and its word, both
    /// tinted; an attempt with nothing in it is faint. The marker is `DictaCore`'s decision
    /// (`AttemptOutcome.marker`), and the details after the word are quiet, as acta's stamp is.
    ///
    /// The ordinary word stays, unlike acta's: acta has one ordinary state, and dicta has two —
    /// `typed` and `returned to caller` say different things about where the text went.
    private var secondLine: some View {
        let parts = row.secondaryParts(at: now)
        return HStack(spacing: 4) {
            if case let .symbol(name) = row.marker {
                Image(systemName: name)
                    .font(.system(size: 9))
                    .foregroundStyle(row.tint.color)
            }
            outcomeWord(parts.outcome)
            if !parts.details.isEmpty {
                Text("· " + parts.details.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .lineLimit(1)
    }

    /// Tinted for an exception and faint for absence, both from `tint`; `.secondary` when ordinary.
    @ViewBuilder
    private func outcomeWord(_ word: String) -> some View {
        if row.marker == nil {
            Text(word).font(.caption2).foregroundStyle(.secondary)
        } else {
            Text(word).font(.caption2).foregroundStyle(row.tint.color)
        }
    }

    /// `final` on one line, truncated at the TAIL — the beginning of a dictation is what identifies
    /// it, and a middle truncation would cut the half the user is scanning for.
    ///
    /// A row showing `recognised` instead is rendered in italic, because it is not what dicta typed
    /// anywhere: it is what dicta heard, verbatim and unreplaced (D26, D28). The word is on the
    /// second line; the italic is so the two kinds of row cannot be skimmed as one.
    @ViewBuilder
    private var primary: some View {
        if row.text.isEmpty {
            Text("—").font(.callout).foregroundStyle(.tertiary)
        } else {
            Text(row.text)
                .font(.callout)
                .italic(row.showsRecognised)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// Present only when there is something to copy, and the row decided that, not this view
    /// (D28). `copyable` is `final` and never `recognised`, so the clipboard cannot be loaded with
    /// words that were deliberately never delivered.
    @ViewBuilder
    private var copyButton: some View {
        if let text = row.copyable {
            Button {
                copy(text)
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Copy this dictation")
        }
    }
}
