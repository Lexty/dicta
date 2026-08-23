import DictaCore
import Foundation
import Testing

/// The control protocol between `dictactl` and the daemon. One JSON object per line, in each
/// direction — so the two properties worth asserting are that a frame is exactly one line, and that
/// the vocabulary §6 defines survives a round trip without being flattened into strings the daemon
/// then has to re-parse.
@Suite("wire")
struct WireTests {
    // MARK: - the vocabulary

    @Test("every command round-trips", arguments: Command.allCases)
    func commandRoundTrip(command: Command) throws {
        let frame = try Wire.encode(Request(cmd: command))
        #expect(try Wire.decode(Request.self, from: frame).cmd == command)
    }

    @Test("every lifecycle state round-trips", arguments: LifecycleState.allCases)
    func stateRoundTrip(state: LifecycleState) throws {
        let frame = try Wire.encode(Response(kind: .accepted, state: state))
        #expect(try Wire.decode(Response.self, from: frame).state == state)
    }

    @Test("every mode round-trips", arguments: Mode.allCases)
    func modeRoundTrip(mode: Mode) throws {
        let frame = try Wire.encode(Request(cmd: .stop, mode: mode))
        #expect(try Wire.decode(Request.self, from: frame).mode == mode)
    }

    @Test("the five states of §6 are exactly the states on the wire")
    func statesMatchTheSpec() {
        #expect(LifecycleState.allCases.map(\.rawValue) ==
            ["idle", "warming", "recording", "processing", "injecting"])
    }

    @Test("the commands are exactly the verbs dictactl offers")
    func commandsMatchTheClient() {
        #expect(Set(Command.allCases.map(\.rawValue)) ==
            ["status", "toggle", "start", "stop", "abort", "last", "dictate"])
    }

    // MARK: - attempt id and target

    @Test("a request carries the attempt id it names, so a spent id is recognisable as spent")
    func requestCarriesTheAttemptID() throws {
        let request = Request(cmd: .stop, sessionID: "session:7", mode: .raw, attempt: 41)
        let decoded = try Wire.decode(Request.self, from: Wire.encode(request))
        #expect(decoded == request)
        #expect(decoded.attempt == 41)
    }

    @Test("a request omitting the attempt id decodes as naming no attempt")
    func attemptIDIsOptional() throws {
        // The chord cannot know the id — the daemon owns it — so `toggle` names none and the
        // daemon resolves it (D7). "Names no attempt" and "names a spent attempt" are different
        // requests and must not decode to the same value.
        let decoded = try Wire.decode(Request.self, from: Data(#"{"cmd":"toggle"}"#.utf8))
        #expect(decoded.attempt == nil)
    }

    @Test("a response carries the resolved target, both halves of it")
    func responseCarriesTheTarget() throws {
        let target = Target(sessionID: "session:7", pane: .right)
        let response = Response(kind: .accepted, state: .recording, attempt: 3, target: target)
        let decoded = try Wire.decode(Response.self, from: Wire.encode(response))
        #expect(decoded == response)
        #expect(decoded.target?.sessionID == "session:7")
        #expect(decoded.target?.pane == .right)
    }

    @Test("the request names only the session, because the pane is not knowable at keypress")
    func requestHasNoPane() throws {
        // F3/D6: the installed agterm does not export $AGT_PANE, so the pane is resolved by the
        // daemon from the live tree. A request that could carry a pane would invite a caller to
        // guess one, which is D4's forbidden substitution wearing a different hat.
        let json = try #require(String(data: Wire.encode(Request(cmd: .start, sessionID: "s")),
                                      encoding: .utf8))
        #expect(!json.contains("pane"))
    }

    @Test("an unrecognised pane kind is a decode error, so the daemon fails closed")
    func unknownPaneFailsClosed() {
        let json = Data(#"{"sessionID":"s","pane":"floating"}"#.utf8)
        #expect(throws: DecodingError.self) { try Wire.decode(Target.self, from: json) }
    }

    // MARK: - rejection versus no-op (§6)

    @Test("a rejection and a no-op are different values, not one value read two ways")
    func rejectionIsNotANoOp() {
        #expect(CommandOutcome.rejected != CommandOutcome.noop)
        #expect(CommandOutcome.rejected != CommandOutcome.accepted)
    }

    @Test("a rejection is audible and a no-op is silent")
    func audibility() {
        #expect(CommandOutcome.rejected.isAudible)
        #expect(!CommandOutcome.noop.isAudible)
        // Accepted commands are announced by the state's own feedback (Pop/Tink), and only after
        // capture confirms it is running (D13) — never by the response itself.
        #expect(!CommandOutcome.accepted.isAudible)
    }

    @Test("every outcome round-trips", arguments: CommandOutcome.allCases)
    func outcomeRoundTrip(outcome: CommandOutcome) throws {
        let frame = try Wire.encode(Response(kind: outcome, state: .idle))
        #expect(try Wire.decode(Response.self, from: frame).kind == outcome)
    }

    @Test("a response carries the message shown to the user")
    func responseCarriesAMessage() throws {
        let response = Response(kind: .rejected, state: .recording, message: "already recording")
        let decoded = try Wire.decode(Response.self, from: Wire.encode(response))
        #expect(decoded.message == "already recording")
    }

    // MARK: - framing

    @Test("a frame is exactly one line, terminated by exactly one newline")
    func frameIsOneLine() throws {
        // The transport is JSON-lines, so an interior newline would split one frame into two. JSON
        // escapes it — this asserts that the encoder does not undo that.
        let frame = try Wire.encode(Response(kind: .accepted, state: .idle, text: "a\nb\r\nc"))
        #expect(frame.last == 0x0A)
        #expect(frame.filter { $0 == 0x0A }.count == 1)
        #expect(try Wire.decode(Response.self, from: frame).text == "a\nb\r\nc")
    }

    @Test("a frame decodes with or without its trailing newline")
    func trailingNewlineIsOptionalOnDecode() throws {
        let frame = try Wire.encode(Request(cmd: .status))
        let stripped = frame.dropLast()
        #expect(try Wire.decode(Request.self, from: Data(stripped)).cmd == .status)
    }

    @Test("the frame limit is explicit and generous enough for a ten-minute dictation")
    func frameLimitIsExplicit() {
        // Ten minutes of speech is on the order of 10 KB of text; the cap exists to bound what an
        // unresponsive or confused peer can make us buffer, not to constrain dictation.
        #expect(Wire.maxFrameBytes == 64 * 1024)
    }

    @Test("encoding a frame over the limit is refused rather than sent")
    func oversizedFrameRefusedOnEncode() {
        let response = Response(kind: .accepted, state: .idle,
                                text: String(repeating: "x", count: Wire.maxFrameBytes))
        #expect(throws: WireError.self) { try Wire.encode(response) }
    }

    @Test("a frame over the limit is rejected before it is parsed")
    func oversizedFrameRejectedOnDecode() {
        let frame = Data(repeating: 0x78, count: Wire.maxFrameBytes + 1)
        do {
            _ = try Wire.decode(Request.self, from: frame)
            Issue.record("an oversized frame was accepted")
        } catch let error as WireError {
            #expect(error == .frameTooLarge(bytes: Wire.maxFrameBytes + 1,
                                            limit: Wire.maxFrameBytes))
        } catch {
            Issue.record("expected a WireError, got \(error)")
        }
    }

    @Test("a frame exactly at the limit is accepted")
    func frameAtTheLimitIsAccepted() throws {
        // Off-by-one here would be discovered by the longest dictation of someone's day.
        let overhead = try Wire.encode(Request(cmd: .last, sessionID: "")).count
        let padding = Wire.maxFrameBytes - overhead
        let frame = try Wire.encode(Request(cmd: .last,
                                            sessionID: String(repeating: "y", count: padding)))
        #expect(frame.count == Wire.maxFrameBytes)
        #expect(try Wire.decode(Request.self, from: frame).sessionID?.count == padding)
    }

    // MARK: - hostile input

    @Test("an unknown command is a clean decode error rather than a crash")
    func unknownCommandIsADecodeError() {
        let json = Data(#"{"cmd":"selfDestruct"}"#.utf8)
        #expect(throws: DecodingError.self) { try Wire.decode(Request.self, from: json) }
    }

    @Test("an unknown lifecycle state is a clean decode error")
    func unknownStateIsADecodeError() {
        let json = Data(#"{"kind":"accepted","state":"levitating"}"#.utf8)
        #expect(throws: DecodingError.self) { try Wire.decode(Response.self, from: json) }
    }

    @Test("garbage is a clean decode error")
    func garbageIsADecodeError() {
        #expect(throws: (any Error).self) {
            try Wire.decode(Request.self, from: Data("not json at all".utf8))
        }
    }

    @Test("an empty frame is reported as empty rather than as malformed JSON")
    func emptyFrameIsItsOwnError() {
        // A peer that closed the connection sends this; the message the user sees should say the
        // daemon went away, not that its JSON was bad.
        #expect(throws: WireError.emptyFrame) { try Wire.decode(Request.self, from: Data()) }
        #expect(throws: WireError.emptyFrame) {
            try Wire.decode(Request.self, from: Data(" \n".utf8))
        }
    }
}
