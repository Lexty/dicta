# The setup window's layout loop, and dead watchers that keep their slots

## Overview

Two defects observed together on 2026-09-14, installing `85665d7`, and filed as
`docs/backlog/setup-window-constraint-loop-crash.md` and
`docs/backlog/dead-watchers-hold-slots-while-idle.md`.

- **DictaMenu dies when the setup window opens.** On a migrated install the offer is pending, the
  window opens by itself on the first snapshot, and about three seconds later AppKit raises
  `NSGenericException` ("more Update Constraints in Window passes than there are views in the
  window") and `_crashOnException` kills the process. launchd's `KeepAlive` turns that into a crash
  loop. Until it is fixed, a pending offer makes the menu unusable. The suspected cause, not yet
  verified, is `hosting.sizingOptions = [.preferredContentSize]` feeding the size of wrapping text back
  into the window.
- **A watcher whose client died keeps its slot while the daemon is idle.** `ControlServer` reads
  nothing after the `watch` handshake and finds a dead peer only when a write fails, and an idle
  daemon writes nothing. After `ControlTimeouts.maxWatchers` (4) such deaths, every new watcher is
  refused, and only a daemon restart frees the slots. The crash loop above filled them in minutes.
  Derived from the code but not observed: the client's own `watchIdle` (3600 s) closes and
  reconnects, so an idle daemon leaks about one slot an hour even with no crashes at all.
- **The refusal is misdrawn.** A refused watch becomes `DaemonLink.failed`, and the header says "dicta
  is not answering" about a daemon that answered.

Both fixes take acta's approach, per the rule that a question the two apps share is settled once:

- the window is sized as acta's `ReminderPanelController` sizes its panel;
- the watch stream ends on the read side, as acta's `ControlConnection` ends it.

The refusal has no acta counterpart: acta's menu observes `ControlViewModel` in-process, with no
socket to be refused on. So no acta backlog item is owed for any of the three.

## Context (from discovery)

- **Files involved:**
  - `Sources/DictaMenu/SetupWindow.swift`: `SetupWindowController.make` uses `NSHostingController`
    with `sizingOptions = [.preferredContentSize]` at `:49`; `SetupView` fixes its width with
    `.frame(width: 440)` and wraps text with `.fixedSize(horizontal: false, vertical: true)`.
  - `Sources/DictaIPC/ControlSocket.swift`:
    - `ControlServer.Watcher` (`:396`) is an `NSCondition` outbox holding one event.
    - `stream(to:watcher:)` (`:740`) writes until `next()` returns `nil` or a write fails.
    - `serve` registers the watcher and removes it in a `defer`.
    - `publish` (`:713`) and `stop` (`:569`, `finish(.end)`) are the outbox's other callers.
    - `ControlTimeouts.watchIdle` (`:91`) and the comment at `stream(to:)` both state the rule this
      plan replaces.
  - `Sources/DictaCore/MenuModel.swift`: `DaemonLink` (`:17`); `presentation` (`:95`) and `banner`
    (`:110`) switch over it; `Presentation.unreachable` (`:266`).
  - `Sources/DictaMenuKit/StatusViewModel.swift`: `link(for:)` (`:142`) maps a client error to a
    link; `finished(_:)` (`:180`) records it and schedules the backoff retry.
  - Tests:
    - `Sources/DictaTestRunner/WatchStreamTests.swift`: the `Watcher` helper, `makeServer`,
      `waitForWatchers`, and the cap test at `:187`.
    - `Sources/DictaTestRunner/MenuModelTests.swift`.
    - `Sources/DictaTestRunner/StatusViewModelTests.swift` with `MenuWorldFakes.swift`
      (`FakeMenuWorld`).
    - `Sources/DictaTestRunner/DaemonLockTests.swift`: `startupTakesTheLockFirst` is the source-check
      pattern.
    - `Sources/DictaTestRunner/MenuBundleTests.swift`.
  - Documentation:
    - `SPEC.md` §7 (`:1399`), with the watcher-cap row at `:1455`;
    - `docs/manual-checklist.md`, where H35–H47 exist and H48 and H49 are free;
    - `AGENTS.md` (`:120`, `:551`, `:1148` mention `SetupWindow.swift`).
- **acta patterns** (branch `dev`):
  - `Sources/Acta/ReminderPanel.swift:77-84`: `NSHostingView`, a fixed width, height from
    `fittingSize`, set with `setContentSize`, measured again at each new `show`, and left alone on an
    in-place update.
  - `Sources/ActaRuntime/ControlConnection.swift:121-172`: `streamEvents` races a pump against
    `awaitPeerDisconnect`; EOF or any unsolicited byte ends the watch, with no deadline on an idle
    one.
- **Verified:**
  - `ControlClient.watch` never calls `shutdown`, so a live client never looks like EOF;
  - `Watcher.cancel()` has no caller today.
- **Dependencies:** none new. `poll`, `pipe` and `fcntl` come from Darwin, as they already do in
  `acceptLoop`.

## Development Approach

- **testing approach**: TDD. Write the failing test, watch it fail for the stated reason, then make it
  pass.
- Task 1 is a measurement and changes no committed code. It has no tests, and nothing after it starts
  until its result is recorded here.
- Complete each task fully before moving to the next, in small, focused changes.
- **CRITICAL: every task MUST include new/updated tests** for the code it changes, success and error
  paths both.
- **CRITICAL: all tests must pass before starting the next task.** The gate is
  `bash Scripts/test.sh`, never `swift test`, which gates nothing here (AGENTS.md).
- **CRITICAL: update this plan file when scope changes during implementation.**
- Run `Scripts/lint.sh` with every task. Its built-in checks (100 columns, no Cyrillic, no trailing
  whitespace) must pass.
  - ⚠️ SwiftLint 0.65.1 appeared on this Mac on 2026-09-14 (Homebrew, 08:50), and the script runs
    it whenever it is on `PATH`. On `main` at `fa89b69` it reports 235 violations, none of them from
    this plan, so the script exits 1 before any change here.
  - Until the user decides what to do with that baseline, the gate for this plan is: built-in checks
    pass, and the SwiftLint count does not rise above the baseline taken at the start of Task 2.
    Every later "run `Scripts/lint.sh`" and "must pass" in this plan means exactly this gate.
- Work on a branch off `main` (`fa89b69`), e.g. `dicta-setup-window-and-watchers`.

## Testing Strategy

- **Unit tests** go through the custom runner (`DictaTestRunner`), required for every code task.
- **No UI e2e suite exists.** No test draws the setup window. What code can hold is held by a source
  check; that the window opens, survives each screen and comes forward is scored by a person (H48,
  plus the unscored H35, H41 and H47).
- **Mutation checks**, recorded in the task:
  - with `next(watching:)` ignoring the client (outbox only, as the `NSCondition` did), the
    dead-client tests must fail;
  - with `watchRefused` mapped back to `.failed`, the refusal tests must fail.

## Progress Tracking

- Mark completed items with `[x]` immediately when done.
- Add newly discovered tasks with a ➕ prefix.
- Record issues and blockers with a ⚠️ prefix.
- Keep the plan in sync with the work when it deviates.

## Solution Overview

1. **Measure first.** The cause is a suspicion. The installed menu crashes on every launch while the
   offer is pending, which is a reproduction available on this Mac today. The fix is chosen only once
   the exception is seen, and seen to go away with the candidate.
2. **Size the window explicitly, as acta sizes its panel.** The window never follows the
   content's preferred size (`.preferredContentSize` is gone):
   - the window's content is an `NSHostingView`;
   - its height is read from `fittingSize` and set by the controller, at `show()` and when what the
     window draws changes;
   - the measurement runs on a later main run-loop turn, never inside a layout pass, so nothing a
     layout pass does can ask for another one.
   - dicta re-measures on a content change where acta does not. The domain forces it: acta builds a
     new presentation per prompt and calls `show` again, while dicta's window changes screen in place
     (offer to checklist, a save error appearing). It is the same measurement at the same kind of
     moment.
3. **End the watch on the read side, as acta does.** The writer thread no longer waits only for the
   outbox; it waits in `poll` on the outbox's wake pipe and on the client. A readable client (EOF or
   an unsolicited byte), `POLLHUP` or `POLLERR` ends the stream at once, and `serve`'s `defer` frees
   the slot.
   - One thread per watcher, as now, rather than acta's two racing tasks: dicta serves connections on
     real threads for the measured reason given in `acceptLoop`.
   - A second reader thread would need a `shutdown` and a join before `close` so that it never reads
     a reused descriptor; `poll` on one thread needs neither.
