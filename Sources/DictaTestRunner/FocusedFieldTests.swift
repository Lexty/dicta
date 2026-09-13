import ApplicationServices
import CoreGraphics
import DictaCore
import DictaRuntime
import Foundation
import Testing

// The seams of focused-field delivery (D31, D32), as far as they can be asserted without another
// application on the screen.
//
// What is asserted here is the half of the system adapters no person has to score: how an
// accessibility error is read, that the one lock really serialises the calls that are not thread
// safe, and what the posted events carry. Whether an application actually accepts them is H24-H27.

@Suite("focused field access")
struct FocusedFieldTests {
    // MARK: - the AXError table

    @Test("an accessibility error is read as no element, definitely different, or cannot tell")
    func theAXErrorTable() {
        // AGENTS.md's rule, for accessibility: only a definite answer may be called gone. An error
        // that could be a slow application or a revoked grant says nothing about the field, and a
        // re-validation that read it as "gone" would report a target the user can still see.
        let table: [(AXError, FocusedFieldError?)] = [
            (.success, nil),
            (.noValue, .noElement),
            (.invalidUIElement, .definitelyDifferent(reason: "invalidUIElement")),
            (.cannotComplete, .cannotTell(reason: "cannotComplete")),
            (.apiDisabled, .cannotTell(reason: "apiDisabled")),
            (.attributeUnsupported, .cannotTell(reason: "attributeUnsupported")),
            (.failure, .cannotTell(reason: "failure")),
            (.illegalArgument, .cannotTell(reason: "illegalArgument")),
            (.notImplemented, .cannotTell(reason: "notImplemented")),
            (.invalidUIElementObserver, .cannotTell(reason: "invalidUIElementObserver")),
            (.actionUnsupported, .cannotTell(reason: "actionUnsupported")),
            (.notificationUnsupported, .cannotTell(reason: "notificationUnsupported")),
            (.notificationAlreadyRegistered, .cannotTell(reason: "notificationAlreadyRegistered")),
            (.notificationNotRegistered, .cannotTell(reason: "notificationNotRegistered")),
            (.parameterizedAttributeUnsupported,
             .cannotTell(reason: "parameterizedAttributeUnsupported")),
            (.notEnoughPrecision, .cannotTell(reason: "notEnoughPrecision")),
        ]
        for (error, expected) in table {
            let read = FocusedFieldError.from(error)
            #expect(read == expected, "\(error.rawValue) read as \(String(describing: read))")
        }
    }

