# Menu Adapter and Quiet Outcome Markers

## Overview

This plan takes three backlog items together, because all three touch the menu (user's choice,
2026-09-13):

- **`docs/backlog/testable-menu-adapter.md`**
  - Move the logic of `StatusViewModel` out of the `DictaMenu` executable into a new importable
    library, `DictaMenuKit`, with every effect on the world injected.
  - Fix the three defects the item names, each with a test that fails first:
    - (a) the ticker outlives the connection;
    - (b) Recent Dictations can roll back to an older read;
    - (c) a read error is drawn as an authoritative "Nothing yet."
- **`docs/backlog/quiet-outcome-markers.md`**
  - The ordinary outcomes (`injected`, `returned`) lose their green dot.
  - The exceptions carry a symbol decided in `DictaCore`.
  - The outcome word stays on every row.
- **`docs/backlog/ui-vocabulary-sync.md`**
  - Bring dicta's copy of `docs/ui-vocabulary.md` in step with what acta's copy now describes,
    without adopting acta's design.
  - Record dicta's own decisions, the kept divergences included.

**Consistency with acta is a requirement, not a nicety.** The user's rule for questions the two
apps share: take acta's approach, or take another one and file the same change in acta's backlog.
Every shared question below follows acta's approach, so no acta backlog item is needed. The two
forced differences are where the view model lives (a dependency, D27) and the word kept on
ordinary rows (dicta has two ordinary outcomes); both are recorded with their reasons.

**What this buys:**
- The menu-side code grown on this branch becomes reachable from `DictaTestRunner`. That covers the
  connection, the ticker, the record reads, and the setup-window wiring: the first-snapshot latch,
  clicks through `OrderedSender`, and closing the window or its becoming key.
- Three defects found by reading are fixed.
- A colour that marks nothing is removed.

Nothing about a dictation changes: the daemon, the wire and the record are untouched (D27).

## Context (from discovery)

Branch `dicta-first-run-setup` at `bb2cde7`, unmerged. Every line number below was verified on
2026-09-13.

### The view model

**Where it lives.** `Sources/DictaMenu/StatusViewModel.swift` declares
`@MainActor final class StatusViewModel: ObservableObject` inside the executable target.
- `DictaMenuApp.swift:20` creates it as `@StateObject private var model = StatusViewModel()`.
- The test runner cannot import it.

**The three defects:**
- **(a) Ticker.** `receive(_:at:)` handles `.end` at :166 and `finished(_:)` is at :172. Neither
  calls `updateTicker()` (:198). The timer is wanted when
  `panelOpen || model.snapshot?.state == .recording`. In `finished`, `guard running` is at :178.
- **(b) Ordering.** `refreshRecent()` (:221) reads on `offMain` and publishes `recent` from a
  main-actor `Task`, with no generation.
- **(c) Read errors.** The read is `try? RecordReader.tail(...)` at :224. `RecordReader.tail` treats
  an absent file as an empty record. It throws `ReaderError.cannotRead(path:reason:)`, described as
  "`<path>` could not be read: `<reason>`", for a file that exists and cannot be read
  (`Sources/DictaRecord/RecordReader.swift:72-103`).

**What else it owns:**
- **The watch.** `connect()` runs the watch thread; `finished` reconnects after `Backoff.delay` via
  `Task.sleep`.
- **The session-name lookup.** `resolveTargetName` (:274) returns early when
  `AgtermTool.locate()` finds nothing, before any thread starts (:279).
- **Commands.** `stopAndType` and `abort` go through `send`, one `Thread` per request.
- **System effects:**
  - `perform(_ action: Banner.Action)` uses NSWorkspace and runs `launchctl` and `Dicta
    --fetch-models`;
  - `copy` uses NSPasteboard;
  - `openRecord()` (:442) calls `NSWorkspace.activateFileViewerSelecting([Paths.current.record])`.
- **The setup window:**
  - `FirstSnapshotLatch` and `setup`;
  - `openSetup()` (:397-404) builds `SetupWindowController(content:becameKey:closed:)` around `self`
    and caches it;
  - `setupClicked`, `setupBecameKey` (:417, private) and `setupClosed` (:422, private);
  - `apply` through `setupSender: OrderedSender<Request>`.

### The rest of the menu

- `Sources/DictaMenu/RecentDictations.swift`:
  - `Text("Nothing yet.")` at :76;
  - `RecentRow` draws `Circle().fill(row.tint.color)` at :106;
  - the reason line is tinted at :122.
- `Sources/DictaMenu/SetupWindow.swift` holds `SetupWindowController` and `SetupView`.
- `Sources/DictaMenu/DictaMenuApp.swift:4-7` lists the modules the app links.

### The pure values and their tests

- In `Sources/DictaCore`: `MenuModel.swift`, `Presentation.swift`, `DictationRow.swift`,
  `SetupModel.swift` and `OrderedSender.swift`.
- **Outcome colours and words.** `AttemptOutcome.tint` and `.label` live in `Presentation.swift:129-156`
  (the doc comment at :122 says "The dot beside a row"):
  - `injected` and `returned` are green;
  - `filterFellBack`, `dictionaryDegraded` and `injectionPartial` are amber;
  - `targetGone`, `injectionFailed`, `recognitionFailed`, `captureFault` and `capped` are red;
  - `empty` and `aborted` are faint.
- **The row.** In `DictationRow.swift`:
  - `tint` is at :62, with the comment "The dot beside the row" at :61;
  - `label` is at :72;
  - `secondary(at:)` (:96) builds "`<relative time>` · `<label>` · …".
- **Tests.** `Sources/DictaTestRunner/DictationRowTests.swift` and `MenuModelTests.swift` cover
  these.
- **The test runner.** It starts at `Sources/DictaTestRunner/main.swift:9`,
  `await Testing.__swiftPMEntryPoint() as Never`. No test is `@MainActor` today.

### The linkage budget

