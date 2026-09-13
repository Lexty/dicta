import AppKit
import DictaCore
import SwiftUI

// The setup window (D27, D31). It draws `SetupModel` and reports three things back to the view
// model — a click, the window becoming key, the window closing — and decides none of them: which
// screen, what a click sends, and whether a close or a key window sends anything are all
// `SetupModel`'s, where the test runner can reach them.
//
// **An AppKit window, not a SwiftUI `Window` scene.** The plan asked for a measurement first:
// whether `openWindow` from the `MenuBarExtra` label opens a `Window` scene in this `LSUIElement`
// app, and brings it forward. Nobody has measured it on hardware yet, and the scene carries two
// more unmeasured behaviours besides: a `Window` declared beside a `MenuBarExtra` may open by
// itself at launch (only macOS 15 can suppress that, and the package targets 14), and window
// restoration may reopen it at login. Each of those would take focus from agterm with nobody having
// asked, which D27 allows this window only on purpose. An `NSWindow` opens when `show()` is called
// and at no other moment, so the view model opens it directly, with nothing to bridge. H35 and H41
// score what is left: that it comes forward, and that it never appears unasked.

/// Owns the one setup window, built on first use and kept for the process.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let content: () -> AnyView
    private let becameKey: () -> Void
    private let closed: () -> Void

    init(content: @escaping () -> AnyView, becameKey: @escaping () -> Void,
         closed: @escaping () -> Void) {
        self.content = content
        self.becameKey = becameKey
        self.closed = closed
    }

    /// Opens the window, or brings it forward, and activates the app — the only moment this process
    /// ever activates itself (D27).
    func show() {
        let window = self.window ?? make()
        self.window = window
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func make() -> NSWindow {
        let hosting = NSHostingController(rootView: content())
        // The window follows the screen it draws: a checklist is taller than an offer.
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "Set Up Dicta"
        // Kept after a close, so reopening from "Set Up…" does not rebuild it.
        window.isReleasedWhenClosed = false
        // Nothing restores it at login: the first snapshot of a launch decides that, and only that.
        window.isRestorable = false
        window.delegate = self
        return window
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Opening makes it key, and so does coming back from System Settings or from the system's
        // own Accessibility dialog — which is why this never prompts (`effectOfBecomingKey`).
        becameKey()
    }

    func windowWillClose(_ notification: Notification) {
        closed()
    }
}

/// What the window draws.
struct SetupView: View {
    @ObservedObject var model: StatusViewModel

    private var setup: SetupModel { model.setup }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "mic")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(setup.heading)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(setup.body.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if case let .checklist(rows) = setup.screen {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(rows, id: \.item) { row in
                        ChecklistRowView(row: row) { model.setupClicked($0) }
                    }
                }
                Divider()
            }
            if let error = setup.saveError {
                // Inline, on the screen whose operation failed: a failed write changed nothing,
                // so this is still the screen to act on.
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Tint.red.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            controls
        }
        .padding(20)
        .frame(width: 440, alignment: .leading)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            ForEach(setup.controls, id: \.self) { control in
                button(control)
            }
            Spacer(minLength: 0)
        }
    }

    /// The choice that turns dictation on is the prominent one; agterm only is the secondary link
    /// the brainstorm asked for, never a button of equal weight.
    @ViewBuilder
    private func button(_ control: SetupControl) -> some View {
        let click = { model.setupClicked(control) }
        switch control {
        case .setUpDictation, .enable:
            Button(control.title, action: click)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        case .useOnlyWithAgterm:
            Button(control.title, action: click)
                .buttonStyle(.link)
        default:
            Button(control.title, action: click)
                .controlSize(.large)
        }
    }
}

/// One line of the checklist: a status glyph, what it is, what it needs, and its one control.
struct ChecklistRowView: View {
    let row: ChecklistRow
    let click: (SetupControl) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: glyph)
                .foregroundStyle(tint.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.body.weight(.medium))
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let control = row.control {
                    Button(control.title) { click(control) }
                        .padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var glyph: String {
        switch row.status {
        case .done: "checkmark.circle.fill"
        case .waiting: "clock"
        case .needed: "exclamationmark.circle.fill"
        case .info: "info.circle"
        }
    }

    /// A pending step is amber, never red: nothing is broken until the person has been asked.
    private var tint: Tint {
        switch row.status {
        case .done: .green
        case .needed: .amber
        case .waiting, .info: .quiet
        }
    }
}
