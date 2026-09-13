import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import DictaCore
import Foundation

// The focused text field of another application as a target (D31), and Unicode keystrokes posted to
// its process as the delivery (D32): the seams, and the adapters over the real APIs.
//
// Nothing in this file may be constructed while `--focused-fields` is off. Posting into another
// process needs the Accessibility grant, and D5's promise is now "no permission unless you ask for
// this" -- so with the option off the daemon makes no AX call and posts no event, and the wiring
// constructs none of these (invariant 14).
//
// Identity, never content. The adapter reads an element's role, subrole, whether its value is
// settable and which attribute names it has. It never reads the value, the selected text or the
// selected range, and there is no method here that could return one.

// MARK: - the seams

/// A focused element, parked in the daemon beside its attempt and never sent anywhere (§5).
///
/// Opaque on purpose. In production it holds an `AXUIElement`, which `DictaCore` must never see;
/// a fake holds a token, and only the adapter that made a handle can say whether two are the same.
public struct FieldHandle: @unchecked Sendable {
    let element: AXUIElement?
    /// What a fake compares. `nil` for a handle the system adapter made.
    public let token: Int?

    /// A handle for a fake to hand out.
    public init(token: Int) {
        element = nil
        self.token = token
    }

    init(element: AXUIElement) {
        self.element = element
        token = nil
    }
}

/// What one focused-element read found: the handle to re-validate against later, and the metadata
/// eligibility is decided on (`FieldEligibility`).
public struct FocusedElement: Sendable {
    public var handle: FieldHandle
    public var facts: FieldFacts

    public init(handle: FieldHandle, facts: FieldFacts) {
        self.handle = handle
        self.facts = facts
    }
}

/// Why a focused element could not be had, in the three kinds a caller must tell apart.
///
/// AGENTS.md's rule reaches accessibility too: only a definite answer may be called gone. A
/// timeout, a revoked grant or an attribute an application does not support says nothing about the
/// field, and a re-validation that read one of them as "gone" would tell the user a field they can
/// still see had vanished.
public enum FocusedFieldError: Error, Equatable, CustomStringConvertible {
    /// The application answered, and it has no focused element to give.
    case noElement
    /// Accessibility answered definitely, and the answer is not the element asked about: it no
    /// longer exists, or it belongs to another process.
    case definitelyDifferent(reason: String)
    /// No answer that says anything about the field.
    case cannotTell(reason: String)

    /// The table, for every `AXError`; `nil` for success.
    public static func from(_ error: AXError) -> FocusedFieldError? {
        switch error {
        case .success: nil
        // For `kAXFocusedUIElementAttribute` this is the application saying nothing is focused, and
        // it is also what Electron answers until `AXManualAccessibility` is set (F11).
        case .noValue: .noElement
        // The element, or its whole application, is gone. The one error that is a statement.
        case .invalidUIElement: .definitelyDifferent(reason: name(of: error))
        // `cannotComplete` is a timeout or a busy application, `apiDisabled` a revoked grant (F11),
        // and the rest are an API that did not answer the question asked.
        default: .cannotTell(reason: name(of: error))
        }
    }

    public var description: String {
        switch self {
        case .noElement: "the application has no focused element"
        case let .definitelyDifferent(reason): "the focused field is gone (\(reason))"
        case let .cannotTell(reason): "accessibility could not read the focused field (\(reason))"
        }
    }

    static func name(of error: AXError) -> String {
        switch error {
        case .success: "success"
        case .failure: "failure"
        case .illegalArgument: "illegalArgument"
        case .invalidUIElement: "invalidUIElement"
        case .invalidUIElementObserver: "invalidUIElementObserver"
        case .cannotComplete: "cannotComplete"
        case .attributeUnsupported: "attributeUnsupported"
        case .actionUnsupported: "actionUnsupported"
        case .notificationUnsupported: "notificationUnsupported"
        case .notImplemented: "notImplemented"
        case .notificationAlreadyRegistered: "notificationAlreadyRegistered"
        case .notificationNotRegistered: "notificationNotRegistered"
        case .apiDisabled: "apiDisabled"
        case .noValue: "noValue"
        case .parameterizedAttributeUnsupported: "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: "notEnoughPrecision"
        @unknown default: "AXError \(error.rawValue)"
        }
    }
}