- `Package.swift:176` gives `DictaMenu` the dependencies `["DictaCore", "DictaIPC", "DictaRecord"]`.
- `DictaTestRunner` (:181) adds `DictaRuntime`.
- The target-layout comment is at `Package.swift:7-31`, and the `DictaMenu` comment at :165-174.
- `Scripts/linkage.sh` §5 (:341-390) checks the built `DictaMenu` binary:
  - no AVFAudio, AVFoundation, CoreML or FluidAudio;
  - no `DictaRuntime` symbols;
  - `check_keystrokes` and `check_posting`.
- A statically linked `DictaMenuKit` is inside that binary, so those checks keep covering it.

### Source-reading tests

- `MenuBundleTests.swift:171`: `menuSources()` reads `Sources/DictaMenu` only. Two tests read it:
  - "the menu sends configure and accessibility only as SetupModel decides";
  - "the menu activates itself in one place, and opens by itself only through the latch".
- `DaemonTests.swift:2941-2942`: "start-up never asks for the grant" scans a fixed directory list
  that includes `Sources/DictaMenu`.
- `DocumentationTests.swift:16` states the rule for documentation tests: "These assert quotation and
  paths, never prose".

### What acta does, which this plan follows

All of this is on `~/dev/acta`, branch `dev`.

- **Presenting an AppKit window from testable logic.**
  - `ActaRuntime/ReminderCoordinator.swift:82` declares
    `public protocol ReminderPresenting: AnyObject`.
  - `Acta/ReminderPanel.swift` implements it as `ReminderPanelController`. The controller takes the
    coordinator in `init`, holds it weakly, and calls its public methods.
  - `ActaApp.swift:143` keeps the panel in a box and sets `coordinator.presenter = panel`.
  - `ReminderPresenterTests` uses a fake presenter.
- **The view model's dependencies.** `ActaRuntime/ControlViewModel.swift` takes one object,
  `ControlAPI` (default `.shared`). Its tests build a real `ControlAPI` over fakes at the lowest
  seam: `FakeAudioDeviceDirectory`, `GatedClock`, `ControllerHarness`. The view model lives in
  `ActaRuntime` and imports SwiftUI. That is where dicta cannot follow (D27).
- **Quiet markers** (`ActaApp.swift:815-885`):
  - the ordinary state (`saved`) has no marker;
  - every other state gets a 9 pt SF Symbol and its word, both tinted, at the start of the second
    line;
  - there is no leading dot column;
  - an unknown state is never drawn as ordinary.
- **A failed read above a list** (`ActaApp.swift:493`):
  `Label(failure, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)`.
  The section stays on screen below it.
- **Its copy of `docs/ui-vocabulary.md`** (226 lines) carries three amendments:
  - 2026-09-11: the microphone merge;
  - 2026-09-12: five panel rows;
  - 2026-09-12: the reminder panel.

  dicta's copy (98 lines) has none. It already carries "no Quit" in its divergences table (:78) and
  a paragraph on no revision tag (:32-37).

### Human-scored items and the failure matrix

- `docs/manual-checklist.md:370-374`: H20(b) passes when the `returned to caller` row is **green**.
- The last human item is H43 (:610). `humanItemNumbersAreUnique` forbids holes in the numbering.
- `docs/manual-checklist.md:109` is the row "the daemon dies while a watcher is showing a recording".
- SPEC §7 has menu rows (a watcher goes away, the watcher cap, a daemon dying under a watcher). It
  has no row for the menu failing to read the record.

### AGENTS.md statements this work makes false or incomplete

- :242-243, "867 tests in 47 suites".
- :361, "Nothing yet." for `recent == []` being unreachable.
- :395-398 and :1169-1171, "the second hand runs only while something is counting". Defect (a)
  contradicts it.
- :532-537, the `Sources/DictaMenu/` structure bullet.
- :541-542, the structure rule "decision → Core, I/O → Runtime", which gains a third shape.
- :1120-1124, "`SetupWindow.swift` renders and sends … because `DictaMenu` is not reachable from the
  test runner".
- :1129-1130, the menu's module list.

Other stale references: `OrderedSender.swift:16` cites `StatusViewModel.offMain`, and
`docs/ui-proposal.md:340` describes dot colours. The latter stays as a historical proposal.

## Development Approach

- **Testing approach: TDD.** Write the test first and watch it fail for the stated reason, then fix.
  - For defects (a), (b) and (c), record the failure message in the task's checkbox note.
  - Tasks 1-2 are a move: their tests pin today's behaviour, so the later tasks change a known
    baseline.
- Complete each task fully before moving to the next, in small, focused changes.
- **CRITICAL: every task MUST include new or updated tests** for the code it changes:
  - new functions and methods;
  - modified functions and methods;
  - new code paths;
  - behaviour that changed.

  Cover both success and error scenarios.
- **CRITICAL: all tests must pass before starting the next task**, no exceptions.
  - The gate is `bash Scripts/test.sh`, which runs `Scripts/linkage.sh` first. Never `swift test`.
  - `Scripts/lint.sh` enforces 100 columns, no Cyrillic and no trailing whitespace.
- **CRITICAL: update this plan file when scope changes during implementation.**
- Run the tests after each change.
- **Backward compatibility.** The panel, the setup window and every request the menu sends behave
  exactly as before, except for the three defects, the markers and the failed-read label.
- The repository stays English. Commit only when the user asks.

## Testing Strategy

**Unit tests, through `DictaTestRunner`.** Every suite that drives `StatusViewModel` is `@MainActor`.
Tests use a fake `MenuWorld`:
- a watch source the test feeds events to, or makes throw;
- an off-main runner that holds closures and runs them outside its own lock, so a closure that
  re-enqueues (reconnect → `connect`) does not deadlock;
- a main hop that holds closures until released, so completion order is the test's to choose;
- a fixed clock;
- a ticker factory that records schedules and cancellations;
- an `after` that records backoff delays and fires on demand;
- a recording transport;
- fake effects;
- a fake `SetupWindowPresenting`.

**Determinism.** No sleeps and no filesystem races. The one exception is a test that goes through
the real `OrderedSender` worker thread. It waits with a timeout on its transport's arrivals, and says
so in its comment. Held-transport ordering stays in `OrderedSenderTests`, which already covers it.