    @Test("every accessibility failure names what could not be read, in the user's words")
    func theFailuresDescribeThemselves() {
        #expect(FocusedFieldError.noElement.description.contains("no focused element"))
        #expect(FocusedFieldError.definitelyDifferent(reason: "invalidUIElement").description
            .contains("invalidUIElement"))
        #expect(FocusedFieldError.cannotTell(reason: "cannotComplete").description
            .contains("cannotComplete"))
    }

    // MARK: - one lock

    @Test("the system adapter's calls are serialised by one lock, whichever call it is")
    func theAdapterSerialisesItsCalls() {
        // `IsSecureEventInputEnabled` is documented "Not thread safe", and the AX calls share the
        // adapter with it, so every call goes through one lock. The probes stand in for the Carbon
        // and AX calls and count how many are inside at once: two threads entering together would
        // be exactly the concurrent call the header forbids.
        let meter = ConcurrencyMeter()
        let access = SystemFocusedFieldAccess(
            isTrusted: { meter.visit() },
            isSecureInputOn: { meter.visit() }
        )
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            if index.isMultiple(of: 2) {
                _ = access.isTrusted
            } else {
                _ = access.isSecureInputOn
            }
        }
        #expect(meter.visits == 64)
        #expect(meter.mostAtOnce == 1)
    }

    // MARK: - identity, never content

    @Test("the adapter can copy only identity attributes, never a field's value or selected text")
    func theAdapterReadsNoContent() throws {
        // Invariant 14's last clause. No person can see an attribute read, so the adapter funnels
        // every copy through one function typed by a closed list, and this holds both halves: the
        // list names no content attribute, and nothing in the sources copies around the funnel.
        typealias Read = SystemFocusedFieldAccess.ReadAttribute
        #expect(Read.allCases.map(\.rawValue) == [kAXFocusedUIElementAttribute,
                                                  "AXManualAccessibility",
                                                  kAXRoleAttribute, kAXSubroleAttribute])
        let content = [kAXValueAttribute, kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute,
                       kAXSelectedTextRangesAttribute, kAXVisibleCharacterRangeAttribute,
                       kAXNumberOfCharactersAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
        #expect(Set(Read.allCases.map(\.rawValue)).isDisjoint(with: content))

        var copies: [String: Int] = [:]
        let sources = BundleTests.repositoryRoot.appendingPathComponent("Sources")
        let files = try FileManager.default.subpathsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") && !$0.hasPrefix("DictaTestRunner/") }
        #expect(files.contains("DictaRuntime/FocusedField.swift"))
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for call in ["AXUIElementCopyAttributeValue(", "AXUIElementCopyAttributeValues(",
                         "AXUIElementCopyMultipleAttributeValues(",
                         "AXUIElementCopyParameterizedAttributeValue("] {
                copies[call, default: 0] += text.components(separatedBy: call).count - 1
            }
        }
        #expect(copies == ["AXUIElementCopyAttributeValue(": 1,
                           "AXUIElementCopyAttributeValues(": 0,
                           "AXUIElementCopyMultipleAttributeValues(": 0,
                           "AXUIElementCopyParameterizedAttributeValue(": 0])
    }

    // MARK: - the events

    @Test("a posted chunk is a key-down and a key-up carrying the string with empty flags")
    func theEventsCarryTheStringAndNoFlags() throws {
        // F11: keycode 0 is not reinterpreted under the Russian layout, and empty flags hold
        // against a physically held modifier -- so a right Command still down cannot turn a
        // chunk into a shortcut. Built and read back here, never posted.
        let text = "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} (world) \u{1F44B}"
        let events = try #require(SystemEventPoster.keystrokes(for: text))
        #expect(events.count == 2)
        #expect(events.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [0, 0])
        #expect(events.map(\.type) == [.keyDown, .keyUp])
        for event in events {
            #expect(event.flags == [])
            #expect(Self.unicode(of: event) == text)
        }
    }

    @Test("a chunk at the hard event limit is carried whole")
    func theHardLimitIsCarriedWhole() throws {
        // `maxEventUTF16` is 200 (F11, VS Code). The event must not be where a chunk the planner
        // allowed is truncated.
        let text = String(repeating: "ab", count: KeystrokeChunks.standard.maxEventUTF16 / 2)
        let events = try #require(SystemEventPoster.keystrokes(for: text))
        #expect(events.allSatisfy { Self.unicode(of: $0) == text })
    }

    static func unicode(of event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 512)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length,
                                       unicodeString: &buffer)
        return String(utf16CodeUnits: buffer, count: length)
    }

    // MARK: - pacing

    @Test("the thread pacer waits, and a zero or negative pause costs nothing")
    func theThreadPacerWaits() {
        let pacer = ThreadPacer()
        let started = Date()
        pacer.pause(0)
        pacer.pause(-1)
        #expect(Date().timeIntervalSince(started) < 0.05)
        pacer.pause(0.02)
        #expect(Date().timeIntervalSince(started) >= 0.02)
    }
}

/// Counts how many callers are inside at once.
final class ConcurrencyMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var inside = 0
    private var most = 0
    private var count = 0

    var visits: Int { lock.withLock { count } }
    var mostAtOnce: Int { lock.withLock { most } }

    func visit() -> Bool {
        lock.withLock {
            inside += 1
            count += 1
            most = max(most, inside)
        }
        // Long enough that two unserialised callers overlap on any machine.
        Thread.sleep(forTimeInterval: 0.002)
        lock.withLock { inside -= 1 }
        return false
    }
}

