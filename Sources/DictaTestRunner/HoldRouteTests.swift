import DictaCore
import Foundation
import Testing

// D22's prohibition as D31's routing table, and the one request shape that names a focused field.
// Pure: nothing here reads a keyboard or an application, which is the point of deciding the route
// out of facts the poll loop already holds.

@Suite("hold route")
struct HoldRouteTests {
    static let agterm = "com.umputun.agterm"
    static let agtermFacts = FrontmostFacts(bundleID: agterm, pid: 99, name: "agterm")
    static let code = FrontmostFacts(bundleID: "com.microsoft.VSCode", pid: 4_242, name: "Code")

    @Test("agterm frontmost takes the agterm path with focused fields off")
    func agtermOff() {
        #expect(HoldRoute.decide(frontmost: Self.agtermFacts, agtermBundleID: Self.agterm,
                                 focusedFieldsEnabled: false) == .agterm)
    }

    @Test("agterm frontmost takes the agterm path with focused fields on")
    func agtermOn() {
        // D31: agterm is more precise (session plus pane), has the indicator and needs no grant,
        // so the option never takes a hold away from it.
        #expect(HoldRoute.decide(frontmost: Self.agtermFacts, agtermBundleID: Self.agterm,
                                 focusedFieldsEnabled: true) == .agterm)
    }

    @Test("another application frontmost is ignored with focused fields off")
    func otherOff() {
        // D22 unchanged: the option off is exactly the build before it.
        #expect(HoldRoute.decide(frontmost: Self.code, agtermBundleID: Self.agterm,
                                 focusedFieldsEnabled: false) == .ignore)
    }

    @Test("another application frontmost routes to its focused field with focused fields on")
    func otherOn() {
        let route = HoldRoute.decide(frontmost: Self.code, agtermBundleID: Self.agterm,
                                     focusedFieldsEnabled: true)
        #expect(route == .focusedFieldAfterFloor(
            FieldTarget(bundleID: "com.microsoft.VSCode", appName: "Code", pid: 4_242)))
    }

    @Test("an application with no bundle identifier is ignored when off and a field target when on")
    func nilBundleIdentifier() {
        // A nil bundle id is never agterm's, and never an invented one either.
        let bare = FrontmostFacts(bundleID: nil, pid: 313, name: "tool")
        #expect(HoldRoute.decide(frontmost: bare, agtermBundleID: Self.agterm,
                                 focusedFieldsEnabled: false) == .ignore)
        #expect(HoldRoute.decide(frontmost: bare, agtermBundleID: Self.agterm,
                                 focusedFieldsEnabled: true)
            == .focusedFieldAfterFloor(FieldTarget(bundleID: nil, appName: "tool", pid: 313)))
    }

    @Test("nothing frontmost routes nowhere, with the option on or off")
    func nothingFrontmost() {
        for enabled in [false, true] {
            #expect(HoldRoute.decide(frontmost: nil, agtermBundleID: Self.agterm,
                                     focusedFieldsEnabled: enabled) == .ignore)
        }
    }

    @Test("a field target's name falls back to the bundle identifier, then the pid")
    func appNameFallback() {
        #expect(HoldRoute.appName(of: FrontmostFacts(bundleID: "a.b", pid: 1, name: nil)) == "a.b")
        #expect(HoldRoute.appName(of: FrontmostFacts(bundleID: "a.b", pid: 1, name: "")) == "a.b")
        #expect(HoldRoute.appName(of: FrontmostFacts(bundleID: nil, pid: 7, name: nil)) == "pid 7")
    }
}

@Suite("focused-field request")
struct FieldRequestTests {
    static let field = FieldTarget(bundleID: "com.microsoft.VSCode", appName: "Code", pid: 4_242)

    @Test("a start naming a field together with focus or a session is a conflict")
    func fieldWithAnotherTargetConflicts() {
        #expect(Request(cmd: .start, focus: true, field: Self.field).conflict == .fieldWithFocus)
        #expect(Request(cmd: .start, sessionID: "s", field: Self.field).conflict
            == .fieldWithSession)
        // An unset `$AGT_SESSION_ID` expands to an empty string, and that is still a session.
        #expect(Request(cmd: .start, sessionID: "", field: Self.field).conflict
            == .fieldWithSession)
    }

    @Test("a field, a focus start and a session start are each accepted alone")
    func eachAloneIsFine() {
        #expect(Request(cmd: .start, field: Self.field).conflict == nil)
        #expect(Request(cmd: .start, focus: true).conflict == nil)
        #expect(Request(cmd: .start, sessionID: "s").conflict == nil)
        // `focus: false` asks for nothing, so it names no second target.
        #expect(Request(cmd: .start, focus: false, field: Self.field).conflict == nil)
    }

    @Test("a field request round-trips on the wire, and a request without one does not mention it")
    func fieldOnTheWire() throws {
        let request = Request(cmd: .start, field: Self.field)
        #expect(try Wire.decode(Request.self, from: Wire.encode(request)) == request)
        let plain = try #require(String(data: Wire.encode(Request(cmd: .start, focus: true)),
                                        encoding: .utf8))
        #expect(!plain.contains("field"))
    }
}