**Source-reading tests.** Where a property is a rule about what source may exist (imports, one
activation, no request spelled by hand), read `Sources/DictaMenu` and `Sources/DictaMenuKit`
together.

**E2E.** The project has none for UI. What the panel looks like is scored by a person, as new H items
in `docs/manual-checklist.md`.

## Progress Tracking

- Mark completed items `[x]` immediately.
- Add newly discovered tasks with ➕, and blockers with ⚠️.
- Keep the plan in sync with the work.

## Solution Overview

### A library for the menu's logic

**What `DictaMenuKit` is.** `Sources/DictaMenuKit` depends on `DictaCore`, `DictaIPC` and
`DictaRecord`, exactly the menu's budget. It imports Foundation and Combine only: no SwiftUI and no
AppKit, so everything in it is reachable from the test runner. It never depends on `DictaRuntime`,
which links FluidAudio and AVFoundation (D27).

**What stays in `DictaMenu`:**
- the SwiftUI views;
- `SetupWindowController`;
- one file that builds the system world.

**Why dicta differs from acta here.** acta keeps its `ControlViewModel` in `ActaRuntime` with SwiftUI.
dicta cannot, because its runtime is the daemon's. That dependency forces the difference, and it is
recorded in `docs/ui-vocabulary.md` with that reason.

**`StatusViewModel` moves into `DictaMenuKit` under the same name.**
- It stays `@MainActor` and `ObservableObject`.
- Its public surface is exactly what the views and the app use:
  - the class and `init(world:socketPath:record:)`;
  - `@Published public private(set)` on `model`, `now`, `recent` (becoming `recentState`) and
    `accessibilityRequested`;
  - `start`, `panelAppeared`, `panelDisappeared`, `copy`, `targetCaption`, `stopAndType`, `abort`,
    `perform`, `setup`, `openSetup`, `setupClicked`, `setupBecameKey`, `setupClosed`,
    `restartDaemon`, `openRecord` and `setupPresenter`.

  Everything else stays internal.

**Dependencies arrive as a struct of capabilities, `MenuWorld`.** This is dicta's own idiom:
`FocusedFieldWiring.Adapters` and `Daemon.TerminalProvider` work the same way. It follows the same
principle as acta: the view model is real and only the lowest seam is fake.
- acta's `ControlAPI` facade is justified by an in-process controller dicta's menu does not have. A
  facade over closures would add a layer with no logic, so no acta backlog item is needed.
- `MenuWorld`, `MenuEffects` and `MenuCancel` get explicit `public init`s, because
  `SystemMenuWorld.swift` in the other module must build them.

**The setup window follows acta's `ReminderPresenting` shape.**
- `DictaMenuKit` declares `public protocol SetupWindowPresenting: AnyObject { func show() }`.
- `StatusViewModel` holds `public weak var setupPresenter: (any SetupWindowPresenting)?`, and
  `openSetup()` calls `setupPresenter?.show()`.
- In `DictaMenu`, `SetupWindowController` adopts the protocol. It takes the model in `init`, holds it
  weakly, renders `SetupView(model:)`, and calls the public `setupBecameKey()` and `setupClosed()`
  from its window delegate.
- **The presenter is installed before the stream starts, in acta's order** (`ActaApp.swift:142-146`:
  retain the panel, assign the presenter, then `coordinator.start()`).
  - `FirstSnapshotLatch` is consumed by the first snapshot whether or not a presenter is attached,
    so a presenter attached after `start()` would silently lose that launch's automatic open.
  - Retrying the open on a later snapshot is not the fix; D27 forbids it.
  - `DictaMenu` therefore owns one stable pairing outside the lazy panel: a `@MainActor` `MenuRoot:
    ObservableObject`, held as the app's `@StateObject`. Its `init` builds the model, then the
    `SetupWindowController`, then assigns `setupPresenter`.
  - The model has two entry points to `start()`: the label's `.task` (`DictaMenuApp.swift:43`), and
    `panelAppeared()` (`StatusViewModel.swift:87`), which calls it idempotently. Both come after
    `MenuRoot.init`, so the presenter is attached before either. No other view starts the model.
  - **Ownership is not observation.** `ObservableObject` does not forward a child's changes:
    `MenuRoot` holding the model does not make the app redraw when the model changes. Codex measured
    it with a Combine probe: a mutated child `@Published` gave 0 events on the root and 1 on the child.
  - So the always-visible label is its own view, `MenuBarLabel`, with
    `@ObservedObject var model: StatusViewModel`. It renders today's `BarItem` and carries the
    `.task { model.start() }`. `Panel` already observes the model the same way (`@ObservedObject`,
    `DictaMenuApp.swift:93`). `MenuRoot` owns lifetime and order; it forwards nothing.
  - `MenuRoot` is the counterpart of acta's `reminderPanelBox`.
- A test uses a fake presenter and calls the two public methods directly.

### The three fixes

**(a) Ticker.**
- `updateTicker()` also runs from `.end` and from `finished`, placed before `guard running`.
- The recording half is additionally gated on `model.link == .connected`, so a snapshot kept across a
  lost link cannot hold the ticker on.
- With the panel open, ticks keep coming.

**(b) Ordering.**
- `refreshRecent()` numbers each read on the main actor.
- The main-actor completion publishes only if its number is newer than the last applied one,
  **whatever the result**. An older failure cannot overwrite a newer success, and an older success
  cannot wipe a newer failure.

