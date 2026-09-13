import Combine
import DictaCore
import DictaIPC
import DictaRecord
import Foundation

/// Owns the `watch` connection and publishes a `MenuModel` (D27).
///
/// Wiring, and as little of it as possible: every decision this makes — which glyph, which banner,
/// how long to wait before retrying — is a pure value in `DictaCore`, where the test runner can
/// reach it. What is left here is a connection, a few threads and a `@Published`, and every one of
/// them arrives through `MenuWorld`, so the wiring is reachable from the test runner too.
///
/// **The connection runs on a real `Thread`, and that is not a style choice.**
/// `ControlClient.watch` blocks for the lifetime of the stream, and on Darwin, Swift's executor
/// shares the non-overcommit pool `DispatchQueue.global()` draws from — a watcher parked on a
/// cooperative thread for hours is one worker that never comes back. The daemon's own socket
/// server follows the same rule for the same measured reason. `MenuWorld.offMain` is that thread.
@MainActor
public final class StatusViewModel: ObservableObject {
    @Published public private(set) var model: MenuModel
    /// Ticks the timer between events. The daemon sends nothing while the user is speaking — there
    /// is no transition to report — so the seconds are counted here from the last known figure.
    @Published public private(set) var now: Date

    /// The last few attempts, newest first (Tier 1). Re-read when an attempt ends and when the
    /// panel is opened, never on a timer: the record only changes when a dictation does.
    @Published public private(set) var recent: [DictationRow] = []
    /// What the live attempt's session is CALLED, once a tree has been asked. `nil` means the
    /// caption falls back to the session id, which is always true and merely less friendly.
    @Published private(set) var targetName: String?

    private let world: MenuWorld
    private let socketPath: String
    private let recordURL: URL
    private var running = false
    private var failures = 0
    private var ticker: MenuCancel?
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
    @Published public private(set) var accessibilityRequested = false
    /// Answers `true` on the first snapshot of this process and never again (`FirstSnapshotLatch`).
    private var firstSnapshot = FirstSnapshotLatch()
    /// What shows the setup window. Held weakly, as acta's coordinator holds its reminder panel:
    /// the app owns the controller, and attaches it before `start()` so the first snapshot of a
    /// launch has somewhere to open the window.
    public weak var setupPresenter: (any SetupWindowPresenting)?
    /// The window's requests, delivered in the order they were made (`OrderedSender`). Not `send`:
    /// a thread per request would let a slow first click land after a second one and overwrite it.
    private let setupSender: OrderedSender<Request>

    public init(world: MenuWorld,
                socketPath: String = Paths.current.socket.path,
                record: URL = Paths.current.record) {
        self.world = world
        self.socketPath = socketPath
        recordURL = record
        setupSender = OrderedSender(name: "dev.personal.dicta.menu.setup") { request in
            // Dropped, as `send` drops it: every consequence arrives on the watch stream.
            try? world.send(request, socketPath)
        }
        now = world.now()
        // Seeded SYNCHRONOUSLY, before the first frame is drawn. acta's `ControlViewModel` does the
        // same thing and it is the detail most worth copying: without it the panel flashes blank
        // every single time it is opened, which reads as a broken app rather than a loading one.
        model = MenuModel(link: world.socketExists(socketPath) ? .connecting : .notRunning)
    }

    /// Starts watching, and keeps watching across daemon restarts. Idempotent.
    public func start() {
        guard !running else { return }
        running = true
        connect()
        refreshRecent()
    }

    /// Called every time the panel appears. `start()` is idempotent; the record is re-read anyway,
    /// because a dictation may have been delivered by a chord while the panel was closed and the
    /// drawer is the one part of this UI that is not driven by the stream.
    public func panelAppeared() {
        start()
        panelOpen = true
        updateTicker()
        refreshRecent()
        resolveTargetName()
    }

    /// The panel was dismissed. The relative times in the drawer stop needing a second hand, so the
    /// ticker goes back to being driven by whether a microphone is open.
    public func panelDisappeared() {
        panelOpen = false
        updateTicker()
    }

    private func connect() {
        let world = world
        let path = socketPath
        let deliver: @Sendable (WatchEvent) -> Void = { [weak self] event in
            let received = world.now()
            world.toMain { [weak self] in self?.receive(event, at: received) }
        }
        world.offMain("watch") { [weak self] in
            // An absent socket is "not running", with no launch-on-demand: a UI that started the
            // daemon because somebody glanced at the menu bar would be deciding something the user
            // did not ask for.
            guard world.socketExists(path) else {
                world.toMain { [weak self] in self?.finished(.notRunning) }
                return
            }
            do {
                try world.watch(path, deliver)
                // Returning normally means the daemon ENDED the stream — a clean shutdown. Only an
                // `.end` frame gets here; anything else throws.
                world.toMain { [weak self] in
                    self?.finished(.ended(self?.model.lastEndReason ?? "it was stopped"))
                }
            } catch {
                let link = Self.link(for: error)
                world.toMain { [weak self] in self?.finished(link) }
            }
        }
    }

