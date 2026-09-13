import DictaCore
import Foundation

// The focused-field path's composition (D31), out of `main.swift` so that "a closed gate constructs
// no system adapter" is an assertion rather than a reading of top-level code.
//
// The adapters are built through `Adapters`, whose production value is the system's and whose test
// value counts. Until the person's choice first opens `FocusedFieldSwitch` none of them is called,
// which is the whole of invariant 14's "only under other-apps" on the daemon side: no
// `SystemFocusedFieldAccess`, so no messaging timeout set and no trust check; and no
// `SystemEventPoster`. The frontmost source is not an adapter the switch makes: it is handed the
// process's one `SystemFrontmost`, which the trigger routes on too (F8a).

public enum FocusedFieldWiring {
    /// How each adapter the path needs is made.
    public struct Adapters: Sendable {
        public typealias InjectorFactory = @Sendable (any FocusedFieldAccess, any EventPoster,
                                                      any FrontmostApplication) -> any FieldInjector

        public var access: @Sendable () -> any FocusedFieldAccess
        public var poster: @Sendable () -> any EventPoster
        /// Composes the injector out of the adapters just made. Constructs, and calls none of them.
        /// The production value is `FocusedFieldInjector`'s own; a daemon test hands in one that
        /// records deliveries, or a real injector with a fake pacer.
        public var injector: InjectorFactory

        public init(access: @escaping @Sendable () -> any FocusedFieldAccess,
                    poster: @escaping @Sendable () -> any EventPoster,
                    injector: @escaping InjectorFactory = { access, poster, frontmost in
                        FocusedFieldInjector(access: access, poster: poster, frontmost: frontmost)
                    }) {
            self.access = access
            self.poster = poster
            self.injector = injector
        }

        public static let system = Adapters(access: { SystemFocusedFieldAccess() },
                                            poster: { SystemEventPoster() })
    }

    /// What the daemon and the trigger are handed once the path has been built.
    public struct Wired: Sendable {
        public let access: any FocusedFieldAccess
        public let daemon: Daemon.FocusedFields
        public let trigger: HoldTrigger.FocusedFields
    }
}

/// The focused-field path behind a gate that follows the person's choice (D31).
///
/// **The wiring is built at most once**, on the first opening, and kept for the process: an attempt
/// accepted while the gate was open delivers through it, final validation included, whatever the
/// gate says by then. Closing never destroys it; it only stops anything new being admitted.
///
/// **Admission is by generation.** `current` answers the wiring and the generation it was read
/// under, or `nil` while closed, and every `setOpen` bumps the generation. A grant check made by an
/// admitted reader is reported back with that generation and discarded unless it is still the
/// current one, so a result from before a close -- or from a previous opening -- never overwrites
/// what the present opening knows.
///
/// **The grant is observed with no timer.** It is checked once, synchronously, when the gate opens,
/// and otherwise only when a reader reports a check it was going to make anyway. A revocation while
/// nobody looks is noticed at the next check.
public final class FocusedFieldSwitch: @unchecked Sendable {
    /// One reader's admission: the wiring, and the generation it must report under.
    public struct Admission: Sendable {
        public let wiring: FocusedFieldWiring.Wired
        public let generation: UInt64
    }

    private let frontmost: any FrontmostApplication
    private let feedback: any Notifier
    private let adapters: FocusedFieldWiring.Adapters
    /// **Guarded by `reportLock`.** Who is told every accepted grant.
    private var onAccessibility: @Sendable (Bool) -> Void

    /// Guards the gate, the generation, the wiring and the grant. Held while the wiring is built,
    /// which makes no check, and never across a trust check or the callback.
    private let lock = NSLock()
    /// Serialises accepted reports with their callbacks, so the grant the switch holds and the one
    /// the callback last delivered cannot disagree. `current` never takes it.
    private let reportLock = NSLock()
    private var isOpen = false
    private var generation: UInt64 = 0
    private var wired: FocusedFieldWiring.Wired?
    private var lastGrant: Bool?