// MARK: - delivery (D32)

/// `FocusedFieldInjector` against fakes: what is posted, in what order, and which of §7's three
/// failures each way of going wrong becomes. Whether an application accepts what is posted is
/// H24-H27; everything that decides WHETHER to post is here.
@Suite("focused field delivery")
struct FocusedFieldDeliveryTests {
    /// The field every delivery here is aimed at, frontmost under the fake's default pid.
    static let field = FieldTarget(bundleID: "com.microsoft.VSCode", appName: "Code",
                                   pid: FakeFrontmost.defaultPID)
    static let other = FrontmostFacts(bundleID: "com.apple.Safari", pid: 777, name: "Safari")
    /// Sixty units of ASCII, three chunks at the standard target of twenty.
    static let text = String(repeating: "dicta types. ", count: 5).prefix(60).description

    /// One delivery's world, every seam faked.
    final class Rig: @unchecked Sendable {
        let clock = FakeClock()
        let access = FakeFocusedFieldAccess()
        let poster = FakeEventPoster()
        let frontmost = FakeFrontmost(bundleIdentifier: "com.microsoft.VSCode")
        let pacer: FakePacer

        init() {
            pacer = FakePacer(clock: clock)
        }

        func injector(chunks: KeystrokeChunks = .standard, pause: TimeInterval = 0.002,
                      deadline: TimeInterval = FocusedFieldInjector.deliveryDeadline,
                      now: (@Sendable () -> TimeInterval)? = nil) -> FocusedFieldInjector {
            let clock = clock
            return FocusedFieldInjector(access: access, poster: poster, frontmost: frontmost,
                                        pacer: pacer, chunks: chunks, pause: pause,
                                        deadline: deadline,
                                        now: now ?? { clock.now.timeIntervalSince1970 })
        }

        /// The handle the attempt captured at the start: the fake's standing element.
        var handle: FieldHandle { FakeFocusedFieldAccess.textArea().handle }

        func deliver(_ text: String = FocusedFieldDeliveryTests.text,
                     with injector: FocusedFieldInjector? = nil) -> DeliveryFailure? {
            do {
                try (injector ?? self.injector())
                    .inject(text, into: FocusedFieldDeliveryTests.field, handle: handle)
                return nil
            } catch let failure as DeliveryFailure {
                return failure
            } catch {
                Issue.record("not a DeliveryFailure: \(error)")
                return nil
            }
        }
    }

    static func kind(_ failure: DeliveryFailure?) -> String {
        switch failure {
        case nil: "delivered"
        case .targetGone: "targetGone"
        case .notStarted: "notStarted"
        case .mayBePartial: "mayBePartial"
        }
    }

    // MARK: the happy path, and the order

