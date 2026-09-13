// D31's admission rule for a focused element. A focused element is not necessarily a text field:
// plain characters posted to a focused tree, list or page act as commands or type-to-select, and §1
// excludes voice control. So before the microphone opens, and again immediately before the first
// event (D32), the element is classified from accessibility METADATA alone -- never its value and
// never its selected text (invariant 14).

/// What the daemon read about a focused element. Metadata only, by construction: there is no field
/// here that could hold a value. `nil` means accessibility did not answer for that attribute.
public struct FieldFacts: Equatable, Sendable {
    public var role: String?
    /// `nil` when the element reports none, which F11 saw as both "no value" and "unsupported" on
    /// real text fields. Only the secure subrole means anything to the rule.
    public var subrole: String?
    /// Whether accessibility answered for the subrole at all. `false` for a timeout or any other
    /// error that is not "none": `subrole` is then `nil` without meaning the field has none, and a
    /// password field whose read timed out must not pass as a plain one.
    public var subroleAnswered: Bool
    /// Whether `kAXValueAttribute` is settable.
    public var valueSettable: Bool?
    /// Whether `kAXSelectedTextRangeAttribute` is present. Read, and deliberately not an input to
    /// the rule: F11 found Chromium puts it on a tree, so it discriminates nothing.
    public var hasSelectedTextRange: Bool?

    public init(role: String?, subrole: String?, subroleAnswered: Bool = true,
                valueSettable: Bool?, hasSelectedTextRange: Bool?) {
        self.role = role
        self.subrole = subrole
        self.subroleAnswered = subroleAnswered
        self.valueSettable = valueSettable
        self.hasSelectedTextRange = hasSelectedTextRange
    }
}

/// Three answers, not a `Bool`, because "could not tell" is a real outcome the caller must not
/// round up: both refusals refuse, but only one of them is a statement about the element.
public enum Eligibility: Equatable, Sendable {
    case eligible
    case ineligible
    /// The role, the settability or the subrole could not be read. Refused, never promoted to
    /// eligible.
    case unknown
}

/// F11's table as a rule (SPEC.md D31).
public enum FieldEligibility {
    /// The roles F11 measured as text fields. Other text-like roles (`AXComboBox`, `AXSearchField`)
    /// were not measured and stay out until a human item shows them.
    public static let textRoles: Set<String> = ["AXTextArea", "AXTextField"]
    /// The password field, named by its subrole without reading it.
    public static let secureSubrole = "AXSecureTextField"
    /// A search field is an `AXTextField` whose SUBROLE is `AXSearchField` -- macOS does not report
    /// it as a role -- so the role set alone would let it through. Unmeasured, so refused (D31).
    public static let searchSubrole = "AXSearchField"

    public static func classify(_ facts: FieldFacts) -> Eligibility {
        // A definite negative wins over a missing fact: the secure subrole, a known non-text role
        // or a value known not to be settable each settle the answer whatever else went unread.
        // Both refusals refuse, so the order only decides which of the two is reported.
        if facts.subrole == secureSubrole || facts.subrole == searchSubrole { return .ineligible }
        guard let role = facts.role else { return .unknown }
        guard textRoles.contains(role) else { return .ineligible }
        guard let settable = facts.valueSettable else { return .unknown }
        guard settable else { return .ineligible }
        // Everything else says text field, and only the subrole could still say password field.
        // Secure Input does not cover for it (SPEC D31), so an unread subrole is not "none".
        return facts.subroleAnswered ? .eligible : .unknown
    }
}