/// Accessibility, as far as the focused-field path needs it.
///
/// There is deliberately no frontmost pid here. The frontmost fact comes only from the shared,
/// observer-backed `FrontmostApplication`; a second source read without an observer is F8a's frozen
/// value again.
public protocol FocusedFieldAccess: Sendable {
    /// Whether this process holds the Accessibility grant. F11: the only check that follows a grant
    /// and a revocation live; without it, posted events are discarded with no error.
    var isTrusted: Bool { get }
    /// Whether ANY process has Secure Input on. System-wide, so a reason to refuse and never a
    /// password-field detector.
    var isSecureInputOn: Bool { get }
    /// The focused element of the application `expectedPID`, with its metadata. Throws
    /// `FocusedFieldError`; an element owned by another pid is `definitelyDifferent`.
    func focusedElement(expectedPID: Int32) throws -> FocusedElement
    /// Whether two handles are the same element (`CFEqual`).
    func isSame(_ handle: FieldHandle, as other: FieldHandle) -> Bool
}

/// Delivery into a focused field (D32): **final**, the field the attempt was started for, and the
/// element the daemon captured for it before the microphone opened.
///
/// A seam of its own rather than `Injector`, because the handle has to reach it and `Target`
/// cannot carry one -- `Target` is `DictaCore`, and the element is ApplicationServices. The daemon
/// owns the handle by attempt id and hands over exactly that attempt's. Throws `DeliveryFailure`,
/// aimed at `.focusedField(target)`, in §7's three kinds; like `Injector`, it re-validates and
/// never retries.
public protocol FieldInjector: Sendable {
    func inject(_ text: String, into target: FieldTarget, handle: FieldHandle) throws
}

/// Posting one chunk into a process.
public protocol EventPoster: Sendable {
    /// A key-down and a key-up carrying `unicode`, posted to `pid`. Throws only when the events
    /// could not even be built; a posted event has no error channel (§7).
    func post(unicode: String, toPID pid: Int32) throws
}

/// The pause between chunks. Synchronous, and its own seam rather than `Clock.schedule`, which
/// starts a real thread per item: delivery runs inline under the handler lock and waits in line.
public protocol Pacer: Sendable {
    func pause(_ seconds: TimeInterval)
}

// MARK: - the system adapters

/// Accessibility and Secure Input, every call serialised by one private lock.
///
/// `IsSecureEventInputEnabled` is documented "Not thread safe" (`CarbonEventsCore.h`), and the AX
/// calls share the adapter with it, so one lock covers all of them. No call is made on the poll
/// thread and none hops to the main run loop, which the workspace observer needs and a hop could
/// deadlock. F11 checked that the Carbon call answers from a background thread as it does on main.
public final class SystemFocusedFieldAccess: FocusedFieldAccess, @unchecked Sendable {
    /// F11's slowest successful read was 44 ms; no hung application was measured.
    public static let messagingTimeout: Float = 0.25
    /// How long Electron is given to build its tree after `AXManualAccessibility` is set, before
    /// the one re-read. NOT MEASURED: F11 saw an element after setting the attribute but did not
    /// time it. Too short costs one refused first dictation per application launch, because the
    /// next attempt finds the attribute already set and its tree built.
    public static let manualAccessibilitySettle: TimeInterval = 0.25
    /// The accessibility messages ONE `focusedElement` read can send, counted off the code below:
    /// the focused element, `AXManualAccessibility` read and set, the focused element again, the
    /// owner's pid, then settability, attribute names, role and subrole. Each is bounded by
    /// `messagingTimeout`, the settle is added once, and `FocusedFieldInjector.worstCaseSeconds`
    /// is built on the sum. `CFEqual`, the trust check and Secure Input send no message.
    public static let worstCaseMessagesPerRead = 9

    /// The longest one focused-element read can take.
    public static var worstCaseReadSeconds: TimeInterval {
        Double(worstCaseMessagesPerRead) * Double(messagingTimeout) + manualAccessibilitySettle
    }