**(c) Read errors.** The drawer's state is a pure value in `DictaCore`, `RecentState`.
- `.unread`: no read has completed yet. Nothing is drawn under the title.
- `.read([DictationRow])`: authoritative. Only `.read([])` says "Nothing yet."
- `.failed(reason:lastGood:)`:
  - it keeps the last good rows on screen;
  - above them, acta's idiom: `Label("The record could not be read: <reason>", systemImage:
    "exclamationmark.triangle")`, at `.caption` in the amber tint;
  - the reason is `ReaderError.cannotRead`'s `reason`, without the path, which is always the same
    known file and would eat the 300 pt line; any other error uses its description;
  - a later successful read clears the label.

  No banner.

### Quiet markers, laid out as acta lays them out

- **The leading dot column goes away.** `DictaCore` decides `AttemptOutcome.marker: OutcomeMarker?`,
  with the tint still `AttemptOutcome.tint`, said once (D19).
  - `nil` for `injected` and `returned`: nothing is drawn.
  - `.faint` for `empty` and `aborted`: no symbol, and the second line in the faint colour. Absence is
    not failure.
  - `.symbol(String)` for the amber and red outcomes. The proposal is `exclamationmark.triangle` for
    amber and `xmark.circle` for red; a person judges them on the built panel (H44).
- **Grouping and tint follow acta** (`ActaApp.swift:849-859`: the symbol and the outcome word first,
  both tinted, then the stamp).
  - `DictaCore` exposes the second line as parts rather than one string:
    `DictationRow.secondaryParts(at:) -> (outcome: String, details: [String])`.
    - `outcome` is `AttemptOutcome.label`, still its only source.
    - `details` are the relative time, "recognised only", "raw" and the duration, in today's order.
  - `secondary(at:)` stays, as those parts joined with the outcome first. Its tests are updated for
    the new order.
- **What `RecentRow` draws on the second line:**
  - the 9 pt symbol for `.symbol`;
  - the outcome word, tinted for `.symbol`, faint for `.faint`, and `.secondary` for an ordinary
    outcome;
  - `· <details>` at `.tertiary`, as acta draws its stamp.

  The reason line keeps its tint.
- **Where dicta still differs, and why that is not a choice of approach.** acta's one ordinary state,
  `saved`, prints no word: there is only one ordinary state, so a word would say nothing. dicta has
  two ordinary outcomes, `typed` and `returned to caller`, which say different things about where the
  text went. So the ordinary word stays, untinted and unmarked. That is acta's rule, "the ordinary is
  quiet", applied to a domain with two ordinary states. It is recorded in `docs/ui-vocabulary.md`
  with that reason.

### Vocabulary

**Sync the amendments.** Add acta's three amendments as descriptions of acta, each marked as asking
nothing of dicta. Leave out acta's introduction.

**Correct what now describes dicta wrongly:**
- the `list` element's dot on every row;
- :94's module list, which gains `DictaMenuKit`.

**Record dicta's decisions, rewording existing rows rather than duplicating them.** Each difference
from acta carries the reason it is forced:
- quiet ordinary rows, and exceptions marked by a symbol and a tinted word first, as in acta;
  the ordinary word kept because dicta has two ordinary outcomes;
- the failed-read label, same as acta's inventory failure;
- the header status line kept (D30);
- no Quit (already at :78);
- no revision (already at :32-37);
- the setup window presented through a protocol, as acta's reminder panel is;
- the view model in a menu-only library rather than the runtime (forced by D27).

## Technical Details

### `Package.swift`

- Add `.target(name: "DictaMenuKit", dependencies: ["DictaCore", "DictaIPC", "DictaRecord"],
  path: "Sources/DictaMenuKit")`.
- `DictaMenu` gains `"DictaMenuKit"`, and so does `DictaTestRunner`.
- Update the comments at :7-31 and :165-174.

### `MenuWorld`

Typechecked under `-swift-version 6` by the plan review; exact names settle in Task 1.

```swift
public struct MenuWorld: Sendable {
    public var socketExists: @Sendable (String) -> Bool
    public var watch: @Sendable (String, @escaping @Sendable (WatchEvent) -> Void) throws -> Void
    public var send: @Sendable (Request, String) throws -> Void
    public var readRecent: @Sendable (URL, Int) throws -> [RecordEntry]
    public var locateAgterm: @Sendable () -> String?            // nil: no thread is started
    public var sessionNames: @Sendable (String) -> [String: String]
    public var offMain: @Sendable (String, @escaping @Sendable () -> Void) -> Void
    public var toMain: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    public var now: @Sendable () -> Date
    public var scheduleTicker: @MainActor (TimeInterval, @escaping @MainActor () -> Void)
        -> MenuCancel
    public var after: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
    public var effects: MenuEffects
    public init(...)
}

public struct MenuEffects: Sendable {
    public var openURL: @MainActor @Sendable (URL) -> Void
    public var revealInFinder: @MainActor @Sendable (URL) -> Void   // openRecord, injected URL
    public var copy: @MainActor @Sendable (String) -> Void
    public var run: @Sendable (String, [String]) -> Void            // launchctl, --fetch-models
    public init(...)
}

@MainActor public protocol SetupWindowPresenting: AnyObject { func show() }
```

- The setup sender is `OrderedSender(name:) { try? world.send($0, socketPath) }`, built inside the
  view model.
- `openRecord()` reveals the injected `recordURL`, not `Paths.current.record`.

### `RecentState`

In `DictaCore/DictationRow.swift`:
- `case unread`, `case read([DictationRow])`, `case failed(reason: String, lastGood: [DictationRow])`;
- `var rows: [DictationRow]`, `var saysNothingYet: Bool`, `var failure: String?`;
- `func afterRead(_ rows: [DictationRow]) -> RecentState` and
  `func afterFailure(reason: String) -> RecentState`. The latter keeps the rows of `.read` or of an
  earlier `.failed`.

### `OutcomeMarker`

In `DictaCore/Presentation.swift`: `enum OutcomeMarker: Equatable, Sendable { case faint;
case symbol(String) }`.
- `AttemptOutcome.marker: OutcomeMarker?`, forwarded by `DictationRow.marker`.
- `DictationRow.secondaryParts(at:) -> (outcome: String, details: [String])`; `secondary(at:)` joins
  them with the outcome first.
- Update the doc comments at `Presentation.swift:122` and `DictationRow.swift:61`.

## What Goes Where

- **Implementation Steps** (`[ ]`):
  - code, tests, `Package.swift`;
  - source-reading tests;
  - the documents in this repository, including the SPEC §7 row and the new H items.
- **Post-Completion** (no checkboxes):
  - scoring the new H items on this Mac;
  - acta, which this plan does not edit.

## Implementation Steps

### Task 1: Create DictaMenuKit, prove @MainActor suites run, and hold the module boundary

**Files:**
- Modify: `Package.swift`
- Create: `Sources/DictaMenuKit/MenuWorld.swift`
- Create: `Sources/DictaTestRunner/MenuKitBoundaryTests.swift`
- Modify: `Sources/DictaTestRunner/MenuBundleTests.swift`, `Sources/DictaTestRunner/DaemonTests.swift`

- [x] add a probe: one `@MainActor @Suite` test that must run, and fail visibly when made to fail,
  under `bash Scripts/test.sh`. Score it under both `DEVELOPER_DIR` settings (Command Line Tools and
  Xcode), as `AGENTS.md` :238-243 does. If it hangs or is skipped, stop and redesign the fake main
  hop before anything moves
  - done as `MainActorProbeTests` in `MenuKitBoundaryTests.swift`: on the main thread, and resumed
    after a hop from a real `Thread` through `Task { @MainActor in }`. It passed in 0.001 s under
    both toolchains, with no hang. With a deliberate `#expect(!hopped)`, `test.sh` exited 1 under
    both, printing `Expectation failed: !(hopped …)`. Swift 6 refuses `Thread.isMainThread` in an
    `async` body, so the probe reads it through a `nonisolated` synchronous helper