4. **Tell a refusal from a failure.** `DaemonLink.refused(reason)` draws amber rather than red,
   because the daemon answered, and carries the daemon's reason and the one action that frees a slot.

## Technical Details

### Setup window (`Sources/DictaMenu/SetupWindow.swift`)

- `SetupWindowController` gains:
  - `private var hosting: NSHostingView<SetupView>?`;
  - `private var observation: AnyCancellable?`, the model's `objectWillChange`, received on the main
    run loop.
- `make(_:)`:
  - `let hosting = NSHostingView(rootView: SetupView(model: model))`;
  - `window.contentView = hosting` on an `NSWindow(contentRect:styleMask:backing:defer:)` built with
    `[.titled, .closable]` from the start, so the style never changes after the content is attached.
  - No `NSHostingController`. `sizingOptions` is left at its default, as acta does (Task 1: `[]`
    makes `fittingSize` read zero).
- `fitHeight()`:
  - `let size = hosting.fittingSize`;
  - if `abs(size.height - window.contentRect(forFrameRect: window.frame).height) < 1`, return;
  - otherwise compute the new frame from `window.frameRect(forContentRect:)` and keep `frame.maxY`
    fixed, so the title bar does not jump when the checklist replaces the offer;
  - `window.setFrame(_, display: true)`.
- **When `fitHeight()` runs:**
  - in `show()` before `center()`;
  - from the observation, via `RunLoop.main.perform` (or `DispatchQueue.main.async`), only while the
    window is visible. `objectWillChange` fires before the change, so measuring on a later turn is
    required anyway, not only for the layout reason.
  - The model also publishes `now` once a second while the ticker runs, so `fitHeight()` runs on
    changes that have nothing to do with the window. That is harmless: the 1 pt skip makes it a
    measurement, and nothing a layout pass does changes the model, so it cannot loop.
- `SetupView` keeps `.frame(width: 440, alignment: .leading)` and every `.fixedSize(horizontal: false,
  vertical: true)`: with the width fixed, they only let text wrap.
- If Task 1 finds a different cause, this section is rewritten before Task 2 starts.