    /// Every attribute whose value this adapter copies, and there is no other way for it to copy
    /// one: `copy(_:of:into:)` takes this type and is the process's only
    /// `AXUIElementCopyAttributeValue`.
    /// Invariant 14's "never reads a field's value or selected text" is therefore a list that has
    /// no such case in it, which a test can hold, rather than a promise about every call site.
    /// Settability and the attribute names are metadata calls of their own and return no content.
    public enum ReadAttribute: String, CaseIterable, Sendable {
        /// `kAXFocusedUIElementAttribute`, read from the application element.
        case focusedElement = "AXFocusedUIElement"
        /// The attribute Chromium watches to switch its accessibility tree on for a client that is
        /// not a screen reader.
        case manualAccessibility = "AXManualAccessibility"
        /// `kAXRoleAttribute`.
        case role = "AXRole"
        /// `kAXSubroleAttribute`.
        case subrole = "AXSubrole"
    }

    private let lock = NSLock()
    private let trustProbe: @Sendable () -> Bool
    private let secureInputProbe: @Sendable () -> Bool

    /// Sets the messaging timeout once, process-globally, on the system-wide element: its
    /// focused-element read fails in every application (F11), so the timeout is the only thing it
    /// is used for. `AXUIElement.h` says a timeout set on one element does not carry over to
    /// `CFEqual` instances, so no per-element timeout is relied on anywhere.
    ///
    /// The probes stand in for the trust and Secure Input calls in tests, which is how the lock is
    /// asserted without a second thread reaching Carbon.
    public init(isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
                isSecureInputOn: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() }) {
        trustProbe = isTrusted
        secureInputProbe = isSecureInputOn
        // The constants and nothing else: `worstCaseReadSeconds` is built from them, and the
        // client's timeout ceiling is checked against that.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.messagingTimeout)
    }

    public var isTrusted: Bool { lock.withLock { trustProbe() } }

    /// Shows the system's Accessibility dialog and adds this bundle to the list, when the grant is
    /// not already held. F11 found this the only call that does either: `AXIsProcessTrusted`, the
    /// check every hold makes, neither asks nor lists, so without this the user would have to find
    /// the bundle and add it by hand. The key is spelled out rather than read from
    /// `kAXTrustedCheckOptionPrompt`, a C global Swift 6 will not read outside the main actor.
    public static func requestTrust() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    public var isSecureInputOn: Bool { lock.withLock { secureInputProbe() } }

    public func focusedElement(expectedPID: Int32) throws -> FocusedElement {
        try lock.withLock { try readFocusedElement(expectedPID: expectedPID) }
    }

    public func isSame(_ handle: FieldHandle, as other: FieldHandle) -> Bool {
        lock.withLock {
            guard let one = handle.element, let two = other.element else { return false }
            return CFEqual(one, two)
        }
    }

    // MARK: under the lock

    private func readFocusedElement(expectedPID: Int32) throws -> FocusedElement {
        // Through the application element of the expected pid, never the system-wide one (F11).
        let application = AXUIElementCreateApplication(expectedPID)
        let element: AXUIElement
        do {
            element = try focused(in: application)
        } catch FocusedFieldError.noElement {
            // Electron answers `noValue` until its tree is switched on (F11). Switched on once per
            // application process -- the attribute stays set for that process's life, which D31
            // states as a side effect -- and read again once.
            guard switchOnManualAccessibility(application) else {
                throw FocusedFieldError.noElement
            }
            Thread.sleep(forTimeInterval: Self.manualAccessibilitySettle)
            element = try focused(in: application)
        }

        var owner: pid_t = 0
        if let failure = FocusedFieldError.from(AXUIElementGetPid(element, &owner)) {
            throw failure
        }
        guard owner == expectedPID else {
            throw FocusedFieldError.definitelyDifferent(
                reason: "the focused element belongs to pid \(owner), not \(expectedPID)")
        }
        return FocusedElement(handle: FieldHandle(element: element), facts: facts(of: element))
    }

    private func focused(in application: AXUIElement) throws -> AXUIElement {
        var value: CFTypeRef?
        let status = copy(.focusedElement, of: application, into: &value)
        if let failure = FocusedFieldError.from(status) { throw failure }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw FocusedFieldError.cannotTell(reason: "the focused element is not an element")
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    /// `false` when the attribute is already on -- `noValue` then means nothing is focused -- or
    /// when the application refuses it, in which case a re-read could not change the answer.
    ///
    /// Read before it is set rather than remembered by pid, so "once per application process" holds
    /// for a pid the system has since reused.
    private func switchOnManualAccessibility(_ application: AXUIElement) -> Bool {
        var current: CFTypeRef?
        if copy(.manualAccessibility, of: application, into: &current) == .success,
           let current, CFGetTypeID(current) == CFBooleanGetTypeID(),
           CFBooleanGetValue(unsafeDowncast(current, to: CFBoolean.self)) {
            return false
        }
        return AXUIElementSetAttributeValue(
            application, ReadAttribute.manualAccessibility.rawValue as CFString, kCFBooleanTrue
        ) == .success
    }

    /// Metadata only. A failed read is `nil`, never a guess: `FieldEligibility` refuses what it
    /// cannot classify.
    private func facts(of element: AXUIElement) -> FieldFacts {
        var settable = DarwinBoolean(false)
        let settableStatus = AXUIElementIsAttributeSettable(
            element, kAXValueAttribute as CFString, &settable)
        var names: CFArray?
        let namesStatus = AXUIElementCopyAttributeNames(element, &names)
        let attributeNames = namesStatus == .success ? names as? [String] : nil
        return FieldFacts(
            role: string(.role, of: element),
            subrole: string(.subrole, of: element),
            valueSettable: settableStatus == .success ? settable.boolValue : nil,
            // From the list of attribute NAMES: reading the range itself would be reading content.
            hasSelectedTextRange: attributeNames?.contains(kAXSelectedTextRangeAttribute)
        )
    }

    private func string(_ attribute: ReadAttribute, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard copy(attribute, of: element, into: &value) == .success else { return nil }
        return value as? String
    }

    /// The one attribute read, for the attributes `ReadAttribute` lists and no others.
    private func copy(_ attribute: ReadAttribute, of element: AXUIElement,
                      into value: inout CFTypeRef?) -> AXError {
        AXUIElementCopyAttributeValue(element, attribute.rawValue as CFString, &value)
    }
}

