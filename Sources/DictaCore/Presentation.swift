import Foundation

// How a `StatusSnapshot` and an `AttemptOutcome` are DRAWN — as pure values, in DictaCore.
//
// This looks like UI in the wrong module and is not. D19's rule is "a decision is a pure value;
// only its performance touches the world", and which glyph a state deserves is a decision: it is
// the thing that must not drift from acta's vocabulary, and the thing a reviewer will otherwise
// check by squinting at two screenshots. SwiftUI's job is to turn `Tint.red` into a colour and
// `"mic.fill"` into an image — that is the performance, and it lives in `DictaMenu`.
//
// The practical reason it cannot live in `DictaMenu`: SwiftPM cannot import an executable target,
// so anything decided there is unreachable from the test runner. The same argument that put
// `ClientCommand` here.
//
// `docs/ui-vocabulary.md` is the prose version of this file. When they disagree, this one is what
// ships, so the doc is the one to correct.

/// The colour vocabulary shared with acta. Deliberately five names rather than a palette: the rule
/// they encode is *what a colour means*, and two apps that agree on meaning look like one family
/// even if their exact shades differ by a hair.
public enum Tint: String, Codable, Sendable, CaseIterable {
    /// The ordinary, nothing-happening colour — SwiftUI's `.secondary`.
    case quiet
    /// Something is broken NOW, or the microphone is open. Both are things you must not miss.
    case red
    /// Working, or landed-but-degraded. Attention, not alarm.
    case amber
    /// It worked.
    case green
    /// Nothing there — SwiftUI's `.tertiary`. Used for absence, never for failure.
    case faint
}

/// How the menu bar and the panel header render one snapshot.
public struct Presentation: Sendable, Equatable {
    /// An SF Symbol name.
    public var glyph: String
    public var tint: Tint
    /// One line, under the app name. A sentence rather than a state name: `idle` is not something
    /// to show a person.
    public var status: String

    public init(glyph: String, tint: Tint, status: String) {
        self.glyph = glyph
        self.tint = tint
        self.status = status
    }

    /// The daemon is not running at all — no socket, or the stream ended.
    ///
    /// A state acta has no equivalent of, because acta's menu IS its daemon. Here the UI and the
    /// thing it describes are separate processes (D27), so "I cannot see it" is a state of its own
    /// and must never be drawn as "it is idle": idle means a chord would work.
    public static let daemonNotRunning = Presentation(
        glyph: "mic.slash",
        tint: .faint,
        status: "dicta is not running"
    )

    /// The glyph and sentence for a snapshot.
    ///
    /// Readiness outranks the lifecycle, and that ordering is the point: a daemon sitting in `idle`
    /// with no models is not ready, and drawing it the same as a healthy idle daemon is exactly the
    /// silence §2 of `docs/ui-proposal.md` says the user discovers by pressing a chord and getting
    /// nothing.
    ///
    /// Only a fault gets the red triangle. A pending step — no choice yet, no grant yet — blocks
    /// just as surely, but nothing is broken, and red before the person has done anything would
    /// teach them that red means nothing.
    public static func of(_ snapshot: StatusSnapshot) -> Presentation {
        if snapshot.readiness.isFault, !snapshot.isBusy {
            return Presentation(
                glyph: "exclamationmark.triangle.fill",
                tint: .red,
                status: snapshot.readiness.shortStatus
            )
        }
        switch snapshot.state {
        case .idle:
            // `fieldsOnly` is drawn as a healthy idle daemon, because it is one: a hold in any
            // other application dictates. The notice is the banner's to give, not the glyph's, and
            // so is a pending setup step's, which the status line still names.
            return Presentation(
                glyph: "mic",
                tint: .quiet,
                status: snapshot.readiness.shortStatus
            )
        case .warming:
            // NOT "Listening". D13 and invariant 4: nothing announces that the microphone is open
            // until capture confirms it, because a user who starts speaking here loses the first
            // syllable every time.
            return Presentation(glyph: "mic", tint: .quiet, status: "Opening the microphone…")
        case .recording:
            return Presentation(glyph: "mic.fill", tint: .red, status: "Listening")
        case .processing:
            return Presentation(glyph: "mic.badge.plus", tint: .amber, status: "Recognising…")
        case .injecting:
            return Presentation(glyph: "mic.badge.plus", tint: .amber, status: "Typing…")
        }
    }
}