### Watcher outbox (`Sources/DictaIPC/ControlSocket.swift`)

```swift
private final class Watcher {
    private let lock = NSLock()
    private var pending: WatchEvent?   // guarded by lock
    private var ending: WatchEvent?    // guarded by lock
    private var done = false           // guarded by lock
    private let wakeRead: Int32        // O_NONBLOCK | O_CLOEXEC
    private let wakeWrite: Int32       // O_NONBLOCK | O_CLOEXEC

    init(wakeRead: Int32, wakeWrite: Int32)
    static func make() throws(WatchRefusal) -> Watcher  // pipe() + fcntl
    func post(_ event: WatchEvent)     // guard !done; set pending; wake()
    func finish(_ event: WatchEvent)   // guard !done, ending == nil; set ending; wake()
    func next(watching client: Int32) -> WatchEvent?
    deinit                             // close both pipe ends
}
```

- `cancel()` has no caller today and is deleted rather than carried over.
- `make()` creates the pipe and sets `O_NONBLOCK` and `FD_CLOEXEC` on **both** ends. Any failure
  closes whatever it opened and throws `.cannotOpen(code:)`; a watcher never runs with a blocking
  write end, which is the premise that `publish` never blocks.
- `wake()` writes one byte to `wakeWrite`:
  - it retries on `EINTR`, so an interrupted write can never leave `pending` set with no wake;
  - `EAGAIN`/`EWOULDBLOCK` means the pipe is full, and a full pipe is a writer already woken;
  - any other error is ignored, because both ends are closed only in `deinit`, which no caller of
    `wake()` can outlive.
- Both pipe ends are closed **only** in `deinit`, never on `next`'s exit paths. `serve` holds the
  registration through the stream, and `publish`/`stop` hold strong copies, so no `post` can write to
  a closed or reused descriptor.
- `next(watching:)` loops:
  1. Under `lock`, note whether an event is ready (`pending` or `ending`), or return `nil` when
     `done`.
  2. `poll([wakeRead POLLIN, client POLLIN], 2, ready ? 0 : -1)`. `EINTR` goes back to 2; any other
     error returns `nil`.
  3. If `client`'s `revents` is nonzero, return `nil`. That covers `POLLIN` (EOF or a byte: the peer
     closed or talked after the handshake, and a watcher does not talk, which is acta's rule),
     `POLLHUP`, `POLLERR` and
     `POLLNVAL`. Treating any bit as the end is what keeps a `POLLNVAL`, which `poll` reports
     unasked, from spinning the thread. Nothing is read from `client`.
  4. If `wakeRead`'s `revents` has anything but `POLLIN`, return `nil`. If it has `POLLIN`, drain it:
     `read` retries `EINTR` and stops at `EAGAIN`/`EWOULDBLOCK`; a `0` (EOF) or any other error
     returns `nil`, never a retry that would spin.
  5. Under `lock`, return `pending` (cleared), else `ending` (cleared, `done = true`); otherwise go
     back to 1.
- **The client is checked before every event, not only while idle.** The zero-timeout `poll` in step
  2 means a client that closed or talked is noticed even while the daemon publishes continuously. A
  pending event for a gone client is dropped rather than written into a failing write.
- **If `pipe()` fails** (`EMFILE`), the client still gets an ordinary refusal, never a dropped
  connection, per the rule of the §7 row, and the refusal says why:
  - `registerWatcher()` returns `Result<(id: Int, watcher: Watcher), WatchRefusal>`, where
    `WatchRefusal` is `.full` or `.cannotOpen(code: Int32)`;
  - `serve` builds the message from it: the existing "dicta is already serving \(maxWatchers)
    watchers", or "dicta could not open a watch stream: <strerror>".
- **"Any byte" means any byte the server has not already read.** `serve` reads the request with
  `Framing.readFrame` (`ControlSocket.swift:265-284`), which discards whatever arrived after the
  newline in the same `read`. A client that sends `watch` plus a newline plus more bytes in one
  write has that tail swallowed, and stays watched while it keeps the socket open.
  - acta has the same boundary: its `FrameReader` and that reader's buffer live only inside
    `readRequestFrame` (`ControlConnection.swift:66`).
  - So the rule is stated, in code comments and SPEC, as bytes arriving after the handshake is read,
    and the test sends its byte only after reading the accepted response. No stronger promise is made.
- `stream(to:watcher:)` calls `watcher.next(watching: client)`; the write path and the `.end` return
  are unchanged.
- **Cost of an idle watcher:** one parked thread in one `poll` and two descriptors. With
  `maxWatchers == 4`, that is at most eight extra descriptors.

### Refused link (`Sources/DictaCore/MenuModel.swift`, `Sources/DictaMenuKit/StatusViewModel.swift`)

- `DaemonLink` gains `case refused(String)`: the daemon answered and declined the watch.
- `presentation`: `.refused` → `Presentation.refused`, with glyph `exclamationmark.triangle.fill`,
  tint `.amber` and status `"dicta refused to be watched"`.
- `banner`: `.refused(reason)` → `Banner(text: reason, tint: .amber, action: .restartDaemon,
  actionTitle: "Restart dicta")`.
- `link(for:)`: `case let .watchRefused(reason): return .refused(reason)`.
- `finished(_:)` is unchanged: it records the link and schedules `Backoff`; the retry reconnects once
  a slot frees. `updateTicker` still counts only on `.connected`.