/// Unicode keystrokes to one process (D32).
public struct SystemEventPoster: EventPoster {
    public init() {}

    /// The key-down and key-up for one chunk, built and not posted.
    ///
    /// Keycode 0 carrying the string, which F11 found is not reinterpreted under the Russian
    /// layout; flags set to empty on both, so a modifier the user is still physically holding --
    /// the right Command that started the dictation among them -- cannot turn a chunk into a
    /// shortcut (F11); a `.privateState` source, so this process's own event state stays out of it.
    public static func keystrokes(for unicode: String) -> [CGEvent]? {
        guard let source = CGEventSource(stateID: .privateState) else { return nil }
        let units = Array(unicode.utf16)
        var events: [CGEvent] = []
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
            else { return nil }
            event.flags = []
            units.withUnsafeBufferPointer {
                event.keyboardSetUnicodeString(stringLength: $0.count,
                                               unicodeString: $0.baseAddress)
            }
            events.append(event)
        }
        return events
    }

    /// `postToPid`, never the HID tap. The tap delivers to whatever is frontmost when the event is
    /// processed; the pid pins the process (D4, D32).
    public func post(unicode: String, toPID pid: Int32) throws {
        guard let events = Self.keystrokes(for: unicode) else {
            throw EventPostFailure(pid: pid)
        }
        for event in events {
            event.postToPid(pid)
        }
    }
}

/// The events for a chunk could not be built, so nothing of it was posted.
public struct EventPostFailure: Error, Equatable, CustomStringConvertible {
    public var pid: Int32

    public init(pid: Int32) {
        self.pid = pid
    }

    public var description: String { "the keystrokes for pid \(pid) could not be built" }
}

/// The production pacer.
public struct ThreadPacer: Pacer {
    public init() {}

    public func pause(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        Thread.sleep(forTimeInterval: seconds)
    }
}

// MARK: - delivery