    /// Builds nothing and calls no adapter: the gate starts closed.
    ///
    /// `frontmost` is the process's one frontmost source, which the injector re-validates against
    /// (F8a). `feedback` is the daemon's own, since a field has no indicator and its refusals are
    /// sounds and notifications (D13). `onAccessibility` is told every accepted grant result, so
    /// readiness follows the same facts as `grant`; the daemon replaces it with its own through
    /// `tellAccessibility(to:)`, since it is built after the switch.
    public init(frontmost: any FrontmostApplication, feedback: any Notifier,
                adapters: FocusedFieldWiring.Adapters = .system,
                onAccessibility: @escaping @Sendable (Bool) -> Void = { _ in }) {
        self.frontmost = frontmost
        self.feedback = feedback
        self.adapters = adapters
        self.onAccessibility = onAccessibility
    }

    /// Opens or closes the gate, bumping the generation either way. Opening builds the wiring if it
    /// was never built, then checks the grant once and reports it under the new generation.
    public func setOpen(_ open: Bool) {
        let admitted = lock.withLock { () -> Admission? in
            generation += 1
            isOpen = open
            // A new generation knows nothing about the grant until it has looked.
            lastGrant = nil
            guard open else { return nil }
            let wiring = wired ?? build()
            wired = wiring
            return Admission(wiring: wiring, generation: generation)
        }
        guard let admitted else { return }
        report(trusted: admitted.wiring.access.isTrusted, generation: admitted.generation)
    }

    /// Replaces who is told every accepted grant. Serialised with the reports themselves, so a
    /// report is delivered whole to the previous recipient or whole to this one.
    public func tellAccessibility(to body: @escaping @Sendable (Bool) -> Void) {
        reportLock.withLock { onAccessibility = body }
    }

    /// The wiring and the generation to report under, or `nil` while the gate is closed.
    public var current: Admission? {
        lock.withLock {
            guard isOpen, let wired else { return nil }
            return Admission(wiring: wired, generation: generation)
        }
    }

    /// The wiring if it was ever built, open or closed: what an accepted attempt delivers through.
    public var built: FocusedFieldWiring.Wired? { lock.withLock { wired } }

    /// The grant as last reported under the current generation; `nil` while closed or not yet
    /// checked.
    public var grant: Bool? { lock.withLock { lastGrant } }

    /// Takes a grant check made under `generation`. Accepted -- `grant` updated and
    /// `onAccessibility` called -- only while the gate is open and the generation is current;
    /// otherwise discarded, and the answer says so, so a reader admitted before a close can stop.
    @discardableResult
    public func report(trusted: Bool, generation reported: UInt64) -> Bool {
        reportLock.withLock {
            let accepted = lock.withLock { () -> Bool in
                guard isOpen, reported == generation else { return false }
                lastGrant = trusted
                return true
            }
            if accepted { onAccessibility(trusted) }
            return accepted
        }
    }

    /// The start-up line naming both facts a user debugging "the hold does nothing in VS Code"
    /// needs first. It makes no call of its own: with the gate closed nothing may look at the
    /// grant, and with it open the opening has already looked.
    public var startupLine: String {
        let (open, grant) = lock.withLock { (isOpen, lastGrant) }
        guard open else { return "focused fields: off, accessibility: not checked" }
        let described = switch grant {
        case true?: "granted"
        case false?: "not granted"
        case nil: "not checked"
        }
        return "focused fields: on, accessibility: \(described)"
    }

    /// Under `lock`, once. The factories construct; none of them checks the grant or reads a field.
    private func build() -> FocusedFieldWiring.Wired {
        let access = adapters.access()
        let injector = adapters.injector(access, adapters.poster(), frontmost)
        return FocusedFieldWiring.Wired(
            access: access,
            daemon: Daemon.FocusedFields(access: access, injector: injector),
            trigger: HoldTrigger.FocusedFields(access: access, feedback: feedback))
    }
}
