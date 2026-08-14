import Foundation

/// What the recogniser handed back, judged before it is allowed to become **recognised** (§2).
///
/// §7 gives the recogniser three rows, and two of them are decided here:
///
///   • *"returns text that is not valid UTF-8 or is longer than the frame limit"* → a processing
///     failure: no injection, notify, and **record the raw bytes' length and the error**. The
/// length     is the whole diagnostic value of that row — an attempt recorded as "the recogniser
/// failed"     with no number leaves a human unable to tell a runaway decode from a broken model.
///   • *"returns nothing but whitespace"* → empty. That one is `Sanitizer`'s to enforce and is not
///     duplicated here; what this adds is that the text has to survive the wire first.
///
/// Why the frame limit is the ceiling and not some larger number of its own: the text travels
/// twice. Once as §9's `recognised`, and once back out through the control socket when `dictactl
/// last` asks for it — where `Wire.encode` throws above `maxFrameBytes`. Text accepted here and
/// refused there would be text the user is told exists and can never read.
///
/// So the ceiling is the frame limit **less an allowance for the envelope**, not the frame limit
/// itself. The readback frame is a whole `Response` — `kind`, `state`, `attempt`, `target`, and the
/// JSON quoting around the text — so setting the two numbers equal left text in the last few
/// hundred bytes accepted into the record and unencodable on the way out. `ControlServer` closed
/// the connection when that happened, and `dictactl` reported a healthy daemon as dead. The
/// allowance covers the envelope; JSON escaping can still expand pathological text past the frame,
/// which is why the server also answers with a short refusal instead of dropping the connection.
///
/// Pure, and separate from any transcriber, because it is a rule about the seam rather than about
/// Parakeet: any recogniser behind `Transcriber` is held to it, and a later one that decodes bytes
/// itself has the UTF-8 branch waiting for it (D19).
public enum RecognisedText {
    /// The verdict. Deliberately not `String?`: the failure carries the byte length §7 wants
    /// recorded, and an optional would leave every call site inventing its own message.
    public enum Validation: Equatable, Sendable {
        /// Within the limit and decodable. The associated text is what becomes **recognised**.
        case text(String)
        /// Bytes that are not valid UTF-8. Carries their length, since nothing else about them can
        /// honestly be written down.
        case notUTF8(bytes: Int)
        /// Longer than the wire will carry. Carries the length and the limit it exceeded.
        case tooLong(bytes: Int, limit: Int)

        /// The sentence §7 wants notified and recorded. Names the number in both failures, because
        /// "the recogniser returned something unusable" is not a diagnosis.
        public var failureReason: String? {
            switch self {
            case .text:
                nil
            case let .notUTF8(bytes):
                "the recogniser returned \(bytes) bytes that are not valid UTF-8 "
                    + "-- nothing was typed"
            case let .tooLong(bytes, limit):
                "the recogniser returned \(bytes) bytes, over dicta's \(limit)-byte limit "
                    + "-- nothing was typed"
            }
        }
    }

    /// What a `Response` costs around the text: the four other fields, their keys, the JSON braces
    /// and the terminating newline. A kilobyte is far more than the longest `target` agterm
    /// produces (two `surface:`/`session:` UUIDs), leaving the number obviously safe rather than
    /// exactly right — the cost of being generous is a kilobyte of dictation nobody will reach,
    /// and the cost of being tight is the failure described above.
    public static let responseEnvelopeBytes = 1024

    /// The ceiling: the wire's frame limit, less the envelope it has to travel inside.
    public static var maxBytes: Int { Wire.maxFrameBytes - responseEnvelopeBytes }

    /// Judges bytes. This is the honest entry point for a recogniser that produces bytes rather
    /// than a `String`, and the only one from which `notUTF8` is reachable.
    public static func validate(_ bytes: Data) -> Validation {
        guard bytes.count <= maxBytes else {
            return .tooLong(bytes: bytes.count, limit: maxBytes)
        }
        // `String(data:encoding:)` returns nil for invalid UTF-8 rather than substituting U+FFFD,
        // which is what makes it a check and not a repair. A repair here would inject mojibake.
        guard let text = String(data: bytes, encoding: .utf8) else {
            return .notUTF8(bytes: bytes.count)
        }
        return .text(text)
    }

    /// Judges a `String`. A Swift `String` is already valid UTF-8, so only the length branch can
    /// fire from here -- stated rather than left to be rediscovered, because a reader who assumes
    /// this path can report `notUTF8` will go looking for a test that cannot exist.
    public static func validate(_ text: String) -> Validation {
        let bytes = text.utf8.count
        guard bytes <= maxBytes else { return .tooLong(bytes: bytes, limit: maxBytes) }
        return .text(text)
    }
}
