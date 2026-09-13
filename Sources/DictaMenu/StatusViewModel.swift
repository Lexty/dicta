import AppKit
import DictaCore
import DictaIPC
import DictaRecord
import Foundation
import SwiftUI

/// Owns the `watch` connection and publishes a `MenuModel` (D27).
///
/// Wiring, and as little of it as possible: every decision this makes — which glyph, which banner,
/// how long to wait before retrying — is a pure value in `DictaCore`, where the test runner can
/// reach it. What is left here is a socket, a thread and a `@Published`.
///
/// **The connection runs on a real `Thread`, and that is not a style choice.**
/// `ControlClient.watch` blocks for the lifetime of the stream, and on Darwin, Swift's executor
/// shares the non-overcommit pool `DispatchQueue.global()` draws from — a watcher parked on a
/// cooperative thread for hours is one worker that never comes back. The daemon's own socket
/// server follows the same rule for the same measured reason.
@MainActor
final class StatusViewModel: ObservableObject {
    @Published private(set) var model = MenuModel()
    /// Ticks the timer between events. The daemon sends nothing while the user is speaking — there
    /// is no transition to report — so the seconds are counted here from the last known figure.
    @Published private(set) var now = Date()

    /// The last few attempts, newest first (Tier 1). Re-read when an attempt ends and when the
    /// panel is opened, never on a timer: the record only changes when a dictation does.
    @Published private(set) var recent: [DictationRow] = []
    /// What the live attempt's session is CALLED, once a tree has been asked. `nil` means the
    /// caption falls back to the session id, which is always true and merely less friendly.
    @Published private(set) var targetName: String?

    private let socketPath: String
    private let recordURL: URL
    private var running = false
    private var failures = 0
    private var ticker: Timer?
    /// The state the last event reported, so an attempt ENDING can be told from one that was
    /// already over — the record is worth re-reading on the first, and not on the second.
    private var lastState: LifecycleState?
    /// Session id → name, so the tree is asked once per session rather than once per redraw.
    private var names: [String: String] = [:]
    /// The session a name lookup is already in flight for, so a panel left open does not spawn a
    /// subprocess per second.
    private var resolvingName: String?
    /// Whether the panel is on screen, which is one of the two reasons to run a second hand.
    private var panelOpen = false

    /// Whether "Allow Access…" was clicked during this launch, which turns the row's action into
    /// "Open Accessibility Settings": the system shows its dialog once, and a second click must not
    /// look as if it did nothing.
    @Published private(set) var accessibilityRequested = false
    /// Answers `true` on the first snapshot of this process and never again (`FirstSnapshotLatch`).
    private var firstSnapshot = FirstSnapshotLatch()
    /// Built on first use, so a menu that never shows the window never builds one.
    private var setupWindowController: SetupWindowController?
    /// The window's requests, delivered in the order they were made (`OrderedSender`). Not `send`:
    /// a thread per request would let a slow first click land after a second one and overwrite it.
    private let setupSender: OrderedSender<Request>

    init(socketPath: String = Paths.current.socket.path,
         record: URL = Paths.current.record) {
        self.socketPath = socketPath
        recordURL = record
        setupSender = OrderedSender(name: "dev.personal.dicta.menu.setup") { request in
            // Dropped, as `send` drops it: every consequence arrives on the watch stream.
            _ = try? ControlClient.send(request, to: socketPath)
        }
        // Seeded SYNCHRONOUSLY, before the first frame is drawn. acta's `ControlViewModel` does the
        // same thing and it is the detail most worth copying: without it the panel flashes blank
        // every single time it is opened, which reads as a broken app rather than a loading one.
        model = MenuModel(link: Self.socketExists(at: socketPath) ? .connecting : .notRunning)
    }

    /// Starts watching, and keeps watching across daemon restarts. Idempotent.
    func start() {
        guard !running else { return }
        running = true
        connect()
        refreshRecent()
    }

    /// Called every time the panel appears. `start()` is idempotent; the record is re-read anyway,
    /// because a dictation may have been delivered by a chord while the panel was closed and the
    /// drawer is the one part of this UI that is not driven by the stream.
    func panelAppeared() {
        start()
        panelOpen = true
        updateTicker()
        refreshRecent()
        resolveTargetName()
    }

