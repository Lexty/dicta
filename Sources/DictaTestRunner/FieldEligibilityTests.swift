import DictaCore
import Testing

/// D31's admission rule for a focused element, as a pure classification of accessibility metadata.
/// Every row of F11's table is here as it was measured, positives and negatives, because plain
/// characters posted into a tree or a page act as commands (§1 excludes voice control).
@Suite("field eligibility")
struct FieldEligibilityTests {
    typealias Row = (name: String, facts: FieldFacts, expected: Eligibility)

    /// One measured element, in the table's column order.
    static func facts(_ role: String?, _ subrole: String?, settable: Bool?,
                      range: Bool?) -> FieldFacts {
        FieldFacts(role: role, subrole: subrole, valueSettable: settable,
                   hasSelectedTextRange: range)
    }

    /// F11's table, one row per focused thing measured on 2026-09-13. A `—` or `unsupported`
    /// subrole is `nil`: the adapter reports no subrole, which is not a secure one.
    static let f11: [Row] = [
        ("VS Code editor", facts("AXTextArea", nil, settable: true, range: true), .eligible),
        ("VS Code chat input", facts("AXTextArea", nil, settable: true, range: true), .eligible),
        ("VS Code terminal", facts("AXTextField", nil, settable: true, range: true), .eligible),
        ("Slack message field", facts("AXTextArea", nil, settable: true, range: true), .eligible),
        ("Telegram message field",
         facts("AXTextArea", nil, settable: true, range: true), .eligible),
        ("Safari textarea", facts("AXTextArea", nil, settable: true, range: true), .eligible),
        ("Safari password field",
         facts("AXTextField", "AXSecureTextField", settable: true, range: true), .ineligible),
        ("VS Code Explorer tree", facts("AXGroup", nil, settable: false, range: true), .ineligible),
        ("Safari page after clicking a button",
         facts("AXWebArea", nil, settable: false, range: false), .ineligible),
    ]

    @Test("every row of F11's table", arguments: FieldEligibilityTests.f11)
    func f11Table(row: Row) {
        #expect(FieldEligibility.classify(row.facts) == row.expected, "\(row.name)")
    }

    @Test("facts AX did not answer at all are unknown, never eligible")
    func allNilIsUnknown() {
        let facts = FieldFacts(role: nil, subrole: nil, valueSettable: nil,
                               hasSelectedTextRange: nil)
        #expect(FieldEligibility.classify(facts) == .unknown)
    }

    @Test("a text role whose value is not settable is ineligible")
    func textRoleNotSettable() {
        let facts = FieldFacts(role: "AXTextArea", subrole: nil, valueSettable: false,
                               hasSelectedTextRange: true)
        #expect(FieldEligibility.classify(facts) == .ineligible)
    }

    @Test("a text role whose settability could not be read is unknown")
    func textRoleSettabilityUnread() {
        let facts = FieldFacts(role: "AXTextField", subrole: nil, valueSettable: nil,
                               hasSelectedTextRange: true)
        #expect(FieldEligibility.classify(facts) == .unknown)
    }

    @Test("a settable value whose role could not be read is unknown")
    func roleUnread() {
        let facts = FieldFacts(role: nil, subrole: nil, valueSettable: true,
                               hasSelectedTextRange: true)
        #expect(FieldEligibility.classify(facts) == .unknown)
    }

    @Test("a known non-text role is ineligible even when its settability could not be read")
    func nonTextRoleWins() {
        let facts = FieldFacts(role: "AXButton", subrole: nil, valueSettable: nil,
                               hasSelectedTextRange: nil)
        #expect(FieldEligibility.classify(facts) == .ineligible)
    }

    @Test("the secure subrole is ineligible whatever else was read")
    func secureSubroleWins() {
        let facts = FieldFacts(role: nil, subrole: "AXSecureTextField", valueSettable: nil,
                               hasSelectedTextRange: nil)
        #expect(FieldEligibility.classify(facts) == .ineligible)
    }

    @Test("a text field whose subrole could not be read is unknown, never eligible")
    func subroleUnreadIsUnknown() {
        // A timed-out subrole read on a password field would otherwise pass as a plain field, and
        // Secure Input is not promised to catch it (SPEC D31).
        let facts = FieldFacts(role: "AXTextField", subrole: nil, subroleAnswered: false,
                               valueSettable: true, hasSelectedTextRange: true)
        #expect(FieldEligibility.classify(facts) == .unknown)
    }

    @Test("a definite negative still wins over a subrole that could not be read")
    func definiteNegativeWinsOverUnreadSubrole() {
        let notSettable = FieldFacts(role: "AXTextArea", subrole: nil, subroleAnswered: false,
                                     valueSettable: false, hasSelectedTextRange: true)
        let tree = FieldFacts(role: "AXGroup", subrole: nil, subroleAnswered: false,
                              valueSettable: false, hasSelectedTextRange: true)
        #expect(FieldEligibility.classify(notSettable) == .ineligible)
        #expect(FieldEligibility.classify(tree) == .ineligible)
    }

    @Test("AXSelectedTextRange discriminates nothing")
    func selectedTextRangeIsNotAnInput() {
        for range in [true, false, nil] as [Bool?] {
            let field = FieldFacts(role: "AXTextArea", subrole: nil, valueSettable: true,
                                   hasSelectedTextRange: range)
            let tree = FieldFacts(role: "AXGroup", subrole: nil, valueSettable: false,
                                  hasSelectedTextRange: range)
            #expect(FieldEligibility.classify(field) == .eligible)
            #expect(FieldEligibility.classify(tree) == .ineligible)
        }
    }

    @Test("text roles F11 did not measure stay ineligible",
          arguments: ["AXComboBox", "AXSearchField"])
    func unmeasuredTextRoles(role: String) {
        let facts = FieldFacts(role: role, subrole: nil, valueSettable: true,
                               hasSelectedTextRange: true)
        #expect(FieldEligibility.classify(facts) == .ineligible)
    }

    /// How macOS actually reports a search field: a text-field role, with the search subrole.
    @Test("a text field with the search subrole stays ineligible")
    func searchSubrole() {
        let facts = FieldFacts(role: "AXTextField", subrole: "AXSearchField", valueSettable: true,
                               hasSelectedTextRange: true)
        #expect(FieldEligibility.classify(facts) == .ineligible)
    }
}