- Every other exhaustive `switch` over `DaemonLink` is found by the compiler.

## What Goes Where

- **Implementation Steps** (`[ ]`): the measurement, code, tests, SPEC, checklist and repository
  docs.
- **Post-Completion** (no checkboxes): the human items only a person at the Mac can score, and
  installing the build.

## Implementation Steps

### Task 1: Reproduce the crash and confirm its cause (measurement only)

**Files:**
- Modify: `docs/plans/20260914-dicta-setup-window-and-dead-watchers.md` (the result, recorded
  here)

- [x] ask the user before touching launchd or the daemon's state; every step below that restarts
      the daemon or rewrites `setup.json` needs that go-ahead
  - ⚠️ run non-interactively (ralphex loop), so no go-ahead could be asked for. Nothing that needs
    one was done: the daemon, `setup.json` and launchd were never touched. The measurement was taken
    instead against a fake daemon (below), which needs no go-ahead and leaks no watcher slot.
- [x] record the starting state, to be restored at the end: whether the menu's LaunchAgent is
      loaded (`launchctl list`; it was not at planning time, 2026-09-14), and `setup.json` copied
      aside. If the agent is loaded, `launchctl bootout` it so no crash loop runs beside the probe
  - recorded 2026-09-14 10:43: `dev.personal.dicta.menu` is not loaded (its plist is in
    `~/Library/LaunchAgents`); the daemon `dev.personal.dicta` is loaded, PID 17524, and was still
    PID 17524 after the probe. `setup.json` was not copied aside because it was never written.
- [x] **the controlled restore**, used between stateful runs and at the end, in this order:
  1. end the probe menu and wait until it has exited, so no close or `configure` effect is still in
     flight;
  2. stop the daemon;
  3. restore `setup.json` from the copy;
  4. start the daemon;
  5. confirm the daemon is up with `dictactl status` (`idle`).

  This checks the restored file and a confirmed restart, **not** the live choice: `dictactl status`
  prints only the state or a message (`Sources/dictactl/main.swift:176-181`), never `scope` or
  `offerSeen`. The live choice is read from the probe's own first watch snapshot, below. No
  `dictactl watch` is added as a diagnostic before Task 3: each one that is ended leaks another
  slot.

  Restoring the file alone is not enough: `SetupStore.bootstrap` reads it only at start-up
  (`SetupStore.swift:146-169`), and a running daemon keeps the choice scenario (b) made in memory.

  - (skipped, not needed: no run touched the daemon. Each probe process owned its own fake daemon,
    so every run started from its own fresh state, which is what the restore exists to give.)
- [x] **before every probe run**, a controlled restore (which also frees any watcher slot a previous
      crash leaked), then confirm the preconditions the run needs:
  - `dictactl status` is `idle`;
  - the probe's first watch snapshot, observed in `lldb` (the same snapshot whose receipt the run
    records), carries `state: idle`, `scope: agtermOnly` and `offerSeen: false`. `shouldAutoOpen`
    (`SetupModel.swift:150-157`) needs all three in the first snapshot; `otherApps` never auto-opens.
    Scenarios (b) and (c) record the snapshot they start from the same way;
  - the probe accepts its watch. Before Task 4, a refusal is drawn as the red banner "dicta refused to
    be watched: dicta is already serving 4 watchers" under the header "dicta is not answering"
    (`StatusViewModel.swift:142-149`, `MenuModel.swift:103-104`); either one makes the run
    inconclusive.

  - held by construction in the probe: the fake daemon's first event is `state: idle`,
    `scope: agtermOnly`, `offerSeen: false` (`offerSeen: true` for (c), so nothing auto-opens and
    "Set Up…" is what opens it), and every run logged `link=connected`.