- [x] add the `DictaMenuKit` target with `MenuWorld`, `MenuEffects`, `MenuCancel` and
  `SetupWindowPresenting`, each with an explicit `public init` where needed; wire `DictaMenu` and
  `DictaTestRunner` to it; update the `Package.swift` comments
- [x] write `MenuKitBoundaryTests`: `Sources/DictaMenuKit` imports only Foundation, Combine,
  DictaCore, DictaIPC and DictaRecord, and `Package.swift` gives it no `DictaRuntime` dependency
  - watched failing: `import SwiftUI` in `MenuWorld.swift` failed the import test under both
    toolchains, and a `"DictaRuntime"` added to the target failed the manifest test
- [x] extend `MenuBundleTests.menuSources()` to read `Sources/DictaMenu` and `Sources/DictaMenuKit`
  together, and add `"Sources/DictaMenuKit"` to the directory list at `DaemonTests.swift:2941`
- [x] run `bash Scripts/test.sh`; `Scripts/linkage.sh` stays clean. Must pass before Task 2
  - 888 tests in 51 suites passed under Xcode 26.6 and under the Command Line Tools, linkage clean,
    lint clean. ⚠️ Not caused by this change: "a stream never goes backwards"
    (`SnapshotPublishingTests.swift:117`) failed twice under load right after a build
    (`sequences.count → 2`). The watcher's mailbox holds one event (`ControlSocket.swift:398`), so
    intermediate transitions can be merged. It passed in 6 of 6 full runs on this change and on the
    base commit alike

### Task 2: Move StatusViewModel into DictaMenuKit behind MenuWorld, with no behaviour change

**Files:**
- Create: `Sources/DictaMenuKit/StatusViewModel.swift` (moved from `Sources/DictaMenu/`)
- Create: `Sources/DictaMenu/SystemMenuWorld.swift`, `Sources/DictaMenu/MenuRoot.swift`
- Modify: `Sources/DictaMenu/DictaMenuApp.swift` (`MenuBarLabel`), `Sources/DictaMenu/SetupWindow.swift`,
  `Sources/DictaMenu/RecentDictations.swift`
- Modify: `Sources/DictaTestRunner/MenuBundleTests.swift`
- Modify: `Sources/DictaCore/OrderedSender.swift` (the `offMain` comment)
- Create: `Sources/DictaTestRunner/MenuWorldFakes.swift`
- Create: `Sources/DictaTestRunner/StatusViewModelTests.swift`

- [x] write the fake world in `MenuWorldFakes.swift`, as the Testing Strategy describes
  - `FakeMenuWorld`: every capability under one lock, with scripted `watch` streams. A stream's
    ending is `.returns`, `.throwing(error)` or `.open`. The fake's watch must return, since it runs
    on the test's thread, so `.open` drops the one hop that return makes: a stream still open has
    not made it yet. Also `runOffMain(name?)`, `releaseMain(at:)` and `releaseMain()`, `settle()`,
    `fireAfter()`, `tick()`, and `FakeSetupPresenter`
- [x] write characterization tests, `@MainActor`, against the class as it will be:
  - the synchronous first model;
  - `start()` connects, and with no socket the link is `.notRunning`;
  - an update publishes the model;
  - a thrown watch schedules a backoff reconnect through `after`;
  - `stopAndType` and `abort` send named requests;
  - `openRecord` reveals the injected record URL;
  - the banner actions reach their effects;
  - no `locateAgterm` result starts no thread
  - 11 tests in `StatusViewModelTests`, plus a clean `.end` keeping its reason and a found agterm
    asked once per session. Watched failing: `stopAndType` sending `.raw`, and `openRecord`
    revealing `Paths.current.record`, each failed its test
- [x] move `StatusViewModel` into `DictaMenuKit`:
  - replace each system call with its `world` capability;
  - declare the public surface listed in the Solution Overview;
  - replace the cached `SetupWindowController` with `weak var setupPresenter`;
  - make `setupBecameKey` and `setupClosed` public.

  The three defects stay.
  - Swift 6 refused `[weak self]` re-captured inside the `@Sendable` watch callback nested in the
    off-main closure, so the event sink (`deliver`) is built on the main actor before the thread
    starts. `refreshRecent` and `resolveTargetName` stay internal; the tests reach them through
    `start()` and `panelAppeared()`
- [x] write `MenuWorld.system` in `SystemMenuWorld.swift`, and make `SetupWindowController` adopt
  `SetupWindowPresenting`, taking the model weakly
  - the ticker's `@MainActor` closure crosses into `Timer`'s `@Sendable` block in a private
    `@unchecked Sendable` box and runs under `MainActor.assumeIsolated`: the block runs on the main
    run loop. The timer is carried into `MenuCancel` the same way