/// Delivery into a focused field (D32): plan and bound, re-validate, then post, stopping part-way
/// rather than ever re-aiming.
///
/// The order is the design, and each step's position is there for a reason:
///   1. **Plan first.** `KeystrokeChunks` is bounded but not free, and nothing slow may sit between
///      the last validation and the first event. A plan over either hard limit is refused here,
///      before a single accessibility call, as `notStarted`: **final** stays in the record.
///   2. **Validate, in SPEC's order**: the deadline, the frontmost pid, the focused element read
///      fresh and compared with the captured one, its eligibility re-classified from that fresh
///      read, Secure Input, the grant. Then the deadline and the pid AGAIN, because an
///      accessibility read can return after either has moved.
///   3. **Post**, checking the frontmost pid and the deadline before every chunk after the first.
///      Either failing is `mayBePartial`, and nothing is ever retried (§7).
///
/// Only a definite answer is called gone: a different element, no element at all, or a different
/// frontmost pid. A timeout, an error, a lost grant, Secure Input and ineligible or unknown
/// metadata say nothing about the field and are `notStarted`.
///
/// What it cannot see is stated in D4 and §7 rather than hidden: the pid pins the process, not the
/// element, so focus moving inside the same application during delivery is not detected.
public struct FocusedFieldInjector: FieldInjector {
    /// How long one delivery may run before it stops itself, measured from the moment it is handed
    /// the text. F11 posted 108 events in 22 ms, so the largest plan `KeystrokeChunks.standard`
    /// allows is about a second of posting; this is ten times that, and far under
    /// `ControlTimeouts.pipelineRead`, which `daemonCeilingsFitTheClientTimeout` asserts through
    /// `worstCaseSeconds`. D20 refuses an abort once delivery has begun, so this is the only thing
    /// that can end a delivery that runs long.
    public static let deliveryDeadline: TimeInterval = 10
    /// The pause between chunks. F11: no application measured needed a gap for correctness.
    public static let chunkPause: TimeInterval = 0
    /// The allowance for posting one chunk -- two events to the window server -- and reading the
    /// frontmost pid before it. NOT a measurement of one event: F11's 22 ms for 108 events is
    /// 0.2 ms each, and this is fifty times that.
    public static let perChunkAllowance: TimeInterval = 0.01

    /// The longest `inject` can take, from the enforced bounds rather than from the text.
    ///
    /// The deadline bounds everything up to the final checks. Past it, at most one validation read
    /// can still be running (it began just before the deadline, and is bounded by the messaging
    /// timeout on every call it makes), and at most one pause and one chunk follow the last check
    /// that passed.
    public static var worstCaseSeconds: TimeInterval {
        deliveryDeadline + SystemFocusedFieldAccess.worstCaseReadSeconds + chunkPause
            + perChunkAllowance
    }

    private let access: any FocusedFieldAccess
    private let poster: any EventPoster
    private let frontmost: any FrontmostApplication
    private let pacer: any Pacer
    private let chunks: KeystrokeChunks
    private let pause: TimeInterval
    private let deadline: TimeInterval
    private let now: @Sendable () -> TimeInterval

    /// `frontmost` must be the one observer-backed source the trigger shares (F8a). `now` is
    /// monotonic in production -- the system uptime -- so a wall-clock change cannot move the
    /// deadline; a test hands in its fake clock.
    public init(access: any FocusedFieldAccess,
                poster: any EventPoster = SystemEventPoster(),
                frontmost: any FrontmostApplication,
                pacer: any Pacer = ThreadPacer(),
                chunks: KeystrokeChunks = .standard,
                pause: TimeInterval = FocusedFieldInjector.chunkPause,
                deadline: TimeInterval = FocusedFieldInjector.deliveryDeadline,
                now: @escaping @Sendable () -> TimeInterval
                    = { ProcessInfo.processInfo.systemUptime }) {
        self.access = access
        self.poster = poster
        self.frontmost = frontmost
        self.pacer = pacer
        self.chunks = chunks
        self.pause = pause
        self.deadline = deadline
        self.now = now
    }

