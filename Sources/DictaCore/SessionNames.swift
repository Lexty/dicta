import Foundation

// Reading session NAMES out of `agtermctl tree --json`, as a pure value.
//
// This is a second decoder of the same JSON, and that is deliberate rather than an oversight.
// `Agterm` in `DictaRuntime` already parses this tree — but `DictaRuntime` links FluidAudio, which
// the menu binary must not reach (D27, invariant 8), so the existing one is unreachable from the
// only caller that wants a name. The choice was between moving `Agterm`'s parser — and its errors,
// and the hottest file in the project — down into `DictaCore` for one line in a panel, or writing
// a narrower one beside it.
//
// The narrower one is safe here for a reason that does not generalise: **this decoder decides
// nothing.** `Agterm`'s answer aims keystrokes and therefore fails closed — an unrecognised pane
// throws rather than being guessed at (D6). This one labels a line, and its failure mode is to
// return nothing so the caller shows the session id instead. A decoder that cannot cause a wrong
// action is allowed to be lenient; one that aims text is not.
//
// The drift that duplication risks is guarded rather than hoped away: `test: the name reader and
// the target resolver read the same tree` runs both over the ONE fixture in `AgtermTests`, which is
// itself checked against what the installed agterm actually prints.

/// Session names, read from a live tree. Never throws: a name is a label, and a label that cannot
/// be resolved is the session id, not an error.
public enum SessionNames {
    /// Only the two fields a label needs. Everything else agterm sends — titles, cwds, foreground
    /// commands, font sizes — is ignored, so a new agterm release does not break a caption.
    private struct Envelope: Decodable {
        struct Result: Decodable { let tree: Tree }
        struct Tree: Decodable { let workspaces: [Workspace]? }
        struct Workspace: Decodable { let sessions: [Session]? }
        struct Session: Decodable {
            let id: String
            let name: String?
        }

        let ok: Bool?
        let result: Result?
    }

    /// Every session the tree names, by id. Empty when the tree could not be read at all — which is
    /// the same outcome as a tree with no names in it, on purpose: both mean "show the id".
    public static func names(inTree json: String) -> [String: String] {
        guard let data = json.data(using: .utf8), !data.isEmpty,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.ok != false, let tree = envelope.result?.tree else { return [:] }
        var names: [String: String] = [:]
        for workspace in tree.workspaces ?? [] {
            for session in workspace.sessions ?? [] {
                guard let name = session.name, !name.isEmpty else { continue }
                names[session.id] = name
            }
        }
        return names
    }
}

public extension Target {
    /// The target line's caption: `claude-code · left` for a pane, `Code` for a focused field.
    ///
    /// For a pane, the pane is always shown and the name never replaces it. Both halves are the
    /// target (§5), and this line exists to be D4 made visible — the one moment where noticing the
    /// wrong pane is still free. A caption naming only a session would be silent about the half a
    /// user is most likely to have got wrong, since the pane follows focus and the session does
    /// not.
    ///
    /// `name` is a session name and describes nothing about a field, so a field ignores it.
    func caption(name: String?) -> String {
        switch self {
        case let .agterm(target):
            let head = name ?? Self.shorten(target.sessionID)
            return "\(head) · \(target.pane.rawValue)"
        case let .focusedField(field):
            return Self.caption(field)
        }
    }

    /// A field's caption: the application's name, then its bundle id, then its pid. Never empty,
    /// for the reason a session falls back to its id: an empty target line is worse than a number.
    static func caption(_ field: FieldTarget) -> String {
        if !field.appName.isEmpty { return field.appName }
        if let bundleID = field.bundleID, !bundleID.isEmpty { return bundleID }
        return "pid \(field.pid)"
    }

    /// A session id, shortened to something a person can compare at a glance. Full ids are UUIDs
    /// and a panel 300 pt wide has no room for one; the first group is enough to tell two sessions
    /// apart, and the record keeps the whole of it for anything that has to be exact.
    static func shorten(_ sessionID: String) -> String {
        let head = sessionID.prefix(8)
        return head.count < sessionID.count ? head + "…" : String(head)
    }
}