- [x] add `MenuRoot` in `DictaMenu`, the app's `@StateObject`:
  - its `init` builds the model, then the controller, then assigns `setupPresenter`;
  - the label becomes `MenuBarLabel(model: root.model)`, a view with
    `@ObservedObject var model: StatusViewModel` that renders `BarItem` and carries
    `.task { model.start() }`;
  - `Panel(model: root.model)` is unchanged;
  - update the module-list comment at `DictaMenuApp.swift:4-7`
- [x] extend `MenuBundleTests` with source checks:
  - in `Sources/DictaMenu`, `setupPresenter =` appears inside `MenuRoot`'s `init`;
  - the only call of `StatusViewModel.start()` in `Sources/DictaMenu` is `MenuBarLabel`'s `.task`,
    and `Panel` has none; `panelAppeared()`'s internal call stays, and `SystemMenuWorld`'s
    `Thread.start()` for the off-main and watch workers is not a model start;
  - `BarItem(` is built only inside a view declaring `@ObservedObject var model: StatusViewModel`;
  - no file other than `MenuRoot` constructs `StatusViewModel(`
  - done as two tests over a brace-counting reader of top-level declarations, which has its own
    test. Watched failing: a `model.start()` added to `Panel`'s `.task` failed the start check. The
    first version of the init check read everything after `init()`, so an assignment moved into a
    later method still passed; it now reads the init's own body, and that move fails it
- [x] run `bash Scripts/test.sh`; linkage clean. Must pass before Task 3
  - 902 tests in 52 suites passed under Xcode 26.6 and, twice, under the Command Line Tools.
    Linkage, lint and `git diff --check` were clean. The first Command Line Tools run, straight
    after a full rebuild, failed only Task 1's known flake "a stream never goes backwards"
    (`sequences.count → 2`). `RecentDictations.swift` needed no change: it never names the model

### Task 3: Stop the ticker when the connection ends (defect a)

**Files:**
- Modify: `Sources/DictaMenuKit/StatusViewModel.swift`, `Sources/DictaTestRunner/StatusViewModelTests.swift`

- [x] write a failing test: with the panel closed, a recording snapshot schedules the ticker, and
  `.end` cancels it. Record the failure
  - "with the panel closed, a recording schedules the ticker and an end cancels it" lands the
    update, the end and the return one hop at a time. Before the fix it failed with
    `Expectation failed: (fake.runningTickers → 1) == 0` after the end, and again after the return
- [x] write a failing test: with the panel closed, a watch that throws mid-recording cancels the
  ticker
  - failed before the fix with `Expectation failed: (fake.runningTickers → 1) == 0`; it also checks
    the backoff reconnect is still scheduled
- [x] write a test: with the panel open, the ticker survives `.end`, a disconnect, and a daemon
  restart that reconnects through `after`; it stops when the panel closes
  - passed before the fix too, as expected: the panel half was never broken. It also checks a tick
    still advances `now` while disconnected, and that one ticker runs throughout
- [x] call `updateTicker()` from `.end` and from `finished`, before `guard running`, and gate the
  recording half on `model.link == .connected`
  - the link gate has no failing test of its own: every path that leaves `.connected` today also
    clears the snapshot, so it guards a state no event produces yet, as `liveTarget` does
- [x] run `bash Scripts/test.sh`; must pass before Task 4
  - 905 tests in 52 suites passed under Xcode 26.6 and under the Command Line Tools, linkage
    clean, lint and `git diff --check` clean

### Task 4: Never roll Recent Dictations back to an older read (defect b)

**Files:**
- Modify: `Sources/DictaMenuKit/StatusViewModel.swift`, `Sources/DictaTestRunner/StatusViewModelTests.swift`

- [x] write a failing test:
  - start two reads;
  - run both held off-main closures in start order, with `readRecent` returning older rows first and
    newer rows second;
  - release their held main hops in reverse order;
  - expect the newer rows.

  This is the real race: slow publication, not slow reads. Record the failure
  - "an older read published late does not roll the drawer back" starts the reads with `start()`
    and `panelAppeared()`. Before the fix the newer hop published two rows, and the older hop
    landing second failed with `Expectation failed: (model.recent → [… id: 1 …]) ==
    (DictationRow.rows(from: newer) → [… id: 2 …, … id: 1 …])`
- [x] write tests that in-order completion publishes the latest, and that a single read publishes
  - "reads published in order leave the latest" and "a single read publishes its rows", which also
    pins newest-first order and that nothing is published before the hop lands
- [x] number reads on the main actor, and apply a completion only if its number is newer than the
  last applied one
  - `readsStarted` and `readApplied` in `StatusViewModel`. Still `try?`: Task 5 routes failures
    through the same check
- [x] run `bash Scripts/test.sh`; must pass before Task 5
  - 908 tests in 52 suites passed under Xcode 26.6 and under the Command Line Tools, linkage
    clean, lint and `git diff --check` clean

### Task 5: Show a failed record read as a failure, as acta does (defect c)

**Files:**
- Modify: `Sources/DictaCore/DictationRow.swift` (`RecentState`)
- Modify: `Sources/DictaMenuKit/StatusViewModel.swift`, `Sources/DictaMenu/RecentDictations.swift`,
  `Sources/DictaMenu/DictaMenuApp.swift` (the `RecentDictations(rows: model.recent, …)` call at :112)
- Modify: `Sources/DictaTestRunner/DictationRowTests.swift`, `Sources/DictaTestRunner/StatusViewModelTests.swift`

- [x] write `RecentState` tests, then add it:
  - only `.read([])` says "Nothing yet.";
  - `.unread` draws no rows and no failure;
  - `afterFailure` keeps the last good rows with the reason;
  - `afterRead` clears a failure
  - four tests in "dictation rows". `failure` is the whole sentence drawn, "The record could not be
    read: <reason>", so the copy is decided in `DictaCore`; the reason extraction stays in the view
    model, because `ReaderError` lives in `DictaRecord`, which `DictaCore` does not import