    /// Which `DaemonLink` an error means. The distinction that matters: "there is no daemon" is
    /// ordinary and quiet, "the daemon stopped answering" is not.
    nonisolated private static func link(for error: any Error) -> DaemonLink {
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
            model = MenuModel(link: link, snapshot: nil, receivedAt: world.now())
        }
        guard running else { return }
        let delay = Backoff.delay(afterFailures: failures)
        failures += 1
        world.after(delay) { [weak self] in
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
            ticker?.cancel()
            ticker = nil
            return
        }
        now = world.now()
        ticker = world.scheduleTicker(1) { [weak self] in
            guard let self else { return }
            self.now = self.world.now()
        }
    }

    // MARK: - the receipt drawer (Tier 1)

    /// Re-reads the last few attempts.
    ///
    /// Bounded by `RecordReader`, on a thread of its own. The record is append-only and grows for
    /// ever, and this runs every time the panel opens — the two facts together are why Task 5
    /// existed at all.
    func refreshRecent() {
        let world = world
        let url = recordURL
        world.offMain("record") {
            let entries = try? world.readRecent(url, Self.recentCount)
            let rows = DictationRow.rows(from: entries ?? [])
            world.toMain { [weak self] in self?.recent = rows }
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
    public func copy(_ text: String) {
        world.effects.copy(text)
    }

    // MARK: - the live target line

    /// The caption for the live attempt, resolved as far as it can be.
    public var targetCaption: String? {
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
        guard resolvingName != session, let tool = world.locateAgterm() else { return }
        resolvingName = session
        let world = world
        world.offMain("tree") {
            let found = world.sessionNames(tool)
            world.toMain { [weak self] in
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
    public func stopAndType() {
        send(Request(cmd: .stop, mode: .clean, attempt: model.snapshot?.attempt))
    }

    /// `Abort` — end it and deliver nothing. The speech still reaches the record (D26).
    public func abort() {
        send(Request(cmd: .abort, attempt: model.snapshot?.attempt))
    }

    /// Sends one command on a thread of its own.
    ///
    /// The daemon does not answer before doing the work: a `stop` returns only after drain,
    /// recognition, the dictionary, the sanitiser and the keystrokes, all of it inside the socket's
    /// handler lock. That is seconds, on the caller's thread. On the main actor it would freeze the
    /// panel — and worse, the glyph — for precisely the interval the UI exists to display.
    private func send(_ request: Request) {
        let world = world
        let path = socketPath
        world.offMain("command") {
            // The answer is deliberately dropped. Every consequence of this command arrives on the
            // watch stream, which is the one description of the daemon's state this UI has; a
            // second one taken from a response would be a second source that could disagree with
            // it. A failure to reach the daemon shows up there too, as the link going down.
            try? world.send(request, path)
            world.toMain { [weak self] in self?.refreshRecent() }
        }
    }

    // MARK: - what the buttons do

    public func perform(_ action: Banner.Action) {
        switch action {
        case .openMicrophoneSettings:
            // The exact pane, not the top of System Settings: a banner that says "grant the
            // microphone" and then drops the user at a search field has not helped them.
            let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            if let url = URL(string: url) { world.effects.openURL(url) }
        case .fetchModels:
            // Six hundred megabytes, so it is a deliberate act rather than something the daemon
            // does at login on whatever network the laptop woke up on.
            world.effects.run("/bin/sh", ["-c",
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
    public var setup: SetupModel {
        SetupModel(snapshot: model.snapshot, accessibilityRequested: accessibilityRequested)
    }

    /// Opens the setup window and brings it forward: from the "Set Up…" row, from a banner, or at
    /// the first snapshot of a launch.
    public func openSetup() {
        setupPresenter?.show()
    }

    /// A button in the window. What it sends is `SetupModel`'s; a control the current screen no
    /// longer draws sends nothing.
    public func setupClicked(_ control: SetupControl) {
        let effect = setup.effect(of: control)
        guard !effect.isNothing else { return }
        if control == .allowAccess { accessibilityRequested = true }
        apply(effect)
    }

    /// The window opened or became key: the person may be back from System Settings, so the grant
    /// is checked — under `other-apps` only, and never with a prompt.
    public func setupBecameKey() {
        apply(setup.effectOfBecomingKey)
    }

    /// The window closed. Only the first-time offer records anything: closing it is an answer.
    public func setupClosed() {
        apply(setup.effectOfClosing)
    }

    /// Sends what an effect names, through `setupSender`, in the order the window reported it. The
    /// answer is dropped as every other command's is: a saved choice and a failed write both arrive
    /// on the watch stream, as `setup.saveError` for the second.
    private func apply(_ effect: SetupEffect) {
        if let request = effect.request { setupSender.enqueue(request) }
        if let url = effect.url { world.effects.openURL(url) }
        if let action = effect.action { perform(action) }
    }

    /// `launchctl kickstart -k`, which is why the footer says Restart and not Quit: launchd's
    /// `KeepAlive` would undo a quit within ten seconds, and a control that cannot do what it says
    /// must not exist.
    public func restartDaemon() {
        world.effects.run("/bin/launchctl",
                          ["kickstart", "-k", "gui/\(getuid())/\(Paths.bundleID)"])
    }

    /// Shows the record in Finder: the file this model reads, not a path looked up again.
    public func openRecord() {
        world.effects.revealInFinder(recordURL)
    }
}

private extension MenuModel {
    /// The reason carried by an `.end` already received, if that is the state we are in.
    var lastEndReason: String? {
        if case let .ended(reason) = link { return reason }
        return nil
    }
}