    @Test("the chunks posted to the captured pid concatenate to final, paced through the pacer")
    func theHappyPathPostsFinalToThePid() throws {
        let rig = Rig()

        #expect(rig.deliver() == nil)

        let posts = rig.poster.posts
        #expect(posts.map(\.unicode) == ["dicta types. dicta t", "ypes. dicta types. d",
                                         "icta types. dicta ty"])
        #expect(posts.map(\.unicode).joined() == Self.text)
        #expect(posts.allSatisfy { $0.pid == Self.field.pid })
        // Between chunks and never before the first: two pauses for three chunks.
        #expect(rig.pacer.pauses == [0.002, 0.002])
        // Every chunk, built the way the system poster builds it, carries no modifier (F11).
        for post in posts {
            let events = try #require(SystemEventPoster.keystrokes(for: post.unicode))
            #expect(events.allSatisfy { $0.flags == [] })
        }
    }

    @Test("planning comes before the final validation, and nothing but posting follows it")
    func theValidationIsTheLastThingBeforeTheEvents() throws {
        let rig = Rig()
        let world = OrderedWorld(rig)

        #expect(rig.deliver(with: world.injector) == nil)

        // D32's order exactly: the deadline read once when the delivery is handed the text, then
        // deadline, pid, element, sameness, Secure Input, grant, then deadline and pid AGAIN once
        // the accessibility calls have returned -- and after that only posts, each later one
        // behind a pause and its own deadline and pid check.
        #expect(world.log == [
            "now",
            "now", "frontmost", "focusedElement", "isSame", "isSecureInputOn", "isTrusted",
            "now", "frontmost",
            "post",
            "pause", "now", "frontmost", "post",
            "pause", "now", "frontmost", "post",
        ])

        // And the plan is made BEFORE any of it: a text the plan refuses reaches no check at all.
        let refused = OrderedWorld(Rig())
        let over = refused.injector(chunks: try #require(
            KeystrokeChunks(targetUTF16: 20, maxEventUTF16: 20, maxChunks: 2)))
        #expect(Self.kind(refused.rig.deliver(with: over)) == "notStarted")
        #expect(refused.log == ["now"])
    }

    // MARK: before the first event

    enum DefiniteChange: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case differentElement
        case noElement
        case elementGone
        case differentFrontmost

        var testDescription: String { rawValue }
    }

    @Test("a definite change before delivery is target-gone with zero events",
          arguments: DefiniteChange.allCases)
    func aDefiniteChangeIsTargetGone(_ change: DefiniteChange) {
        let rig = Rig()
        switch change {
        case .differentElement:
            rig.access.answer(.success(FakeFocusedFieldAccess.textArea(token: 2)))
        case .noElement:
            rig.access.answer(.failure(.noElement))
        case .elementGone:
            rig.access.answer(.failure(.definitelyDifferent(reason: "invalidUIElement")))
        case .differentFrontmost:
            rig.frontmost.activate(Self.other)
        }

        let failure = rig.deliver()

        #expect(Self.kind(failure) == "targetGone")
        #expect(failure?.target == .focusedField(Self.field))
        #expect(rig.poster.posts.isEmpty)
    }

    @Test("the same element no longer eligible on fresh metadata is not-started with zero events",
          arguments: [
              FieldFacts(role: "AXTextArea", subrole: nil, valueSettable: false,
                         hasSelectedTextRange: true),
              FieldFacts(role: "AXTextField", subrole: "AXSecureTextField", valueSettable: true,
                         hasSelectedTextRange: true),
              FieldFacts(role: nil, subrole: nil, valueSettable: nil, hasSelectedTextRange: nil),
          ])
    func aChangedEligibilityIsNotStarted(_ facts: FieldFacts) {
        let rig = Rig()
        // The SAME handle: the element is still focused, and has stopped being a text field.
        rig.access.answer(.success(FocusedElement(handle: FieldHandle(token: 1), facts: facts)))

        #expect(Self.kind(rig.deliver()) == "notStarted")
        #expect(rig.poster.posts.isEmpty)
    }

    @Test("a deadline already passed before the first event is not-started, not may-be-partial")
    func aDeadlinePassedBeforeTheFirstEventIsNotStarted() {
        let rig = Rig()
        // A clock that moves two seconds per reading against a one-second deadline: the first
        // check after the plan is already late.
        let stepping = SteppingClock(step: 2)

        let failure = rig.deliver(with: rig.injector(deadline: 1, now: { stepping.read() }))

        #expect(Self.kind(failure) == "notStarted")
        #expect(failure?.description.contains("deadline") == true)
        #expect(rig.poster.posts.isEmpty)
        // Refused on the deadline, before any accessibility call was spent.
        #expect(rig.access.callLog.isEmpty)
    }

    @Test("an accessibility read that succeeds past the deadline posts nothing, as not-started")
    func aLateReadPastTheDeadlineIsNotStarted() {
        let rig = Rig()
        let clock = rig.clock
        rig.access.duringRead { clock.advance(by: FocusedFieldInjector.deliveryDeadline + 1) }

        let failure = rig.deliver()

        #expect(Self.kind(failure) == "notStarted")
        #expect(failure?.description.contains("deadline") == true)
        #expect(rig.poster.posts.isEmpty)
    }

    @Test("an accessibility read that succeeds while the frontmost app changes is target-gone")
    func aLateReadAfterAnAppSwitchIsTargetGone() {
        let rig = Rig()
        let frontmost = rig.frontmost
        rig.access.duringRead { frontmost.activate(Self.other) }

        let failure = rig.deliver()

        #expect(Self.kind(failure) == "targetGone")
        #expect(failure?.description.contains("Safari") == true)
        #expect(rig.poster.posts.isEmpty)
    }

    @Test("accessibility that cannot answer at re-validation is not-started with zero events")
    func anUnansweredReadIsNotStarted() {
        let rig = Rig()
        rig.access.answer(.failure(.cannotTell(reason: "cannotComplete")))

        let failure = rig.deliver()

        // Never target-gone: a timeout says nothing about the field (AGENTS.md).
        #expect(Self.kind(failure) == "notStarted")
        #expect(failure?.description.contains("cannotComplete") == true)
        #expect(rig.poster.posts.isEmpty)
    }

    @Test("a revoked grant or Secure Input at re-validation is not-started with zero events",
          arguments: ["grant", "secureInput"])
    func aLostGrantOrSecureInputIsNotStarted(_ cause: String) {
        let rig = Rig()
        if cause == "grant" {
            rig.access.setTrusted(false)
        } else {
            rig.access.setSecureInput(true)
        }

        #expect(Self.kind(rig.deliver()) == "notStarted")
        #expect(rig.poster.posts.isEmpty)
    }

    @Test("nothing frontmost at re-validation is not-started, because it names no other app")
    func nothingFrontmostIsNotStarted() {
        let rig = Rig()
        rig.frontmost.activate(nil)

        #expect(Self.kind(rig.deliver()) == "notStarted")
        #expect(rig.poster.posts.isEmpty)
    }

    // MARK: part-way

    @Test("the frontmost app changing after chunk k stops as may-be-partial with exactly k chunks",
          arguments: [1, 2])
    func anAppSwitchMidDeliveryIsPartial(_ k: Int) {
        let rig = Rig()
        let frontmost = rig.frontmost
        rig.poster.afterPost { if $0 == k { frontmost.activate(Self.other) } }

        let failure = rig.deliver()

        #expect(Self.kind(failure) == "mayBePartial")
        #expect(failure?.description.contains("after \(k) of 3 chunks") == true)
        // Exactly k, and never retried: the rest is not posted to Safari, nor again to Code.
        #expect(rig.poster.posts.count == k)
        #expect(rig.poster.posts.allSatisfy { $0.pid == Self.field.pid })
    }

    @Test("nothing frontmost after chunk k stops as may-be-partial with exactly k chunks")
    func nothingFrontmostMidDeliveryIsPartial() {
        // Not a definite switch, but posting on into an unknown frontmost is D4's substitution.
        let rig = Rig()
        let frontmost = rig.frontmost
        rig.poster.afterPost { if $0 == 1 { frontmost.activate(nil) } }

        let failure = rig.deliver()

        #expect(Self.kind(failure) == "mayBePartial")
        #expect(rig.poster.posts.count == 1)
    }

    @Test("the deadline passing after chunk k stops as may-be-partial with exactly k chunks",
          arguments: [1, 2])
    func aDeadlineMidDeliveryIsPartial(_ k: Int) {
        let rig = Rig()
        let clock = rig.clock
        rig.poster.afterPost {
            if $0 == k { clock.advance(by: FocusedFieldInjector.deliveryDeadline) }
        }

        let failure = rig.deliver()

        #expect(Self.kind(failure) == "mayBePartial")
        #expect(failure?.description.contains("deadline") == true)
        #expect(rig.poster.posts.count == k)
    }

    @Test("the pacing counts against the deadline")
    func thePacingCountsAgainstTheDeadline() {
        let rig = Rig()

        // Three chunks, a second between them, a deadline of one and a half: the second pause
        // takes the delivery past it, so two chunks went in.
        let failure = rig.deliver(with: rig.injector(pause: 1, deadline: 1.5))

        #expect(Self.kind(failure) == "mayBePartial")
        #expect(rig.poster.posts.count == 2)
    }

    @Test("events that cannot be built are not-started first, and may-be-partial after a chunk")
    func anUnbuildableChunkIsClassifiedByPosition() {
        let first = Rig()
        first.poster.setError(EventPostFailure(pid: Self.field.pid))
        #expect(Self.kind(first.deliver()) == "notStarted")

        let later = Rig()
        let poster = later.poster
        later.poster.afterPost { if $0 == 1 { poster.setError(EventPostFailure(pid: 1)) } }
        #expect(Self.kind(later.deliver()) == "mayBePartial")
        #expect(later.poster.posts.count == 1)
    }

    // MARK: the bound

    @Test("a plan over either hard limit is not-started with zero events and no check made",
          arguments: ["tooManyChunks", "graphemeTooLong"])
    func aPlanOverTheBoundIsNotStarted(_ rejection: String) throws {
        let rig = Rig()
        let chunks = try #require(KeystrokeChunks(targetUTF16: 2, maxEventUTF16: 4, maxChunks: 3))
        let text = rejection == "tooManyChunks"
            ? "abcdefg"
            : "a" + String(repeating: "\u{0301}", count: 4)

        let failure = rig.deliver(text, with: rig.injector(chunks: chunks))

        #expect(Self.kind(failure) == "notStarted")
        #expect(failure?.description.contains("nothing was inserted") == true)
        #expect(rig.poster.posts.isEmpty)
        #expect(rig.access.callLog.isEmpty)
        #expect(rig.frontmost.reads == 0)
    }
}

