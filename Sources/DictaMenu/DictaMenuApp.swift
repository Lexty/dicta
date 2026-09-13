import DictaCore
import DictaMenuKit
import SwiftUI

// The menu-bar item (D27). A SECOND client of the control socket, never a second face of the
// daemon: this process links DictaCore, DictaIPC and DictaRecord, as `dictactl` could, plus
// DictaMenuKit, which holds the menu's logic over those three, plus SwiftUI. It opens no
// microphone, loads no model, and the daemon holds no reference to it — if this binary is absent,
// quit or crashed, every dictation behaves identically.
//
// Why the file is not called `main.swift`: a SwiftUI `@main` type and top-level code cannot coexist
// in a target, and `main.swift` IS top-level code. Naming it after the type is the ordinary fix.
//
// The vocabulary below — 300 pt, 12 pt padding, a header of glyph/name/status/timer, banners on a
// tinted rounded rectangle, a footer of one verb and one exit — is acta's, adopted deliberately.
// Two menus in one menu bar that differ by twenty points look like a mistake rather than a choice.
// `docs/ui-vocabulary.md` is the written form; `Presentation` and `MenuModel` are the executable
// one.

@main
struct DictaMenuApp: App {
    /// The model and its setup-window presenter, paired before anything starts the model.
    @StateObject private var root = MenuRoot()

    var body: some Scene {
        MenuBarExtra {
            Panel(model: root.model)
        } label: {
            MenuBarLabel(model: root.model)
        }
        // `.window`, matching acta. `.menu` would give a list of commands; what this needs is a
        // panel with a header, banners and rows.
        .menuBarExtraStyle(.window)
    }
}

/// The view that is always there: the menu-bar item, observing the model itself.
///
/// Its own view, with its own `@ObservedObject`, because `MenuRoot` owns the model without
/// observing it: an `ObservableObject` does not forward a child's changes, so a label drawn from
/// `root.model` in the app's body would never redraw.
struct MenuBarLabel: View {
    @ObservedObject var model: StatusViewModel

    var body: some View {
        // The 90% of this UI: passive, always visible, never focused, no click. `mic` rather
        // than acta's `waveform` because two items from one family sit in the same strip and
        // must be distinguishable by SHAPE, not only by position.
        //
        // D13 applies here in full — the glyph lights on `listening`, never on the keypress —
        // and it holds by construction: the state it draws comes from the daemon's own
        // transitions, the same ones that drive the agterm indicator, so the two cannot
        // disagree.
        BarItem(label: model.model.barLabel(at: model.now))
            // **The stream starts HERE, not in the panel**, and that is a fix rather than a
            // style. `Panel` is built lazily by `MenuBarExtra` — it does not exist until the
            // item is clicked — so a `.task` on it meant the watch connection was opened by the
            // first person to open the panel and by nobody else. Measured on the installed
            // build (2026-08-24): a freshly launched `DictaMenu` held ZERO sockets, so the
            // glyph sat on its seeded state from login onwards. Every test of it passed
            // because everyone testing a panel opens the panel. The label is the view that
            // always exists, which makes it the only honest place for this.
            .task { model.start() }
    }
}

extension Tint {
    /// The one place the vocabulary becomes pixels. Everything above this line is a value a test
    /// can assert; this is the performance (D19).
    var color: Color {
        switch self {
        case .quiet: .secondary
        case .red: .red
        case .amber: .orange
        case .green: .green
        // `Color` has no `.tertiary` (it is a ShapeStyle, not a colour), so the closest true
        // colour is used: absence, never failure.
        case .faint: Color.secondary.opacity(0.5)
        }
    }
}

/// The menu-bar item: the glyph, and the clock beside it while the microphone is open.
///
/// Two icons from one family sit in this strip (dicta's `mic`, acta's `waveform`), so the shape
/// carries the identity and the clock carries the state. The clock's appearance and disappearance
/// changes the item's WIDTH, which moves every icon to its left — the one change in a menu bar that
/// peripheral vision reads without being asked to.
struct BarItem: View {
    let label: BarLabel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: label.glyph)
                .foregroundStyle(label.tint.color)
            if let timer = label.timer {
                // Monospaced DIGITS rather than a monospaced face: the strip must not twitch once a
                // second as `1` and `4` swap places, and the surrounding icons must not shuffle
                // except when the clock appears and goes.
                Text(timer)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(label.timerTint.color)
            }
        }
    }
}

struct Panel: View {
    @ObservedObject var model: StatusViewModel

    private var menu: MenuModel { model.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let banner = menu.banner {
                Divider()
                bannerView(banner)
            }
            // The target and the controls come and go together: both belong to an attempt that is
            // happening, and there is no idle version of either (D30).
            if let caption = model.targetCaption {
                Divider()
                TargetLine(caption: caption)
                AttemptControls(stop: model.stopAndType, abort: model.abort)
            }
            Divider()
            RecentDictations(rows: model.recent, now: model.now, copy: model.copy)
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 300)
        .task { model.panelAppeared() }
        .onDisappear { model.panelDisappeared() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: menu.presentation.glyph)
                .foregroundStyle(menu.presentation.tint.color)
            VStack(alignment: .leading, spacing: 1) {
                Text("Dicta").font(.headline)
                Text(menu.presentation.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            timer
        }
    }

    /// `2:41 / 10:00`, amber in the last minute.
    ///
    /// The cap is carried in the snapshot rather than hard-coded, so a UI cannot keep claiming ten
    /// minutes after the daemon's configuration changed — the first the user would know of that is
    /// a dictation vanishing early (D15).
    @ViewBuilder
    private var timer: some View {
        if let seconds = menu.speakingSeconds(at: model.now) {
            Text(Duration.clock(seconds) + (menu.snapshot?.capSeconds.map {
                " / " + Duration.clock($0)
            } ?? ""))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(menu.isNearCap(at: model.now) ? Color.orange : .red)
        }
    }

    private func bannerView(_ banner: Banner) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: banner.tint == .red
                ? "exclamationmark.triangle.fill"
                : "info.circle.fill")
                .foregroundStyle(banner.tint.color)
            VStack(alignment: .leading, spacing: 6) {
                Text(banner.text)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = banner.action, let title = banner.actionTitle {
                    Button(title) { model.perform(action) }
                        .font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(banner.tint.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    /// `Open Record` and `Set Up…` left, `Restart` right — and deliberately NO Quit.
    ///
    /// `Set Up…` is the window's one door that is always there: it opens by itself only at the
    /// first snapshot of a launch, and a banner offers it only while a step is pending (D27).
    ///
    /// The daemon's LaunchAgent has `KeepAlive`, so quitting it would be undone within ten seconds;
    /// a control that cannot do what it says must not exist. acta keeps its Quit because quitting
    /// acta quits it. That divergence is in `docs/ui-vocabulary.md` as a decision rather than as a
    /// difference somebody will later "fix".
    private var footer: some View {
        HStack {
            Button("Open Record") { model.openRecord() }
            Button("Set Up…") { model.openSetup() }
            Spacer()
            Button("Restart") { model.restartDaemon() }
        }
        .font(.caption)
    }
}