public extension Readiness {
    /// The header's version of `message`: a few words rather than a sentence, because the sentence
    /// belongs in the banner where there is room for it and for its button.
    var shortStatus: String {
        switch self {
        case .ready: "Ready"
        case .starting: "Starting…"
        case .microphoneDenied: "Microphone denied"
        case .modelsMissing: "Models not downloaded"
        case .terminalMissing: "agterm not found"
        case .setupNeeded: "Not set up"
        case .accessibilityNeeded: "Needs Accessibility"
        case .accessibilityForFields: "Ready in agterm"
        case .fieldsOnly: "Ready, without agterm"
        }
    }
}

/// What marks an outcome on a row's second line, when anything does (D19).
///
/// **The ordinary is quiet**, which is acta's rule: a green dot on nearly every row is a colour the
/// eye learns to ignore, and the row that matters sat in that same field of dots with nothing but a
/// hue to set it apart. So a delivery carries no marker at all, and an exception is marked by a
/// symbol and by its word, which also survives a user who cannot tell amber from red.
public enum OutcomeMarker: Equatable, Sendable {
    /// No symbol, and the second line in the faint colour: there was nothing there, which is
    /// absence and not failure.
    case faint
    /// An SF Symbol drawn before the outcome's word, both in the outcome's tint.
    case symbol(String)
}

public extension AttemptOutcome {
    /// How a row marks this outcome, or `nil` when it is ordinary and nothing is drawn.
    ///
    /// One symbol per tint, so the symbol says what the colour says and nothing more; the word
    /// beside it says which exception this is. The names are a proposal a person judges on the
    /// built panel.
    var marker: OutcomeMarker? {
        // Decided from `tint`, so a marker cannot disagree with its colour. No outcome is `quiet`.
        switch tint {
        case .green, .quiet: nil
        case .faint: .faint
        case .amber: .symbol("exclamationmark.triangle")
        case .red: .symbol("xmark.circle")
        }
    }

    /// The colour of an outcome: of its marker, its word and its reason in `Recent Dictations`.
    ///
    /// Green means the words got somewhere. Amber means they got there but something about the
    /// journey is worth knowing. Red means they did not arrive. Faint means there were none. Green
    /// is never drawn on a row: a delivery is the ordinary outcome, and `marker` keeps it quiet.
    ///
    /// `returned` is GREEN and that is deliberate: D29's text reached its caller, which is a
    /// delivery and not a failure. It is not `injected` either — see `landedLabel`.
    var tint: Tint {
        switch self {
        case .injected, .returned: .green
        case .filterFellBack, .dictionaryDegraded, .injectionPartial: .amber
        case .targetGone, .injectionFailed, .recognitionFailed, .captureFault, .capped: .red
        case .empty, .aborted: .faint
        }
    }

    /// The word in the row's second line.
    ///
    /// `returned` says `returned to caller` rather than borrowing `injected`'s wording, because
    /// dicta cannot know what the calling script did with the text it handed over. "Delivered" is
    /// true; "arrived somewhere the user can see it" is not established.
    var label: String {
        switch self {
        case .injected: "typed"
        case .returned: "returned to caller"
        case .filterFellBack: "typed, filter skipped"
        case .dictionaryDegraded: "typed, dictionary degraded"
        case .injectionPartial: "may be partly typed"
        case .targetGone: "target gone"
        case .injectionFailed: "not delivered"
        case .recognitionFailed: "recognition failed"
        case .captureFault: "audio fault"
        case .capped: "stopped at the cap"
        case .empty: "nothing heard"
        case .aborted: "cancelled"
        }
    }
}