- [x] **what a run records**, each item positively observed, by a screenshot or in `lldb`:
  - the watch was accepted (the header shows the daemon's state, not a failure);
  - the scope, `offerSeen` and state of the first snapshot, read in `lldb`;
  - the expected screen actually visible;
  - then the window left open for one minute, or the exception with its stack.

  A run in which the expected screen never appeared is **inconclusive and repeated, never a pass**.

  - each run logged once a second for the first five and every five after: the link, `setup.heading`
    (the screen drawn), `window.isVisible` and the window frame; then `SURVIVED 60s` or the
    exception and its stack under `lldb`. No screenshots.
- [x] build with `Scripts/bundle.sh` and run `DictaMenu.app/Contents/MacOS/DictaMenu` under `lldb`:
      the bundle carries `LSUIElement`, and a bare `.build` executable activates differently. Record
      the exception text and the top of the stack for the offer opening by itself
  - ⚠️ deviation: not `DictaMenu.app`, which would watch the live daemon. A scratch, uncommitted
    executable target `SetupProbe` (deleted after, `Package.swift` restored) ran the same shape: a
    SwiftUI `App` with a `.window` `MenuBarExtra`, the real `StatusViewModel`, a verbatim copy of
    `SetupWindow.swift`, a `MenuWorld` whose `watch`/`send` were an in-process fake daemon that
    applies `configure`, all inside a hand-built `SetupProbe.app` with `LSUIElement`. It ran under
    `lldb --batch` on macOS 26.6.2, Swift 6.3.3, with a debug build.
  - **reproduced with the current code, in all four runs.** (a) the offer opening by itself threw
    about half a second after the window appeared, with the same text as the installed menu:
    `NSGenericException: The window has been marked as needing another Update Constraints in Window
    pass, but it has already had more Update Constraints in Window passes than there are views in
    the window.` (window `{440, 224}`). (b) threw on the offer before the click could happen.
    (c) threw right after "Set Up…" opened it. (d) threw as well.
  - **the cause, confirmed by the stack** (innermost first): `NSHostingView.setNeedsUpdate` ←
    `requestUpdate(after:)` ← `ViewGraph.setSize` ← `setProposedSize` ← `NSHostingView.updateSize` ←
    `ViewGraphRootValueUpdater._sizeThatFits` ← **`NSHostingController.preferredContentSize` getter**
    ← `-[NSViewController updateViewConstraints]` ← `-[NSWindow updateConstraintsIfNeeded]` ←
    `NSDisplayCycleFlush`. Reading the preferred content size inside the Update Constraints pass
    proposes a size, which marks the window as needing another Update Constraints pass, and so on.
    That is `sizingOptions = [.preferredContentSize]` feeding back into the window, as suspected.
- [x] apply the Task 2 candidate locally (uncommitted) and run three scenarios under `lldb`, each from
      a controlled restore:
  - (a) the offer opening by itself;
  - (b) the checklist screen, after "Set up dictation";
  - (c) "Set Up…" from the panel.

  Run the three twice: with `NSHostingView`'s default `sizingOptions`, and with `hosting.sizingOptions
  = []`. The default is believed to be `.standardBounds`, whose min/max constraints could fight an
  explicit `setFrame`; the SDK interface does not state the default.

  - The candidate followed Technical Details: an `NSHostingView` as `contentView` of an `NSWindow`
    built with `[.titled, .closable]`, `fitHeight()` (`layoutSubtreeIfNeeded`, then `fittingSize`, a
    1 pt skip, top edge kept) in `show()` before `center()` and from `objectWillChange` received on
    `RunLoop.main` while visible. ➕ A fourth scenario, (d) a save error arriving while the offer is
    open, ran with the three. (b) sent `enable` rather than "Set up dictation": on a migrated
    install the offer's button is "Enable", and both send the same `configure otherApps`.
  - **default `sizingOptions`** (measured `rawValue` 7): 4 of 4 survived 60 s, no exception.
    `fittingSize` measured the content: the offer 192.5 pt (window 440 × 225), the checklist
    387.5 pt (440 × 420), the offer with a save error 232.5 pt (440 × 265). The top edge stayed put
    across both resizes (`maxY` 768 before and after).
  - **`sizingOptions = []`**: 4 of 4 survived 60 s, but `fittingSize` read **(0, 0)** every time, so
    `fitHeight()` measured nothing. The window changed height anyway (224 → 419, 224 → 264), by some
    path this probe did not identify. Nothing Task 2 relies on holds under `[]`.
- [x] record the outcome in this task, including which `sizingOptions` Task 2 uses (the default when
      both survive, matching acta). If the exception persists with the candidate, or its stack points
      elsewhere, mark ⚠️, stop, and revise Task 2 with the user before continuing
  - **outcome:** the cause is confirmed and the candidate removes it. **Task 2 leaves `sizingOptions`
    at `NSHostingView`'s default**, as acta does. That is the choice the plan already made when both
    survive, and `[]` is also ruled out on its own terms: it zeroes the `fittingSize` the fix measures.
  - ⚠️ not yet seen on the installed menu against the real daemon, since that needs the user's
    go-ahead. The stack matches the installed crash's text exactly, but the probe differs in its
    daemon, its debug build and its bundle. Task 2's "with the user's go-ahead, repeat" step and H48
    remain the confirmation on the real thing.
- [x] finish:
  - discard the local candidate (`git restore`), so that Task 2 starts from its failing test;
  - do a controlled restore;
  - put the menu's LaunchAgent back in the loaded state recorded at the start.

  - the scratch target was deleted and `Package.swift` restored; `git status` is clean. No
    controlled restore was needed, since the daemon was never touched (PID 17524 before and after).
    The menu's LaunchAgent was never changed and is still not loaded.

### Task 2: Size the setup window explicitly, as acta sizes its panel

**Files:**
- Modify: `Sources/DictaMenu/SetupWindow.swift`
- Modify: `Sources/DictaTestRunner/MenuBundleTests.swift` (or a new source-check test beside it)

- [x] write the source-check test first:
  - `Sources/DictaMenu/SetupWindow.swift` contains neither `.preferredContentSize` nor
    `NSHostingController`. The text `sizingOptions` is not banned: Task 1 may choose `= []`;
  - it builds an `NSHostingView` and reads `fittingSize`;
  - `fitHeight()` is called in `show()` before `center()`.

  Watch the test fail against the current file.

  - `MenuBundleTests.setupWindowSizeIsSetNotTracked`. Comment lines are dropped before the banned
    words are looked for, so the header comment can still name `NSHostingController`. It also holds
    `window.contentView = hosting`, `layoutSubtreeIfNeeded()`, and an `objectWillChange`
    observation received on `RunLoop.main` with `[weak self]`. Against the old file it failed with
    7 issues, stopping at the missing `fitHeight()` in `show()`.
- [x] replace `NSHostingController` with `NSHostingView` as the window's `contentView`, built with its
      final style mask
- [x] add `fitHeight()`, which measures `fittingSize`, skips a change under 1 pt and keeps the top
      edge; call it from `show()` before `center()`
- [x] observe `model.objectWillChange` with `[weak self]`, and call `fitHeight()` on a later main
      run-loop turn while the window is visible. `fitHeight()` calls
      `hosting.layoutSubtreeIfNeeded()` before reading `fittingSize`, so it measures the new state
- [x] set `sizingOptions` as Task 1 recorded
- [x] rewrite the file's header comment on sizing: why the size is set rather than tracked, and
      acta's `ReminderPanelController` as the shape
- [x] run `bash Scripts/test.sh` and `Scripts/lint.sh` under the gate in Development Approach
      (tests pass; lint's built-in checks pass and SwiftLint stays at its baseline) before Task 3
  - 941 tests in 52 suites pass (`Scripts/test.sh`, which ran `linkage.sh` first), Swift 6.3.3,
    macOS 26.6.2. `swift build -c release --product DictaMenu` builds with no warning from the menu.
    Lint: the built-in checks pass; SwiftLint reports 235, the baseline. Two existing
    `MenuBundleTests` violations grew rather than new ones appearing: `file_length` 443 → 478
    lines and `type_body_length` 304 → 329.
  - mutation: with `fitHeight()` moved after `center()` in `show()`, the test fails ("show()
    centres before it measures"); restored.
- [x] with the user's go-ahead, repeat Task 1's three scenarios with this code, under Task 1's
      controlled restore, preconditions and recording rules, and record the result here
  - ⚠️ (skipped - not automatable here: the loop runs non-interactively, so no go-ahead could be
    asked for, and the installed menu against the real daemon was not run.) The nearest evidence is
    Task 1's probe, whose candidate had this shape and survived all four scenarios for 60 s. H48
    stays the confirmation.
- [x] if the user has asked for commits, commit Task 2 together with
      `git rm docs/backlog/setup-window-constraint-loop-crash.md`, only once the repeat above
      survived all three scenarios
  - committed on its own, as the loop commits every task. ⚠️ The backlog item was **not** removed:
    the repeat on the real menu has not run. It goes once H48, or that repeat, has passed; Task 7's
    check that it is gone must wait for that too.

### Task 3: End a watch when its client closes or talks

**Files:**
- Modify: `Sources/DictaIPC/ControlSocket.swift`
- Modify: `Sources/DictaTestRunner/WatchStreamTests.swift`

- [x] reuse the raw-connection pattern `deadWatcherIsDropped` already has
      (`ControlSocketTests.rawConnect`, a manual `watch` frame, `Framing.readFrame`), factored into a
      small helper only if a third test needs it
  - factored as `WatchStreamTests.rawWatch(_:)` (connect, `watch` frame, accepted response read,
    `rawConnect`'s 2 s read timeout kept), since four tests use it.
- [x] turn the existing `deadWatcherIsDropped` into test (a). Keep its `@Test` name, which
      `docs/manual-checklist.md:106` cites and `ChecklistTests` resolves. Remove its
      `publish(.update(state: .recording))`, and rewrite the comment claiming "the write that fails
      is what discovers the peer is gone". With nothing published, `watcherCount` must still reach
      0. Watch it fail
  - the `@Test` display name, which is what the checklist cites, and the function name are both
    kept. Against the old code it failed at `waitForWatchers(count: 0)` after 5 s.
- [x] write the other failing tests:
  - (b) `maxWatchers` raw watchers close silently, `waitForWatchers(count: 0)` (removal happens in
    `serve`'s `defer`, so a fifth connecting at once would race it), then a fifth ordinary `Watcher`
    is accepted and receives a published event;
  - (c) a raw watcher that sends one byte after the handshake has its watch ended and its slot freed,
    with nothing published.

  Watch (b) and (c) fail for the stated reason.
  - (b) `deadWatchersFreeTheirSlots`, (c) `talkingWatcherIsEnded`, which also reads EOF on the raw
    end once the slot is gone. Against the old code (b) failed with 5 issues, ending in the fifth
    watcher refused with "dicta is already serving 4 watchers", and (c) with 2: the count never
    reached 0 and the read timed out (`-1`) instead of reading EOF.
- [x] write the guard test: a live, silent raw watcher is still registered after 0.5 s and still
      receives the next published event, so no false end is taken for EOF
  - `silentWatcherIsKept`; it passed against the old code too, as a guard should.
- [x] replace `Watcher`'s `NSCondition` with the lock, the wake pipe and `next(watching:)` as in
      Technical Details; delete `cancel()`; `stream(to:watcher:)` passes `client`
  - the wait is split into `next(watching:)`, `wait(watching:blocking:)`, `take()` and
    `drainWake()`, which keeps the new code under SwiftLint's complexity limit. `Watcher.make()` uses
    typed throws, and `registerWatcher` catches it with `do throws(WatchRefusal)`. `publish`'s
    comment now describes a `post` as a lock plus one byte written to a non-blocking pipe.
- [x] give `registerWatcher` its `WatchRefusal` result and build both refusal messages in `serve`.
      The pipe-failure path has no seam and no test; say so in the task record rather than invent
      one
  - `WatchRefusal.message` builds both messages; the `.full` text is unchanged, and
    `watcherCapIsRefusedPolitely` still passes. The pipe-failure path (`.cannotOpen`) has no seam and
    no test: nothing in the suite can make `pipe()` or `fcntl` fail inside the server.
- [x] mutation check: make `next(watching:)` ignore the client (outbox only, as the `NSCondition`
      did). Tests (a)–(c) must fail; record the count, then restore it
  - mutation: `poll` over the wake pipe alone (count 1 instead of 2). 3 of 9 watch-stream tests
    fail, with 8 issues: (a), (b) and (c). The guard and the other five pass. Restored, and 9 of 9
    pass again.
- [x] rewrite the comments that state the old rule: `stream(to:)` ("a peer that has gone away is
      discovered by the write that fails", "no syscalls") and `ControlTimeouts.watchIdle` ("What
      actually detects a dead peer is the write that fails")
  - both rewritten; `Watcher`'s own header now carries the rule and acta's shape.
- [x] run `bash Scripts/test.sh` and `Scripts/lint.sh`. The existing cap, coalescing, `stop` and
      command-latency tests must pass unchanged
  - 944 tests in 52 suites pass (`Scripts/test.sh`, `linkage.sh` first), Swift 6.3.3, macOS
    26.6.2. The cap, coalescing, `stop` and command-latency tests passed unchanged. Lint: the
    built-in checks pass, and SwiftLint reports 235, the baseline. As in Task 2, three existing
    violations in `ControlSocket.swift` grew but none were added: `file_length` 1092 → 1216 lines,
    `ControlServer`'s `type_body_length` 317 → 395, and `serve`'s `cyclomatic_complexity` 11 → 12.
- [x] if the user has asked for commits, commit Task 3 on its own. The backlog item stays: its
      misdrawn refusal is Task 4's
  - committed on its own, as the loop commits every task; the backlog item stays.

### Task 4: Draw a refused watch as a refusal

**Files:**
- Modify: `Sources/DictaCore/MenuModel.swift`
- Modify: `Sources/DictaMenuKit/StatusViewModel.swift`
- Modify: `Sources/DictaTestRunner/MenuModelTests.swift`
- Modify: `Sources/DictaTestRunner/StatusViewModelTests.swift`

The seams exist: `FakeMenuWorld.script(_:then: .throwing(...))` and `fireAfter` cover every case
below, so `MenuWorldFakes.swift` needs no change.

- [x] write failing `MenuModelTests`:
  - `.refused` does not present `"dicta is not answering"`;
  - its tint is amber and its status is `"dicta refused to be watched"`;
  - its banner is amber, carries the reason verbatim and offers `.restartDaemon`;
  - `.failed` is unchanged (red, "not answering").
  - added as `refusedIsNotAFailure`, with `failedIsRed` extended to pin the status and the action.
    Against a stub case that drew `.refused` as `.failed`, it failed with 4 issues: status "not
    answering" (twice), presentation tint red, banner tint red.
- [x] write failing `StatusViewModelTests` through `FakeMenuWorld`:
  - `watch` throwing `ClientError.watchRefused("dicta is already serving 4 watchers")` gives
    `model.link == .refused(...)`;
  - a `ClientError.timedOut` still gives `.failed`;
  - after a refusal a retry is scheduled through `after`, and a later accepted watch reaches
    `.connected`.
  - added as `refusedWatchIsNotAFailure` and `refusedWatchRetries`. Against the stub both failed:
    the link was `.failed("dicta refused to be watched: dicta is already serving 4 watchers")`.
- [x] add `.refused` to the loop in `MenuModelTests.barIsQuietWhenIdle` (`:191`), so the strip
      and the header cannot disagree about it. The compiler does not flag that loop
- [x] add `DaemonLink.refused`, `Presentation.refused` and the banner case; fix every `switch` the
      compiler names
  - the compiler named none outside `MenuModel`: `swift build` of every product, `DictaMenu`
    included, is clean.
- [x] correct the two comments that call a refusal a failure: `DaemonLink.failed` ("The connection
      broke, or the daemon refused", `MenuModel.swift:30`) and `Presentation.unreachable` ("broke or
      was refused", `:266`)
- [x] map `watchRefused` in `link(for:)`
- [x] mutation check: map `watchRefused` back to `.failed`. The `StatusViewModelTests` above must fail;
      then restore it
  - mapped to `.failed(ClientError.watchRefused(reason).description)`: 2 of 61 tests in the two
    suites fail, exactly the two new `StatusViewModelTests`. Restored, all 61 pass.
- [x] run `bash Scripts/test.sh` and `Scripts/lint.sh` under the gate in Development Approach before
      Task 5
  - `bash Scripts/test.sh`: 947 tests in 52 suites pass (944 + 3 new), Swift 6.3.3.
    `Scripts/lint.sh`: built-in checks pass and SwiftLint reports 235, the baseline; the existing
    `type_body_length` of `StatusViewModelTests` grew 654 → 688 lines, and none was added.
- [x] if the user has asked for commits, commit Task 4 together with
      `git rm docs/backlog/dead-watchers-hold-slots-while-idle.md`: both halves of that item have now
      landed
  - committed with the backlog file removed.

### Task 5: SPEC §7, the manual checklist and the human items

**Files:**
- Modify: `SPEC.md`
- Modify: `docs/manual-checklist.md`

- [x] SPEC §7, amend the existing row "a watcher goes away mid-stream" (`SPEC.md:1454`) rather than
      add a near-duplicate: the daemon notices the close, or a byte arriving after the handshake
      was read, without writing anything, including while idle, and frees the slot at once; no
      dictation outcome changes.
      Keep the event cell verbatim, because `ChecklistTests` matches it against the checklist
- [x] SPEC §7, the watcher-cap row (`:1455`): the menu shows the refusal as a refusal (amber, the
      daemon's reason, "Restart dicta"), never as "not answering", and retries with backoff
- [x] add **H48**: the setup window opens and survives each screen, and a screen change while it is
      open:
  - (a) the offer opening by itself on a migrated install;
  - (b) "Set up dictation" turning it into the checklist;
  - (c) "Set Up…" from the panel;
  - (d) a save error appearing.

  Each resizes with the top edge in place, and the menu is still alive a minute later.
- [x] add **H49**: with the daemon idle, `kill -9` the menu five times. Each time the menu returns
      connected, and `lsof` on `control.sock` shows no connection without a live peer
- [x] update the Audit 2 lines in `docs/manual-checklist.md` that `ChecklistTests` pairs with §7:
  - "a watcher goes away mid-stream" (`:106`) cites Task 3's tests (a), (b) and (c) and the guard,
    by their exact `@Test` names, plus H49;
  - "the watcher cap is reached" (`:107`) adds Task 4's refusal tests.
- [x] note in H35, H41 and H47 that they are scored together with H48
- [x] run `bash Scripts/test.sh` (`ChecklistTests` gates these edits) and `Scripts/lint.sh`
  - `bash Scripts/test.sh`: 947 tests in 52 suites pass, `checklist` included, so every new
    `test:` citation resolves and the two amended §7 rows still pair by their verbatim events.
    Swift 6.3.3. `Scripts/lint.sh`: the built-in checks pass; SwiftLint reports 235, the baseline.
  - H48 (d) makes the save error with the `chmod a-w` of H42 (b). H49's pass is the daemon's
    `lsof ... | grep -c unix` count unchanged after five kills, beside the menu returning connected.
    H35, H41 and H47 each end with a note that they are scored together with H48.

### Task 6: Verify acceptance criteria

- [x] the offer, the checklist and "Set Up…" no longer raise the exception (Task 1 and Task 2
      records)
  - held in the probe only: Task 1's candidate, the shape Task 2 committed, survived all four
    scenarios for 60 s with the default `sizingOptions`, where the old code threw in all four.
    `setupWindowSizeIsSetNotTracked` holds that shape in source, and its mutation fails it (Task 2).
    ⚠️ Not seen on the installed menu against the real daemon: that repeat needs the user's go-ahead
    and is H48's to score.
- [x] a silently dead watcher frees its slot with the daemon idle, and a fifth watcher is accepted
      after four such deaths (Task 3 tests)
  - `deadWatcherIsDropped` ("a watcher that goes away is dropped, and the daemon keeps serving") with
    nothing published, `deadWatchersFreeTheirSlots` and `talkingWatcherIsEnded` pass.
- [x] a live silent watcher is never ended, and coalescing, `stop` and command latency are unchanged
  - `silentWatcherIsKept` passes, as do the untouched "a slow reader is given the newest state", "a
    daemon shutting down ENDS the stream", "past the cap a watcher is REFUSED" and "a watcher
    connected for the whole test never delays a command".
- [x] a refused watch draws amber with the reason and retries, and every other failure still draws
      red
  - `MenuModelTests.refusedIsNotAFailure` and `failedIsRed`, `barIsQuietWhenIdle` with `.refused`
    in its loop, and `StatusViewModelTests.refusedWatchIsNotAFailure` (a `timedOut` still `.failed`)
    and `refusedWatchRetries` pass. No person has looked at the amber banner yet.
- [x] run the full suite: `bash Scripts/test.sh`; record the test and suite counts and the toolchain
  - 947 tests in 52 suites pass, `linkage.sh` first. Swift 6.3.3 (swiftlang-6.3.3.1.3), macOS
    26.6.2.
- [x] run `Scripts/lint.sh`
  - exits 1 on the SwiftLint baseline alone: none of the built-in checks reports anything, and
    SwiftLint 0.65.1 reports 235 violations, the baseline taken at the start of Task 2.
- [x] both mutation checks are recorded with their failing test counts
  - Task 3: `next(watching:)` polling the wake pipe alone fails 3 of 9 watch-stream tests (8
    issues), exactly (a), (b) and (c). Task 4: `watchRefused` mapped back to `.failed` fails 2 of
    61 tests in the two suites, exactly the two new `StatusViewModelTests`. Task 2's source-check
    mutation is recorded there too.

### Task 7: [Final] Update documentation

- [ ] `AGENTS.md`: update the `SetupWindow.swift` and `ControlServer` descriptions and any line
      references that moved, and record the two rules (window size set rather than tracked; a watch
      ends on the read side) where the structure section keeps such rules
- [ ] `README.md`: update only if it describes either behaviour
- [ ] confirm both backlog items are gone: the dead-watchers item went with Task 4's commit, and the
      crash item goes with Task 2's
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*Items requiring manual intervention or external systems. No checkboxes, informational only.*

**Manual verification:**
- Install the build (`Scripts/install.sh`) and score H48 and H49, together
  with H35, H41 and H47, which were never scored because the window crashed before they could be.
- Watch the menu across an idle hour or more and confirm it stays connected; this is the derived
  `watchIdle` leak.

**External system updates:**
- None. acta owes no backlog item: both fixes adopt its approach, and the refused-link case has no
  counterpart in an in-process menu.
