import Foundation

/// Where a hold goes, decided at the press from what was frontmost (D22, D31).
///
/// D22's prohibition, turned into a table by `--focused-fields`:
///
/// | frontmost at the press | option off | option on |
/// |---|---|---|
/// | agterm | agterm path, start on key-down | agterm path, start on key-down |
/// | any other application | silent no-op | focused-field path, once the hold outlasts the floor |
///
/// There is no row for dicta's own bundles: F11 measured that the menu-bar panel never becomes
/// frontmost, so a rule naming it would be a rule about a state that does not occur (D30).
///
/// What is NOT here is as deliberate as what is. The grant, Secure Input and the focused element
/// all need accessibility, and none of that may be touched at the press: a combination released
/// before the floor must cost nothing at all (D21, D31). This is a comparison of strings the poll
/// loop already has.
public enum HoldRoute: Sendable, Equatable {
    /// agterm is frontmost: the session and pane come from its tree, and the start is sent at
    /// key-down, exactly as before D31.
    case agterm
    /// Nothing happens and nothing is said (D22).
    case ignore
    /// The focused field of this application, evaluated only once the hold outlasts the floor.
    case focusedFieldAfterFloor(FieldTarget)

    public static func decide(frontmost: FrontmostFacts?, agtermBundleID: String,
                              focusedFieldsEnabled: Bool) -> HoldRoute {
        // Nothing frontmost has no pid to aim at, with the option on or off.
        guard let frontmost else { return .ignore }
        if frontmost.bundleID == agtermBundleID { return .agterm }
        guard focusedFieldsEnabled else { return .ignore }
        return .focusedFieldAfterFloor(FieldTarget(bundleID: frontmost.bundleID,
                                                   appName: appName(of: frontmost),
                                                   pid: frontmost.pid))
    }

    /// The name the record and the menu show. An application may report no localized name; its
    /// bundle identifier is then the next most recognisable thing, and the pid is the last resort
    /// rather than an invented name.
    public static func appName(of frontmost: FrontmostFacts) -> String {
        if let name = frontmost.name, !name.isEmpty { return name }
        if let bundleID = frontmost.bundleID, !bundleID.isEmpty { return bundleID }
        return "pid \(frontmost.pid)"
    }
}
