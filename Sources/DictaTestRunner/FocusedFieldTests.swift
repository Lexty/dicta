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