    public func inject(_ text: String, into field: FieldTarget, handle: FieldHandle) throws {
        let target = Target.focusedField(field)
        let expires = now() + deadline

        let plan: [String]
        switch chunks.plan(text) {
        case let .chunks(planned):
            plan = planned
        case .tooManyChunks:
            throw DeliveryFailure.notStarted(
                target, reason: "the text is longer than one delivery may type "
                    + "(\(chunks.maxChunks) keystroke chunks)")
        case .graphemeTooLong:
            throw DeliveryFailure.notStarted(
                target, reason: "one character of the text is longer than a keystroke may carry "
                    + "(\(chunks.maxEventUTF16) UTF-16 units)")
        }

        try validate(field, handle: handle, before: expires)

        for (index, chunk) in plan.enumerated() {
            if index > 0 {
                pacer.pause(pause)
                guard now() <= expires else {
                    throw DeliveryFailure.mayBePartial(
                        target, reason: "the delivery ran past its \(Self.seconds(deadline)) "
                            + "deadline after \(index) of \(plan.count) chunks")
                }
                guard frontmost.current?.pid == field.pid else {
                    throw DeliveryFailure.mayBePartial(
                        target, reason: "\(field.appName) stopped being the frontmost application "
                            + "after \(index) of \(plan.count) chunks")
                }
            }
            do {
                try poster.post(unicode: chunk, toPID: field.pid)
            } catch {
                let reason = Daemon.reason(error)
                throw index == 0
                    ? DeliveryFailure.notStarted(target, reason: reason)
                    : DeliveryFailure.mayBePartial(target, reason: reason)
            }
        }
    }

    /// The final validation, in D32's order. Nothing but posting follows it.
    private func validate(_ field: FieldTarget, handle: FieldHandle,
                          before expires: TimeInterval) throws {
        let target = Target.focusedField(field)
        try checkDeadline(target, expires)
        try checkFrontmost(field)

        let fresh: FocusedElement
        do {
            fresh = try access.focusedElement(expectedPID: field.pid)
        } catch let error as FocusedFieldError {
            switch error {
            case .noElement, .definitelyDifferent:
                throw DeliveryFailure.targetGone(target, reason: error.description)
            case .cannotTell:
                throw DeliveryFailure.notStarted(target, reason: error.description)
            }
        } catch {
            throw DeliveryFailure.notStarted(target, reason: Daemon.reason(error))
        }
        guard access.isSame(fresh.handle, as: handle) else {
            throw DeliveryFailure.targetGone(
                target, reason: "a different element is focused in \(field.appName)")
        }
        switch FieldEligibility.classify(fresh.facts) {
        case .eligible:
            break
        case .ineligible:
            throw DeliveryFailure.notStarted(
                target, reason: "the focused element in \(field.appName) is no longer a text field")
        case .unknown:
            throw DeliveryFailure.notStarted(
                target, reason: "accessibility could not tell whether the focused element in "
                    + "\(field.appName) is still a text field")
        }
        guard !access.isSecureInputOn else {
            throw DeliveryFailure.notStarted(target, reason: "Secure Input is on")
        }
        guard access.isTrusted else {
            throw DeliveryFailure.notStarted(target, reason: "the Accessibility grant is gone")
        }

        // Again, now that every call that could block has returned.
        try checkDeadline(target, expires)
        try checkFrontmost(field)
    }

    /// Nothing has been posted yet, so a deadline passed here is `notStarted`.
    private func checkDeadline(_ target: Target, _ expires: TimeInterval) throws {
        guard now() <= expires else {
            throw DeliveryFailure.notStarted(
                target, reason: "the delivery's \(Self.seconds(deadline)) deadline passed before "
                    + "the first keystroke")
        }
    }

    /// A different frontmost application is a definite answer; nothing frontmost at all is not.
    private func checkFrontmost(_ field: FieldTarget) throws {
        let target = Target.focusedField(field)
        guard let current = frontmost.current else {
            throw DeliveryFailure.notStarted(target, reason: "no application is frontmost")
        }
        guard current.pid == field.pid else {
            throw DeliveryFailure.targetGone(
                target, reason: "\(HoldRoute.appName(of: current)) is frontmost, not "
                    + "\(field.appName)")
        }
    }

    private static func seconds(_ value: TimeInterval) -> String {
        value == value.rounded() ? "\(Int(value)) s" : "\(value) s"
    }
}