/// A clock that moves a fixed step on every reading.
final class SteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 0
    private let step: TimeInterval

    init(step: TimeInterval) { self.step = step }

    func read() -> TimeInterval {
        lock.withLock {
            defer { current += step }
            return current
        }
    }
}

/// Every seam of a delivery, logged into ONE sequence, so the order between an accessibility call,
/// a frontmost read, a deadline read and a post can be asserted rather than inferred.
final class OrderedWorld: FocusedFieldAccess, EventPoster, FrontmostApplication, Pacer,
    @unchecked Sendable {
    let rig: FocusedFieldDeliveryTests.Rig
    private let lock = NSLock()
    private var entries: [String] = []

    init(_ rig: FocusedFieldDeliveryTests.Rig) { self.rig = rig }

    var log: [String] { lock.withLock { entries } }

    private func note(_ entry: String) { lock.withLock { entries.append(entry) } }

    var injector: FocusedFieldInjector { injector(chunks: .standard) }

    func injector(chunks: KeystrokeChunks) -> FocusedFieldInjector {
        let clock = rig.clock
        return FocusedFieldInjector(access: self, poster: self, frontmost: self, pacer: self,
                                    chunks: chunks, pause: 0, now: { [self] in
                                        note("now")
                                        return clock.now.timeIntervalSince1970
                                    })
    }

    var isTrusted: Bool {
        note("isTrusted")
        return rig.access.isTrusted
    }

    var isSecureInputOn: Bool {
        note("isSecureInputOn")
        return rig.access.isSecureInputOn
    }

    func focusedElement(expectedPID: Int32) throws -> FocusedElement {
        note("focusedElement")
        return try rig.access.focusedElement(expectedPID: expectedPID)
    }

    func isSame(_ handle: FieldHandle, as other: FieldHandle) -> Bool {
        note("isSame")
        return rig.access.isSame(handle, as: other)
    }

    func post(unicode: String, toPID pid: Int32) throws {
        note("post")
        try rig.poster.post(unicode: unicode, toPID: pid)
    }

    var current: FrontmostFacts? {
        note("frontmost")
        return rig.frontmost.current
    }

    func pause(_ seconds: TimeInterval) {
        note("pause")
        rig.pacer.pause(seconds)
    }
}