- [x] publish `recentState` from the view model as `.read(rows)`, still through `try?`, so the next
  test can compile and fail on behaviour. In the same step, change `RecentDictations` to take the
  state and update its caller at `DictaMenuApp.swift:112`, so `DictaMenu` still builds for
  `Scripts/linkage.sh`
  - `recent` became `recentState`; the Task 4 tests compare against `.read(rows)` and `.unread`
- [x] write a failing test: a `readRecent` that throws `ReaderError.cannotRead` leaves `.failed` with
  that reason and no path, not `.read([])`. Record the failure
  - "a record that cannot be read is a failure with its reason, not an empty record" failed before
    the fix with `Expectation failed: (model.recentState → .read([])) == .failed(reason: "it could
    not be opened", lastGood: [])`, and with `saysNothingYet → true`
- [x] write tests:
  - an older failing read completing after a newer success leaves `.read(newer)`;
  - an older success completing after a newer failure keeps `.failed`;
  - a record readable again clears the failure;
  - a sequence through the adapter, starting from non-empty rows: success, failure, failure, recovery.
    `lastGood` holds the first success's rows across both failures, the failure is the highest
    applied generation after each failing read, and the recovery replaces the rows and clears the
    failure
  - all four, plus "any other read error is shown by its description"; the sequence test uses a
    different reason for each failure, so the shown reason is shown to be the latest applied read's
- [x] catch the error and apply it through the generation check. Update `RecentDictations`:
  - the amber `Label` above the rows when `failure != nil`;
  - the rows from `state.rows`;
  - "Nothing yet." only when `saysNothingYet`;
  - nothing under the title when unread
  - the read result crosses to the main actor as rows or a reason string and goes through the same
    `readApplied` check. The `Label` uses `Tint.amber.color`, the one place amber becomes a colour
- [x] run `bash Scripts/test.sh`; must pass before Task 6
  - 918 tests in 52 suites passed under Xcode 26.6 and under the Command Line Tools, linkage
    clean, lint and `git diff --check` clean. What the label looks like is not checked here; a
    person scores it in Task 9's H items

### Task 6: Test the setup-window wiring through the fake world

**Files:**
- Modify: `Sources/DictaTestRunner/StatusViewModelTests.swift`

- [x] write latch tests with a fake `SetupWindowPresenting`:
  - an idle first snapshot with a pending choice calls `show()` once;
  - a busy first snapshot never does, and neither does a later one;
  - a reconnect, followed by a second pending snapshot, shows nothing
  - plus "a presenter attached after the first snapshot never gets that launch's open", which pins
    why `MenuRoot` attaches it before `start()`
- [x] write tests for `openSetup`:
  - `openSetup()`, `perform(.openSetup)` and the "Set Up…" row call `show()`;
  - with the link down, `openSetup()` still shows the window, and the model's screen is
    `.unavailable`
  - the footer's "Set Up…" row is a SwiftUI button in `DictaMenu`, so `MenuBundleTests` reads that
    it calls `model.openSetup()` and that `setupPresenter?.show()` is the only `.show()` call; the
    banner's "Set Up…" action is driven through the model
- [x] write click tests:
  - `setupClicked` on the fresh screen hands `SetupModel`'s request to `world.send`;
  - two different clicks arrive at `world.send` in click order, waiting with a timeout on the real
    sender's thread, as noted in the test;
  - `.allowAccess` flips `accessibilityRequested`
  - every setup request goes through the real sender, so each of these tests waits: the fake's
    lock became an `NSCondition`, with `waitUntil(timeout:)` as its one wait. A request that must
    NOT be sent is checked by a later one that must, arriving alone: the sender keeps order
- [x] write tests for the window's events:
  - `setupBecameKey()` sends a non-prompting `accessibility` only under `other-apps`;
  - `setupClosed()` sends `offerSeen` only on the first-time offer;
  - a control the screen no longer draws sends nothing
  - these pin behaviour that already held, so they passed first. Watched failing on a mutated
    model instead: a latch that opened on every snapshot failed the five latch and door tests, and
    becoming key sending `status` failed the becoming-key test under both screens
- [x] run `bash Scripts/test.sh`; must pass before Task 7
  - 930 tests in 52 suites passed under Xcode 26.6 and under the Command Line Tools, linkage
    clean, lint and `git diff --check` clean

### Task 7: Quiet the ordinary outcome and mark exceptions on the second line

**Files:**
- Modify: `Sources/DictaCore/Presentation.swift` (`OutcomeMarker`, `AttemptOutcome.marker`)
- Modify: `Sources/DictaCore/DictationRow.swift` (`marker`)
- Modify: `Sources/DictaMenu/RecentDictations.swift`
- Modify: `Sources/DictaTestRunner/DictationRowTests.swift`

- [x] write failing tests over `AttemptOutcome.allCases`:
  - `injected` and `returned` have no marker;
  - `empty` and `aborted` are `.faint`;
  - every amber and red outcome is `.symbol(_)`, with one name per tint
  - "the ordinary outcomes carry no marker, absence is faint, and every exception a symbol", plus
    "a row's marker is its outcome's". Watched failing against a stub returning `nil` for every
    outcome: `(outcome.marker → nil) == .faint`, `Issue recorded` for each exception, and
    `(symbols[.amber]?.count → nil) == 1`
- [x] write failing tests for `secondaryParts(at:)`:
  - `outcome` is `label` for every outcome;
  - `details` hold the time, "recognised only", "raw" and the duration in today's order, and never the
    label;
  - `secondary(at:)` joins them with the outcome first.

  Update the existing `secondary(at:)` tests for the new order
  - "the second line's parts put the outcome's word first and never repeat it in the details"; the
    existing test now expects `typed · 4m ago · 12s`. Watched failing against a stub that split
    today's line: `(parts.details → ["4m ago", "typed", "12s"]) == ["4m ago", "12s"]` and
    `(line → "4m ago · typed · 12s") == "typed · 4m ago · 12s"`