    /// The panel was dismissed. The relative times in the drawer stop needing a second hand, so the
    /// ticker goes back to being driven by whether a microphone is open.
    func panelDisappeared() {
        panelOpen = false
        updateTicker()
    }

    nonisolated private static func socketExists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    private func connect() {
        let path = socketPath
        let thread = Thread { [weak self] in
            // An absent socket is "not running", with no launch-on-demand: a UI that started the
            // daemon because somebody glanced at the menu bar would be deciding something the user
            // did not ask for.
            guard Self.socketExists(at: path) else {
                Task { @MainActor [weak self] in self?.finished(.notRunning) }
                return
            }
            do {
                try ControlClient.watch(to: path) { event in
                    let received = Date()
                    Task { @MainActor [weak self] in self?.receive(event, at: received) }
                }
                // Returning normally means the daemon ENDED the stream — a clean shutdown. Only an
                // `.end` frame gets here; anything else throws.
                Task { @MainActor [weak self] in
                    self?.finished(.ended(self?.model.lastEndReason ?? "it was stopped"))
                }
            } catch {
                Task { @MainActor [weak self] in self?.finished(Self.link(for: error, path: path)) }
            }
        }
        thread.name = "dev.personal.dicta.menu.watch"
        thread.start()
    }

    /// Which `DaemonLink` an error means. The distinction that matters: "there is no daemon" is
    /// ordinary and quiet, "the daemon stopped answering" is not.
    private static func link(for error: any Error, path: String) -> DaemonLink {
        guard let clientError = error as? ControlClient.ClientError else {
            return .failed("\(error)")
        }
        switch clientError {
        case .daemonNotRunning: return .notRunning
        default: return .failed(clientError.description)
        }
    }

    private func receive(_ event: WatchEvent, at time: Date) {
        failures = 0
        switch event.kind {
        case .update:
            model = MenuModel(link: .connected, snapshot: event.snapshot, receivedAt: time)
            // The only moment the window may open without being asked: the first snapshot of this
            // launch, if it is idle and something is pending. Never later, so it cannot take focus
            // from the pane just dictated into (D27).
            if firstSnapshot.observe(event.snapshot),
               SetupModel(snapshot: event.snapshot, firstSnapshotOfThisLaunch: true)
                   .shouldAutoOpen {
                openSetup()
            }
            let state = event.snapshot?.state
            // An attempt that has just ENDED is the only thing that writes to the record, and
            // invariant 10 puts the entry on disk before the first keystroke — so by the time the
            // daemon publishes `idle`, the line the drawer wants is already there.
            if state == .idle, let previous = lastState, previous != .idle { refreshRecent() }
            lastState = state
            updateTicker()
            resolveTargetName()
        case .end:
            model = MenuModel(link: .ended(event.reason ?? "it was stopped"),
                              snapshot: nil, receivedAt: time)
        }
    }

