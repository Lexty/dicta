import DictaCore
import Foundation

// The focused-field path's composition (D31), out of `main.swift` so that "the option off
// constructs no system adapter" is an assertion rather than a reading of top-level code.
//
// The adapters are built through `Adapters`, whose production value is the system's and whose test
// value counts. With `--focused-fields` off `make` returns before calling any of them, which is the
// whole of invariant 14's "only when on" on the daemon side: no `SystemFocusedFieldAccess`, so no
// messaging timeout set and no trust check; no `SystemEventPoster`; and no second workspace
// observer.

public enum FocusedFieldWiring {
    /// How each adapter the path needs is made.
    public struct Adapters: Sendable {
        public var frontmost: @Sendable () -> any FrontmostApplication
        public var access: @Sendable () -> any FocusedFieldAccess
        public var poster: @Sendable () -> any EventPoster

        public init(frontmost: @escaping @Sendable () -> any FrontmostApplication,
                    access: @escaping @Sendable () -> any FocusedFieldAccess,
                    poster: @escaping @Sendable () -> any EventPoster) {
            self.frontmost = frontmost
            self.access = access
            self.poster = poster
        }

        public static let system = Adapters(frontmost: { SystemFrontmost() },
                                            access: { SystemFocusedFieldAccess() },
                                            poster: { SystemEventPoster() })
    }

    /// What the daemon and the trigger are handed when the option is on.
    public struct Wired: Sendable {
        /// The ONE frontmost source: the trigger routes on it and the injector re-validates against
        /// it. Two instances would be two observers that can disagree, and an unobserved one is
        /// F8a's frozen value.
        public let frontmost: any FrontmostApplication
        public let access: any FocusedFieldAccess
        public let daemon: Daemon.FocusedFields
        public let trigger: HoldTrigger.FocusedFields
    }

    /// `nil`, having called no adapter, when `--focused-fields` is off.
    ///
    /// With the option on the frontmost source is built even under `--no-hold`: the injector
    /// re-validates against it, and it only tracks activations once its observer exists (F8a).
    /// `feedback` is the daemon's own, since a field has no indicator and its refusals are sounds
    /// and notifications (D13).
    public static func make(options: DaemonOptions, feedback: any Notifier,
                            adapters: Adapters = .system) -> Wired? {
        guard options.focusedFields else { return nil }
        let frontmost = adapters.frontmost()
        let access = adapters.access()
        let injector = FocusedFieldInjector(access: access, poster: adapters.poster(),
                                            frontmost: frontmost)
        return Wired(frontmost: frontmost,
                     access: access,
                     daemon: Daemon.FocusedFields(access: access, injector: injector),
                     trigger: HoldTrigger.FocusedFields(access: access, feedback: feedback))
    }

    /// The start-up line naming both facts a user debugging "the hold does nothing in VS Code"
    /// needs first. With the option off the grant is not looked at -- the trust check is an
    /// accessibility call, and the option off makes none -- so it says so rather than guessing.
    public static func startupLine(_ wired: Wired?) -> String {
        guard let wired else { return "focused fields: off, accessibility: not checked" }
        let grant = wired.access.isTrusted ? "granted" : "not granted"
        return "focused fields: on, accessibility: \(grant)"
    }
}