- [x] add `OutcomeMarker`, `AttemptOutcome.marker`, `DictationRow.marker` and `secondaryParts(at:)`,
  and update the doc comments at `Presentation.swift:122` and `DictationRow.swift:61`
  - `marker` switches on `tint`, so a marker cannot disagree with its colour and one symbol per tint
    is structural: `exclamationmark.triangle` for amber, `xmark.circle` for red, pending H44
- [x] update `RecentRow`:
  - remove the leading `Circle` column;
  - draw the second line as acta does: the 9 pt symbol for `.symbol`, then the outcome word (tinted
    for `.symbol`, faint for `.faint`, `.secondary` for an ordinary outcome), then `· <details>` at
    `.tertiary`;
  - keep the reason line's tint;
  - rewrite the row's comment
  - the faint word uses `Tint.faint.color` through `row.tint`, so the tint is still said once
- [x] run `bash Scripts/test.sh`; must pass before Task 8
  - 933 tests in 52 suites passed under Xcode 26.6 and under the Command Line Tools, linkage
    clean, lint and `git diff --check` clean. What the row looks like is not checked here; a person
    scores it in H44

### Task 8: Sync docs/ui-vocabulary.md and record dicta's decisions

**Files:**
- Modify: `docs/ui-vocabulary.md`
- Modify: `Sources/DictaTestRunner/DocumentationTests.swift`

- [ ] re-read `~/dev/acta` `docs/ui-vocabulary.md` on `dev`, and list the amendments present then
  (three as of 2026-09-13)
- [ ] add each as a description of what acta does, marked as asking nothing of dicta, without acta's
  introduction or its account of authorship
- [ ] correct the `list` element row, and the module list at :94 (add `DictaMenuKit`)
- [ ] record dicta's decisions as listed in the Solution Overview, rewording the existing "no Quit"
  row and the no-revision paragraph rather than duplicating them
- [ ] add one documentation test, a quotation or path only (`DocumentationTests.swift:16`): the
  module list names `DictaMenuKit`
- [ ] run `bash Scripts/test.sh` and `Scripts/lint.sh`; must pass before Task 9

### Task 9: SPEC §7, the manual checklist and the human items

**Files:**
- Modify: `SPEC.md`, `docs/manual-checklist.md`

- [ ] add a SPEC §7 row, "the menu cannot read the record": the last good rows stay under an amber
  label saying so, never "Nothing yet.", and a later successful read clears it. Add the matching
  checklist row citing Task 5's test names verbatim and the new H item
- [ ] cite Task 3's ticker tests in the checklist row "the daemon dies while a watcher is showing a
  recording" (:109)
- [ ] rewrite H20(b) (:370-374): the `returned to caller` row has no marker and keeps its copy
  button. Check H20's red-row wording against the symbol
- [ ] add contiguous human items after H43:
  - **H44**, the markers on a mix of outcomes: symbol names judged, text aligned, words unchanged;
  - **H45**, an unreadable record (`chmod 000` then `600`);
  - **H46**, the ticker, with the panel closed. (a) `launchctl bootout` the daemon while recording.
    (b) Kill the daemon (`kill -9`) while recording. Each time the menu-bar clock goes, and nothing
    redraws once a second (Activity Monitor's idle wake-ups, before and after). An ordinary recording
    that ends cleanly is not the test, because today's code already passes it. (c) After a fresh
    menu launch, and with the panel never opened, start a dictation: the glyph lights and the clock
    counts in the menu bar, then both go when it ends. This is the label's own observation of the
    model, which ownership through `MenuRoot` does not give;
  - **H47**, the setup window through the presenter:
    - it opens by itself only on the FIRST snapshot of a menu launch, and only if that snapshot is
      idle;
    - a launch whose first snapshot is busy never opens it, not even when a later snapshot is idle;
    - "Set Up…" and a banner open it at any time.

    Check that H41 states the same first-snapshot rule, and align it if not
- [ ] run `bash Scripts/test.sh` (ChecklistTests audits citations and numbering); must pass before
  Task 10

### Task 10: Verify acceptance criteria

- [ ] verify each backlog item's criteria:
  - (a), (b) and (c), each with a test that failed first, as recorded in Tasks 3-5;
  - the adapter is outside `DictaRuntime`;
  - `Scripts/linkage.sh` holds;
  - the quiet-marker rules hold;
  - the vocabulary is synced
- [ ] verify that every shared question follows acta. A difference is acceptable without an acta
  backlog item only when a dependency or a domain fact forces it, and its reason is written in
  `docs/ui-vocabulary.md`: the view model's module (D27), and the ordinary word kept because dicta
  has two ordinary outcomes. Any other difference is either removed or filed in acta's
  `docs/backlog/` in the same change, per the user's rule
- [ ] run `bash Scripts/test.sh` and report the test and suite counts; run `Scripts/lint.sh` and
  `git diff --check`

### Task 11: [Final] Update documentation

- [ ] update `AGENTS.md`:
  - the `Sources/DictaMenu/` structure bullet (:532-537) and a new `Sources/DictaMenuKit/` bullet;
  - the structure rule (:541-542): menu logic without I/O types goes to `DictaMenuKit`;
  - :1120-1124 and :1129-1130 (module list, "not reachable from the test runner");
  - :395-398 and :1169-1171 (the second hand, now also stopped when the link ends);
  - :361 ("Nothing yet." against a failed read);
  - :242-243, the test count, only if re-scored under both toolchains
- [ ] update `README.md` wherever it describes row dots or the menu's modules
- [ ] `git rm` `docs/backlog/testable-menu-adapter.md`, `docs/backlog/quiet-outcome-markers.md` and
  `docs/backlog/ui-vocabulary-sync.md` in the commit that lands their work
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*Items requiring manual intervention or external systems. Informational only.*

**Manual verification.** Score H44-H47 on the installed pair, on this Mac:
- the marker symbol names, judged on the built panel, changed in `Presentation.swift` if they read
  wrong;
- the failed-read label;
- idle wake-ups after a recording;
- the setup window's doors.

**External systems.**
- acta is not edited from here. Every shared question follows acta's existing approach, so no acta
  backlog item is owed. If a later review finds a divergence that is not forced, file it in acta's
  `docs/backlog/`, per the user's rule.