    private func finished(_ link: DaemonLink) {
        // An `.end` already recorded by `receive` is the more specific answer; do not overwrite it
        // with the generic one the returning thread reports.
        if case .ended = model.link, case .ended = link {} else {
            model = MenuModel(link: link, snapshot: nil, receivedAt: Date())
        }
        guard running else { return }
        let delay = Backoff.delay(afterFailures: failures)
        failures += 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.running else { return }
            if case .connected = self.model.link { return }
            self.connect()
        }
    }

    /// Runs the second hand only when something on screen is counting.
    ///
    /// Two things are: the clock in the menu bar while the microphone is open, and the relative
    /// times in the drawer while the panel is up. Neither is true most of the day, and a menu-bar
    /// item redrawn once a second for a glyph that has not changed is the same waste this project
    /// refused when it declined to poll `status` at 1 Hz — 86 400 wakeups to report nothing.
    ///
    /// One second is the right interval when it does run: the clock shows `m:ss`, and anything
    /// faster would redraw for a digit that cannot have changed.
    private func updateTicker() {
        let wanted = panelOpen || model.snapshot?.state == .recording
        guard wanted != (ticker != nil) else { return }
        guard wanted else {
            ticker?.invalidate()
            ticker = nil
            return
        }
        now = Date()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.now = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    // MARK: - the receipt drawer (Tier 1)

    /// Re-reads the last few attempts.
    ///
    /// Bounded by `RecordReader`, on a thread of its own. The record is append-only and grows for
    /// ever, and this runs every time the panel opens — the two facts together are why Task 5
    /// existed at all.
    func refreshRecent() {
        let url = recordURL
        offMain("record") { [weak self] in
            let reading = try? RecordReader.tail(of: url, entries: Self.recentCount)
            let rows = DictationRow.rows(from: reading?.entries ?? [])
            Task { @MainActor [weak self] in self?.recent = rows }
        }
    }

    /// How many rows the drawer holds. Five, per the proposal: enough to find the dictation you
    /// meant, short enough that the panel is still a glance rather than a log viewer.
    nonisolated static let recentCount = 5

    /// Copies one row's delivered text.
    ///
    /// **The only route by which this UI produces text**, and it takes the string the row already
    /// decided is copyable — which is `final` and never `recognised` (D28). A row with nothing to
    /// deliver has no button, so there is no branch here that could pick the wrong field.
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - the live target line

    /// The caption for the live attempt, resolved as far as it can be.
    var targetCaption: String? {
        guard let target = liveTarget else { return nil }
        return target.caption(name: target.sessionID.flatMap { names[$0] })
    }

    /// The target of an attempt that is happening NOW, and nothing else.
    ///
    /// Gated on the link as well as on the state: a snapshot kept across a lost connection is the
    /// last thing known, not the thing happening, and captioning a dead attempt with a live session
    /// name is the same class of lie as a red glyph over a closed microphone.
    private var liveTarget: Target? {
        guard model.link == .connected, let snapshot = model.snapshot,
              snapshot.isBusy else { return nil }
        return snapshot.target
    }

    /// Asks a live tree what the active attempt's session is called.
    ///
    /// Only for the ACTIVE attempt, and only once per session id: §9's `Target` holds the id, and
    /// this does not change that. History rows show no name at all, because the name is a live
    /// property of a session and a row from yesterday would be captioned with whatever that session
    /// happens to be called now — a caption that changes under a record that cannot.
    func resolveTargetName() {
        // A focused field has no session and nothing to look up: its caption is already its name.
        guard let session = liveTarget?.sessionID else {
            targetName = nil
            return
        }
        if let known = names[session] {
            targetName = known
            return
        }
        guard resolvingName != session, let tool = AgtermTool.locate() else { return }
        resolvingName = session
        offMain("tree") { [weak self] in
            let json = Self.capture(tool, ["tree", "--json"])
            let found = SessionNames.names(inTree: json)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.resolvingName = nil
                // Every name the tree gave, not only the one asked for: the next attempt is very
                // often in a session this tree already described, and a hit costs no subprocess.
                self.names.merge(found) { _, new in new }
                self.targetName = self.names[session]
            }
        }
    }

    // MARK: - ending an attempt from the panel (D30)

    /// `Stop and type` — the same thing the stopping chord does, in `clean` mode.
    ///
    /// **The attempt is NAMED**, and that is the safety property rather than a detail. The panel
    /// can be looking at a snapshot the daemon has already moved past — the duration cap, a
    /// route-change fault and a held key's release all end attempts with no click involved — and
    /// unaddressed `stop` landing after that would stop whatever attempt started next, in whatever
    /// session, which is D4's forbidden substitution reached through a button. Named, a stale click
    /// is §6's silent no-op, which is exactly what it should be.
    ///
    /// `clean` because there is one button. `raw` is chosen by the chord that stops the recording
    /// (D3) and stays a chord: a second button here would be a mode picker in a panel that opens
    /// after the user has stopped thinking about the dictation.
    func stopAndType() {
        send(Request(cmd: .stop, mode: .clean, attempt: model.snapshot?.attempt))
    }

    /// `Abort` — end it and deliver nothing. The speech still reaches the record (D26).
    func abort() {
        send(Request(cmd: .abort, attempt: model.snapshot?.attempt))
    }

    /// Sends one command on a thread of its own.
    ///
    /// The daemon does not answer before doing the work: a `stop` returns only after drain,
    /// recognition, the dictionary, the sanitiser and the keystrokes, all of it inside the socket's
    /// handler lock. That is seconds, on the caller's thread. On the main actor it would freeze the
    /// panel — and worse, the glyph — for precisely the interval the UI exists to display.
    private func send(_ request: Request) {
        let path = socketPath
        offMain("command") { [weak self] in
            // The answer is deliberately dropped. Every consequence of this command arrives on the
            // watch stream, which is the one description of the daemon's state this UI has; a
            // second one taken from a response would be a second source that could disagree with
            // it. A failure to reach the daemon shows up there too, as the link going down.
            _ = try? ControlClient.send(request, to: path)
            Task { @MainActor [weak self] in self?.refreshRecent() }
        }
    }

    // MARK: - the world

    /// Runs work off the main actor on a real `Thread`.
    ///
    /// Not `DispatchQueue.global()`, and not a queue targeting it: on Darwin, Swift concurrency's
    /// executor shares that non-overcommit pool, and it does not grow when its threads block. A
    /// `stop` parked in there for the length of a dictation is one worker that is not running the
    /// watch stream. The daemon's socket server follows the same rule, for the same measured
    /// reason.
    private func offMain(_ name: String, _ work: @escaping @Sendable () -> Void) {
        let thread = Thread { work() }
        thread.name = "dev.personal.dicta.menu.\(name)"
        thread.start()
    }

    /// One subprocess, its stdout as text. Failure is an empty string: everything this runs is a
    /// caption, and a caption that cannot be resolved falls back to the id.
    nonisolated private static func capture(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - what the buttons do

    func perform(_ action: Banner.Action) {
        switch action {
        case .openMicrophoneSettings:
            // The exact pane, not the top of System Settings: a banner that says "grant the
            // microphone" and then drops the user at a search field has not helped them.
            let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            if let url = URL(string: url) { NSWorkspace.shared.open(url) }
        case .fetchModels:
            // Six hundred megabytes, so it is a deliberate act rather than something the daemon
            // does at login on whatever network the laptop woke up on.
            run("/bin/sh", ["-c",
                            "\"$HOME/Applications/Dicta.app/Contents/MacOS/Dicta\" --fetch-models"])
        case .restartDaemon:
            restartDaemon()
        case .openSetup:
            openSetup()
        }
    }

    // MARK: - the setup window (D27, D31)

    /// Everything the window decides, over the latest snapshot. A lost link carries no snapshot, so
    /// the window says setup is unavailable rather than offering a choice nobody can receive.
    var setup: SetupModel {
        SetupModel(snapshot: model.snapshot, accessibilityRequested: accessibilityRequested)
    }

    /// Opens the setup window and brings it forward: from the "Set Up…" row, from a banner, or at
    /// the first snapshot of a launch.
    func openSetup() {
        let controller = setupWindowController ?? SetupWindowController(
            content: { [unowned self] in AnyView(SetupView(model: self)) },
            becameKey: { [weak self] in self?.setupBecameKey() },
            closed: { [weak self] in self?.setupClosed() })
        setupWindowController = controller
        controller.show()
    }

    /// A button in the window. What it sends is `SetupModel`'s; a control the current screen no
    /// longer draws sends nothing.
    func setupClicked(_ control: SetupControl) {
        let effect = setup.effect(of: control)
        guard !effect.isNothing else { return }
        if control == .allowAccess { accessibilityRequested = true }
        apply(effect)
    }

    /// The window opened or became key: the person may be back from System Settings, so the grant
    /// is checked — under `other-apps` only, and never with a prompt.
    private func setupBecameKey() {
        apply(setup.effectOfBecomingKey)
    }

    /// The window closed. Only the first-time offer records anything: closing it is an answer.
    private func setupClosed() {
        apply(setup.effectOfClosing)
    }

    /// Sends what an effect names, through `setupSender`, in the order the window reported it. The
    /// answer is dropped as every other command's is: a saved choice and a failed write both arrive
    /// on the watch stream, as `setup.saveError` for the second.
    private func apply(_ effect: SetupEffect) {
        if let request = effect.request { setupSender.enqueue(request) }
        if let url = effect.url { NSWorkspace.shared.open(url) }
        if let action = effect.action { perform(action) }
    }

    /// `launchctl kickstart -k`, which is why the footer says Restart and not Quit: launchd's
    /// `KeepAlive` would undo a quit within ten seconds, and a control that cannot do what it says
    /// must not exist.
    func restartDaemon() {
        run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(Paths.bundleID)"])
    }

    func openRecord() {
        NSWorkspace.shared.activateFileViewerSelecting([Paths.current.record])
    }

    private func run(_ executable: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try? process.run()
    }
}

private extension MenuModel {
    /// The reason carried by an `.end` already received, if that is the state we are in.
    var lastEndReason: String? {
        if case let .ended(reason) = link { return reason }
        return nil
    }
}
