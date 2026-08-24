# dicta — the menu-bar UI

## Overview

Build the minimal UI designed in `docs/ui-proposal.md`: a menu-bar **lamp and receipt drawer** for
dicta, consistent with `acta`'s menu, living in a **second bundle** that the daemon knows nothing
about.

The two decisions this plan rests on were taken by the user on 2026-08-23:

- **§13 is reversed in the part that says "a menu bar".** "A settings window" and "a dock icon" stay
  out of scope, and this plan wants neither.
- **A second bundle in `Scripts/install.sh` is accepted.**

Scope is **Tier 0 + Tier 1** of the proposal: the glyph, the panel with header, fault banners and
footer, then the live target line, Stop/Abort, and `Recent Dictations` with copy-to-clipboard.
Tier 2 (row expansion showing `recognised` vs `final` vs the rules that fired, and the D9b filter
field) waits for step 4, per the proposal's §8.

The shape in one sentence, because every task below is a consequence of it: **the menu app is
`dictactl` with a face** — a second client of the control socket, linking `DictaCore` + `DictaIPC`
(+ a new record-reading target + SwiftUI) and nothing else, so the daemon's binary, its process
shape and its TCC grant are untouched.

### What makes this plan different from the last one

Nothing here is a pure value waiting to be written. Three of the tasks are re-establishing
guarantees that the current code answers *by construction* and would stop answering:

- `ControlServer` has no connection that outlives one answer. `watch` is a second connection shape,
  not a case in an enum (Task 3), and the guarantees it re-opens — how many watchers, how a stream
  ends without looking like a crashed daemon, what bounds an idle read — are the substance of it.
- `FileHistory.entries()` parses the whole append-only record. A panel that opens many times a day
  cannot use it (Task 5), and this is a real defect independent of whether the UI ships.
- The record reader lives in `DictaRuntime`, which links FluidAudio. The UI must not, so the reader
  is extracted (Task 5) — the same argument that produced `DictaIPC`, in its second instance.

## Context

- **Files involved (existing):** `SPEC.md`, `Package.swift`, `Sources/DictaCore/Wire.swift`,
  `Sources/DictaIPC/ControlSocket.swift`, `Sources/DictaRuntime/Daemon.swift`,
  `Sources/DictaRuntime/History.swift`, `Scripts/bundle.sh`, `Scripts/install.sh`,
  `Scripts/linkage.sh`, `Scripts/launchagent.plist`, `CLAUDE.md`, `README.md`,
  `docs/manual-checklist.md`.
- **Files involved (new):** `Sources/DictaRecord/`, `Sources/DictaMenu/`,
  `Resources/DictaMenu-Info.plist`, `Scripts/menu-launchagent.plist`, `docs/ui-vocabulary.md`.
- **Reference material:**
  - `docs/ui-proposal.md` — the design and the reasoning. Normative for this plan's *shape*;
    `SPEC.md` stays normative for behaviour.
  - `SPEC.md` — decisions D*, measurements F*, invariants §8.
  - `../acta/Sources/Acta/ActaApp.swift` and `ControlViewModel.swift` on branch `socket-transport`
    — the vocabulary being adopted, and the synchronous-seeding trick that keeps the first frame
    from being blank.
  - `../acta/Sources/ActaControlProtocol/` and its `Command.watch` on the same branch — the
    streaming semantics being mirrored (coalescing to the newest state).
  - `Scripts/bundle.sh --print-requirement` — what identity-based signing looks like when it is
    right.
- **Related patterns:** a decision is a pure value in `DictaCore`, its I/O in `DictaRuntime` (or now
  `DictaRecord`), its test in `DictaTestRunner` (D19). `swift test` is not a gate (D18);
  `bash Scripts/test.sh` is. **English only, with no exceptions.**

### Coordination — read before starting

Three sessions are in these repositories, and two of this plan's files are the hottest in the
project.

- **`dicta-cf` holds two uncommitted branches**: `dicta-push-to-talk` (rewrites §6 substantially;
  adds invariants 11–13, decisions **D21–D26**, facts F6–F8a; touches `main.swift`, `Wire.swift`,
  `Daemon.swift`, `Agterm.swift`, `linkage.sh`) and `dicta-record-window` (adds `speechStartedAt`,
  `speechEndedAt`, `audioSeconds` to §9; cancelled attempts carry `recognised` with an empty
  `final`; touches `Record.swift`, `StateMachine.swift`, `Daemon.swift`).
- **Decision numbers: D27 and D28 are this plan's, D30 is the third; `dicta-cf` holds D21–D26 and
  D29 (`dictactl dictate`, which returns text on stdout and added the `returned` outcome).**
  Everything from D31 up is free. Every §6/§8 edit is written **against `dicta-cf`'s
  text, not `main`'s** — ask them for it rather than reading `main`.
- **Task ordering is chosen to keep out of their way**: the new targets, the bundle and the record
  reader come first and collide with nothing; `Wire.swift`, `Daemon.swift` and `SPEC.md` §6/§8 are
  touched as late as the dependencies allow.
- **`dicta-8f`** owns the main checkout, has a pending `SPEC.md` edit for F4/§10 (a)/H5, and nothing
  else in flight.
- **`acta-f3`** reports `Sources/Acta/` clear and is not touching it. Task 10's acta-side edit is
  the only cross-repo work here and needs its own approval. Not in the train below, but a
  stakeholder in it: `dicta-record-window` carries the §9 fields their meeting-correlation work
  reads.

**The train ran on 2026-08-23 and is finished. `main` is `0873b9a`**, linear, 469 tests in 24
suites, lint clean — verified in this worktree, which was fast-forwarded onto it, not taken from a
message. Nothing in the Context list above is blocked any more.

    0873b9a  docs: F4 has two endpoints, and §10 (a) does not say which one it means
    022721a  feat: record when the speaking happened … (D26)
    ea712ad  feat: hold a key to dictate, and hand text back to callers
    4c2ac7c  perf: build the capture engine before the chord, not during it

**Commit and merge were two gates, and conflating them was an error this plan made once** — the
request relayed was to *commit*, and it was written up here as "→ `main`", which is a materially
larger thing to ask. In the event the owner took both: merge now, verify later.

**So this plan is built on a `main` that is green by machine and unseen by a human.** H11, H12 and
H13 have not been run once. That is the owner's call and it is recorded rather than argued with, but
it changes what a citation means: **push-to-talk's behaviour on `main` is what the spec claims, not
what anyone has observed.** Where a task below reasons from D21–D26 or D29, it is reasoning from a
document. If H11–H13 later contradict them, the tasks resting on them move with them.

What was collected from the repository rather than from messages, and is therefore what the tasks
below cite:

- **`AttemptOutcome` has twelve cases**, `returned` last (`Sources/DictaCore/Record.swift`).
- **`Command.isServedConcurrently` is `abort` and `dictate`.** The comment on `dictate` makes the
  test explicit — it blocks for as long as the user speaks, so under the handler lock it would
  deadlock outright — which is the second worked example Task 3 leans on.
- **`ControlTimeouts` has five values and `read(for:)` five cases**, including `dictateWait = 60.0`
  and `case .dictate: dictateWait + pipelineRead`. The stream's timeout in Task 3 is a sixth value
  and a sixth case, landing beside a precedent rather than alone.
- **`History.swift` is untouched** — last modified at `20cf908`, three commits before the train.
  Task 5's extraction collides with nothing.
- **F4 is in `SPEC.md` and `CLAUDE.md`**, with both endpoints and the phase table. Cite it there.

## Development Approach

- **TDD** for everything that is a pure value: the watch protocol's vocabulary and timeout policy,
  the readiness snapshot, the tail reader's line-splitting, the outcome-to-colour mapping. These are
  `DictaCore`/`DictaRecord` and their tests are the executable form of the design.
- **Regular** (code first, then tests) for the socket's streaming path, the daemon's observer hook
  and the menu app, where a test drives a real thread or a fake handler that has to exist first.
- **The UI itself is not unit-tested, and the plan does not pretend otherwise.** What *is* tested is
  everything below it: the snapshot, the stream, the reader, the mappings. Anything the panel does
  that a test cannot reach is a checklist item in `docs/manual-checklist.md` with its pass condition
  written out, not a checkbox here.
- **CRITICAL: every task MUST include new/updated tests**, except Task 1 (spec text) and Task 10
  (documentation), which say so explicitly.
- **CRITICAL: all tests must pass (`bash Scripts/test.sh`) before starting the next task**, and
  `bash Scripts/lint.sh` must be clean.
- **A regression in the keypress path vetoes the task that caused it.** Cite the numbers from **F4 in
  `SPEC.md`**, not from this plan: `dicta-8f` rewrote F4 on 2026-08-23 and it is the only copy that
  stays true. As of that rewrite — chord → live microphone ~95 ms; chord → lit indicator (what
  `Scripts/measure.sh` actually times) median 122, p90 132, p95 145, worst 158 over 120 attempts in
  12 runs of 10, on `4c2ac7c`. Phase breakdown: `dictactl` + socket ~20, target resolution ~30,
  `engine.start()` ~40, the indicator ~35 — two of the four are `agtermctl` subprocesses.
- **The instrument can be gamed, and F4 now names the move.** The indicator lights *after* the
  microphone is live, because D13 requires it — announcing earlier trains the user to speak before
  audio flows. So taking the indicator off the path before the daemon replies would cut ~35 ms from
  what `measure.sh` reports **without the indicator appearing one millisecond sooner**. That is
  tuning to the instrument, not speeding anything up, and this plan forbids it as a way of clearing
  its own veto. See Task 4, where the temptation actually arises.
- **§10 (a) is not passed, and must not be quoted as though it were.** The criterion still says
  "each of ten attempts", and against the end of the interval the script measures it fails: 9 clean
  runs of 12, 4 attempts of 120 over budget. Which end of the interval the criterion means is an
  unresolved decision belonging to the user. This plan's veto is therefore "do not make it worse",
  not "stay under a bar that is currently met".

## Implementation Steps

### Task 1: The decisions, in the spec, before any code

**Files:**
- Modify: `SPEC.md`

- [x] §13 — remove "a menu bar" from the not-in-scope list; keep "a settings window" and "a dock
      icon", and say in one clause that the daemon still has neither dock icon nor window
- [x] §12 — the note that the bundle has "no dock icon, no menu bar, no windows" describes the
      **daemon** and stays true; add the sentence that the UI is a separate bundle which never opens
      the microphone
- [x] add **D27 — the UI is a second client of the control socket, never a second face of the
      daemon.** State the three reasons the in-daemon `MenuBarExtra` was refused: invariant 11's
      linkage gate reads the `Dicta` binary for `_OBJC_CLASS_$_NSEvent`; F6/F8a were measured in a
      process with no `NSApplication`; and the smallest daemon is the one whose TCC grant is easiest
      to reason about
- [x] add **D28 — the UI never injects.** Recovery is the clipboard; a target is only ever captured
      by a trigger. Record its structural form: the UI acts on `final` and displays `recognised`,
      which is the rule `dictactl last` already follows
- [x] add **D30 — no Start in the UI, but Stop and Abort are allowed.** A click carries no session to
      aim at (D4, D6) and D22 means agterm is not frontmost while the panel is open; a live attempt
      already owns a target captured at start
- [x] state in D27 that the UI's absence — not installed, quit, crashed — changes no outcome, and
      that nothing the daemon does for a dictation may wait on it
- [x] no tests: this task is spec text. The invariants it implies are asserted in Tasks 3, 5 and 8

### Task 2: `DictaMenu` as an empty second bundle that installs and runs

Deliberately first, and deliberately empty. If the second bundle cannot be built, signed, installed
and started as its own LaunchAgent, nothing else in this plan is worth writing — and every
measurement taken after a signing mistake would be taken against a grant that evaporates.

**Files:**
- Modify: `Package.swift`, `Scripts/bundle.sh`, `Scripts/install.sh`, `Scripts/linkage.sh`
- Create: `Sources/DictaMenu/main.swift`, `Resources/DictaMenu-Info.plist`,
  `Scripts/menu-launchagent.plist`
- Create: `Sources/DictaTestRunner/MenuBundleTests.swift`

- [x] add the `DictaMenu` executable target to `Package.swift`, depending on `DictaCore` + `DictaIPC`
      **only** for now, with the comment explaining that this is D12's budget in its second instance
- [x] write `Resources/DictaMenu-Info.plist`: `CFBundleIdentifier` `dev.personal.dicta.menu`,
      `LSUIElement` true, **no** `NSMicrophoneUsageDescription` — the menu app must never be in a
      position to ask
- [x] teach `Scripts/bundle.sh` to produce `Dicta Menu.app` with the **same identity-based signing**
      it asserts for the daemon, and to fail on an ad-hoc requirement exactly as it already does
- [x] extend `Scripts/linkage.sh` with a row for `DictaMenu`, following the structure the train
      already put there — it now scores two binaries with different rules and takes `--daemon <path>`
      to score one alone, so this is a third mode, not a new script. The rules: no AVFoundation, no
      AVFAudio, no CoreML, no FluidAudio (invariant 8's reasoning, one binary further); AppKit and
      SwiftUI **are** allowed, and that difference from `dictactl`'s row is written down rather than
      left to be inferred; and none of `CGEventTapCreate`, `CGEventTapEnable`, `IOHIDManager`,
      `_OBJC_CLASS_$_NSEvent`-as-a-monitor, so the UI can never become a second trigger path
      (invariant 11's reasoning). ⚠️ **`_OBJC_CLASS_$_NSEvent` cannot be forbidden outright here** the
      way it is for `Dicta` — any SwiftUI status item references it — so the menu's rule has to
      target the global-monitor entry points instead. Prove the weaker rule can still fail, by
      adding an `NSEvent.addGlobalMonitorForEvents` call and watching it trip
- [x] a `MenuBarExtra` showing the glyph and a panel with the app name and nothing else — enough to
      prove it appears
- [x] `Scripts/menu-launchagent.plist` + `install.sh`: install the second bundle to
      `~/Applications/Dicta Menu.app` and its agent to `dev.personal.dicta.menu.plist`, reusing the
      staged-copy-then-swap and the bootout/bootstrap wait that `install.sh` already learned the hard
      way; **`ProcessType` is not `Interactive` here** — the UI is off the keypress path by design
- [x] tests: the plist's placeholders are all ones the installer replaces (the existing
      `BundleTests` pattern); the bundle id in the plist matches the one the menu app compiles
      against; `linkage.sh` is proven able to fail by pointing it at a binary that does link CoreML
- [x] **measure and record in `CLAUDE.md`**: that a `MenuBarExtra` status item actually appears when
      its app is started by a `gui/$UID` LaunchAgent — expected, never observed here
- [x] **measure and record**: that installing the second bundle leaves the daemon's TCC grant intact
      (`bundle.sh --print-requirement` unchanged, no second microphone prompt)
- [x] run `bash Scripts/test.sh` and `bash Scripts/lint.sh`

### Task 3: `watch` — the second connection shape

The largest task, and the one with the most to get wrong. `ControlServer.serve` reads exactly one
frame, calls a handler that returns exactly one `Response`, writes it and returns; `ControlClient`
is documented as opening and closing per command — "a keypress is not a session". Everything below
exists because that guarantee has to be re-established for a connection that lives for hours.

**Files:**
- Modify: `Sources/DictaCore/Wire.swift`, `Sources/DictaIPC/ControlSocket.swift`
- Create: `Sources/DictaTestRunner/WatchProtocolTests.swift`,
  `Sources/DictaTestRunner/WatchStreamTests.swift`
- Modify: `Sources/DictaTestRunner/WireTests.swift`, `ControlSocketTests.swift`

- [x] **TDD, pure first:** add `watch` to `Command`; define the event frame the daemon pushes and an
      explicit **end-of-stream** frame, distinguishable from a closed connection — the server never
      closes silently, because a client reads a close as `closedByPeer` and reports a dead daemon,
      which is why an oversized answer is already refused with a short `Response` rather than a
      hang-up
- [x] **TDD:** `Command.isServedConcurrently` gains `watch`, and the comment says *why* the list is
      not loose: `abort` was alone because every other verb begins or ends an attempt and two of
      those resolving at once is what D7 forbids; D29's `dictate` has since joined it, which is the
      worked example that the list is a test rather than a habit; `watch` does neither either, so it
      qualifies as the third member rather than as an exception
- [x] **TDD:** a timeout policy for a stream. `pipelineRead` and `clientRead` both mean "one answer";
      a watcher idle for an hour because nobody dictated is healthy. Give the stream its own value —
      the **sixth** in `ControlTimeouts`, beside D29's `dictateWait = 60.0` — and its own case in
      `read(for:)`, and assert that no chord-sending verb accidentally inherits it. Read the current
      file for the numbers, never a figure quoted in prose
- [x] **TDD:** a maximum number of concurrent watchers, refused with a short `Response` rather than a
      dropped connection. Today "how many connections may exist" is answered by "connections are
      momentary"; a watcher breaks that premise, and the per-connection real `Thread` — required, not
      incidental, because Darwin's non-overcommit pool was measured starving the front door — is what
      the bound protects
- [x] implement the streaming serve path in `ControlServer`, leaving the one-frame path byte-identical
      for every other verb
- [x] implement the client half in `DictaIPC`: a watch connection on a **real `Thread`**, delivering
      snapshots to a callback, reporting a clean end-of-stream distinctly from a transport failure
- [x] tests, against a real socket: a watcher receives a snapshot on every transition; a slow reader
      is coalesced to the newest state and never handed a queue of stale ones; a watcher that goes
      away is dropped and never retried; a watcher does **not** delay or block a concurrent `toggle`;
      the watcher cap is enforced and its refusal is a `Response`, not a hang-up; and — the one that
      matters most — **the daemon still answers chords while a watcher has been connected for the
      whole test**
- [x] run `bash Scripts/test.sh` and `bash Scripts/lint.sh`

### Task 4: The readiness snapshot, and the daemon's observer hook

What a watcher receives. The lifecycle state alone cannot draw the panel: the fault banners need
facts the daemon holds and has never published — whether the models loaded, whether the microphone
is granted, whether `agtermctl` was found.

**Files:**
- Modify: `Sources/DictaCore/Wire.swift`, `Sources/DictaRuntime/Daemon.swift`
- Create: `Sources/DictaTestRunner/SnapshotTests.swift`
- Modify: `Sources/DictaTestRunner/DaemonTests.swift`

- [x] **TDD, pure:** a `StatusSnapshot` value — lifecycle state, current attempt and its target, the
      elapsed seconds and the cap, and a readiness verdict (`ready`, or a named reason: models
      missing, microphone denied, `agtermctl` absent). One value, so the glyph, the status line and
      the banner cannot disagree
- [x] **TDD, pure:** the mapping from `AttemptOutcome` to the row colour, and from the snapshot to
      the glyph and the status sentence. These are the vocabulary of §5.1 and §5.2 of the proposal in
      an assertable form, and they are what makes a divergence from acta fail rather than merely look
      different
- [x] give `Daemon` an observer hook fed from the `.announce` effects, which `apply` already performs
      **after releasing the lock** — so publishing is never inside `stateLock` and a slow socket write
      can never become part of a dictation
- [x] make `status` answer with the same snapshot, so the two routes cannot drift
- [x] tests: every transition publishes exactly one snapshot; an observer that throws or blocks does
      not affect the attempt's outcome; a snapshot is published after the transition is visible, never
      before; the readiness verdict is derived, not stored twice
- [x] **measure**: `Scripts/measure.sh` with a watcher attached, against F4's numbers as committed.
      A regression past its p95 vetoes the design of the hook
- [x] **The one way this task could cheat its own veto, named so it is not walked into.** The hook is
      fed from the `.announce` effects — the very effects that light the agterm indicator, which F4
      measures at ~35 ms of the ~165. A refactor that publishes to the UI first and defers the
      indicator would show a faster `measure.sh` while the indicator appears no sooner, and D13's
      rule (nothing announced before capture confirms) would still have to hold for the glyph
      anyway. **Publishing to a watcher may never reorder, delay or replace an announcement.** If the
      numbers improve after this task, establish why before believing them
- [x] run `bash Scripts/test.sh` and `bash Scripts/lint.sh`

### Task 5: `DictaRecord` — a bounded reader for an unbounded file

Two problems in one place. `FileHistory.entries()` parses the whole append-only record, which a
panel opening many times a day cannot afford; and it lives in `DictaRuntime`, which links FluidAudio,
where the UI must never reach. Extraction and bounding are the same edit.

**Files:**
- Create: `Sources/DictaRecord/RecordReader.swift`
- Modify: `Package.swift`, `Sources/DictaRuntime/History.swift`
- Create: `Sources/DictaTestRunner/RecordReaderTests.swift`

- [x] add the `DictaRecord` target (`DictaCore` only), with the comment naming the concrete reason
      the split exists — the menu app needs the reader and `DictaRuntime` is where CoreML lands —
      and noting it is the same argument that produced `DictaIPC`, not a new one
- [x] **TDD:** a tail reader that returns the last *n* entries without parsing the file from the
      start: read backwards in bounded chunks, split on newlines, decode only what is needed
- [x] **TDD, the cases that bite:** a torn last line (the file is append-only and a crash can leave
      one) is skipped, not fatal; a superseding line with the same id wins, exactly as
      `Record.entries` promises, **and the reader must look far enough back to find it**; an entry
      whose `final` is empty and whose `recognised` is not is returned intact and flagged, so the UI
      can label it `cancelled` and offer nothing to copy (D28's structural half)
- [x] D29's twelfth outcome, `returned`, is decoded and carried like any other — a dictation that
      left on its caller's stdout **landed**, so it reads green and behaves like `injected`
- [x] **`returned` is not `cancelled`, and the field is what says so.** `cancelled` works under D28
      because its `final` is *empty*; `returned` has a *full* `final` — the text was produced,
      sanitised and handed over — so every affordance an injected row has, a returned row has too.
      That is correct, and the reason it is safe is D28's other half: the UI has no re-send
      affordance at all, only copy. Assert the two side by side, because a reader who reasons from
      the outcome name instead of the field will get this backwards

      What `returned` does *not* establish is worth one word in the row: the text went to a script,
      and dicta cannot know what the script did with it. "Delivered" is true; "arrived somewhere the
      user can see it" is not, so the row says `returned to caller` rather than borrowing
      `injected`'s wording
- [x] `FileHistory` keeps its `History` conformance and delegates its reading to `DictaRecord`, so
      there is exactly one reader in the project
- [x] **This task bounds READING. It must never become a licence to bound the FILE.** The temptation
      is real and arrives in the next breath — "the panel parses less now, so cap the record too" —
      and rotation or age-based truncation would break two things silently. §9's superseding line
      wins because the file is append-only and `Record.entries` takes the last line per id; a
      rotation splitting an id's two lines across files makes the reader return the *superseded*
      one — a **silent** wrong answer about a specific attempt, with no sign that anything happened.
      And `acta`'s meeting correlation reads this journal retrospectively, sometimes long after:
      rotate it and old meetings stop correlating with an honest "no candidates", indistinguishable
      from "there were no dictations" — a stage that lies green, which is the loud half of the same
      failure. Append-only therefore has **three** named dependents now — §9's superseding line, this
      reader, and `acta`'s correlation pass — and that plurality is the point: an invariant with one
      named dependent gets repealed when that dependent's reason lapses. If rotation is ever wanted,
      it owes a marker saying the journal does not begin at the beginning of time.
      Verified 2026-08-23: no rotation exists anywhere, and `History.swift`'s `logrotate` mention is
      about why no `FileHandle` is held open, not about truncating anything
- [x] tests: fixture files — empty, one line, a torn tail, a superseded id, more entries than asked
      for, a file larger than one chunk; and an assertion that the reader touches a bounded number of
      bytes rather than the whole file, since that is the property being bought
- [x] run `bash Scripts/test.sh` and `bash Scripts/lint.sh`

### Task 6: Tier 0 — the lamp

**Files:**
- Modify: `Package.swift`, `Sources/DictaMenu/main.swift`
- Create: `Sources/DictaMenu/MenuApp.swift`, `Sources/DictaMenu/StatusViewModel.swift`,
  `Sources/DictaMenu/Panel.swift`
- Modify: `docs/manual-checklist.md`

- [x] `DictaMenu` gains `DictaRecord` as a dependency; `linkage.sh`'s row is re-run and still clean
- [x] `StatusViewModel`: owns the watch connection, **seeds its snapshot synchronously at
      construction** so the panel never opens blank (acta's `ControlViewModel` does exactly this and
      it is the detail most worth copying), subscribes from the view's `.task {}`, and reconnects
      with a backoff when the daemon restarts
- [x] the menu-bar glyph per the proposal's §5.2, including the two rows acta cannot have: a fault
      state, and **daemon not running** when the socket is absent — an absent socket means "not
      running", with no launch-on-demand, the same rule acta wrote into `actactl`'s constraints
- [x] D13 applies to the glyph in full: it lights on `listening`, never on the keypress
- [x] the panel at 300 pt with acta's vocabulary — header (glyph, name, one-line status, trailing
      monospaced timer), fault banners in red with their one action each (`Fetch Models…`, open the
      Privacy pane), the last attempt's failure in dismissible orange **carrying the same sentence
      the notification carried**, and the footer: `Open Record` left, `Restart` right
      — **partly, and the orange half was ticked over code that had none.** `Banner.dismissible`
      existed and nothing ever set it; §9's `error` reached no part of the UI. Found and closed in
      Task 10: the reason is a line on the row that failed, from `error` verbatim, for every row
      rather than only the last, and the dead flag is deleted. The lesson is the one D18 keeps
      teaching in new costumes — a field that looks like a feature reads as implemented to anybody
      who greps for it
- [x] `Restart` is `launchctl kickstart -k`, and the reason there is no `Quit` is written in a
      comment: launchd's `KeepAlive` would restart the daemon within ten seconds, and a control that
      cannot do what it says must not exist
- [x] the timer renders as `2:41 / 10:00` and turns amber in the last minute, so D15's cap stops
      being a surprise that eats a dictation
- [x] tests: the view model's state machine against a fake watch client — seeded state, reconnect
      after a daemon restart, the absent-socket verdict. The SwiftUI views themselves are not tested
- [x] **checklist items**, each with its pass condition: the glyph tracks the agterm indicator and
      never leads it; the panel opens without a blank frame; the fault banners appear on a machine
      with no models and with the microphone denied; opening the panel while agterm is frontmost
      silences the trigger and it returns when the panel closes (D22, expected and accepted)
- [x] run `bash Scripts/test.sh` and `bash Scripts/lint.sh`

### Task 7: Tier 1 — the receipt drawer

**Files:**
- Modify: `Sources/DictaMenu/Panel.swift`, `Sources/DictaMenu/StatusViewModel.swift`
- Create: `Sources/DictaMenu/RecentDictations.swift`
- Modify: `docs/manual-checklist.md`

- [x] the live target line — where the text is going, as a session **name** plus pane, resolved live
      for the active attempt only. §9's `Target` holds the id, and this does **not** change §9
- [x] `Stop and type` (red, prominent) and `Abort` (borderless), present **only** while an attempt is
      live, and **absent — not disabled — when idle**, because there is no Start (D30)
- [x] `Recent Dictations`: the last five entries through `DictaRecord`, dot colour from Task 4's
      pure mapping, primary line `final` truncated at the tail, secondary line relative time,
      outcome, mode and `audioSeconds` once `dicta-record-window` lands
- [x] a row whose `final` is empty and whose `recognised` is not shows `recognised`, is labelled
      `cancelled`, and its copy button is **absent rather than disabled** — rule 1a leaves it nothing
      to copy, which is D28 made structural rather than remembered
- [x] the copy button puts `final` on the clipboard, and there is no other route by which the UI
      produces text
- [x] tests: the row model — colour, label, what is copyable — driven from record fixtures, including
      every `AttemptOutcome` case exhaustively, so a new outcome fails to compile rather than
      rendering grey. That is not hypothetical: D29 added `returned` between the proposal and this
      plan, and it must read green with the label `returned to caller`. Include the pair
      `returned` / `cancelled` as an explicit case, since reasoning from the outcome's name rather
      than from `final` gets exactly that pair backwards (Task 5)
- [x] **checklist items**: after a `target-gone` attempt, the text is recoverable from the panel with
      no terminal; `Stop` from the panel ends a live dictation and types it into the pane the chord
      was pressed in, not the one focused now (D4)
- [x] run `bash Scripts/test.sh` and `bash Scripts/lint.sh`

### Task 8: §6, §8 and the checklist — written against `dicta-cf`'s text

Deliberately late. §6 is being rewritten on an uncommitted branch, and writing this against `main`
would produce a spec that contradicts itself an hour after the merge.

**Files:**
- Modify: `SPEC.md`, `docs/manual-checklist.md`

- [x] **first, ask `dicta-cf` for the current §6 and the invariant numbering** — do not read it off
      `main`
- [x] §6 — one row for the menu-bar glyph in the Feedback table, stating that it is driven by the
      same transitions as the agterm indicator and therefore cannot disagree with it
- [x] §8 — extend the invariant that keeps the capture stack off the keypress client to the menu
      binary, and the one that keeps event-tap symbols out of the daemon likewise; both are asserted
      by `Scripts/linkage.sh` and by nothing else, which the invariant should say
- [x] §7 — a watcher that dies, a watcher cap reached, and a daemon restart under a live watcher:
      three rows, each stating that no dictation outcome changes
- [x] `ChecklistTests` still parses `SPEC.md` and `docs/manual-checklist.md` against each other and
      against the suite's `@Test` names — every new invariant names the assertion that goes red
      first, or a human item with its pass condition
- [x] run `bash Scripts/test.sh` and `bash Scripts/lint.sh`

### Task 9: Measure what only running it can answer

**Files:**
- Modify: `CLAUDE.md`

- [x] chord → live microphone and chord → lit indicator, with the menu app running and a watcher
      attached, against ~95 ms / ~122 ms median / p95 145 ms. Record the numbers whichever way they
      come out
- [x] the panel's open-to-drawn latency with a record file of a realistic size, and the bytes the
      tail reader actually touched
- [x] daemon restart under a live watcher: the glyph returns to truth without the panel being opened
- [x] the D22 interaction, exactly: how long the trigger stays silent after the panel closes
- [x] logout/login: both LaunchAgents come back, and the menu app does not race the daemon into a
      "not running" glyph that never clears
- [x] record every one of these in `CLAUDE.md` as a measurement with its date, in the style of F4 —
      including the ones that came out boring

### Task 10: Documentation, and the one edit to acta

**Files:**
- Create: `docs/ui-vocabulary.md`
- Modify: `CLAUDE.md`, `README.md`, `docs/ui-proposal.md`
- Modify (in `../acta`, separately approved): `docs/ui-vocabulary.md`

- [x] write `docs/ui-vocabulary.md`: the table from the proposal's §5.1, the two conventions under it
      ("a control that cannot do what it says must not exist"; "every app in the family owns one
      glyph and keeps it"), and the table of **deliberate divergences**, so they are not later
      "fixed" into inconsistency
- [x] **the acta side needs its own approval and its own session** — the two repositories share no
      package, so the file is a copy, and it says so at the top. `acta-f3` reports `Sources/Acta/` is
      clear. The optional refactor there (collapsing `statusIcon`/`statusColor`/`statusText` into one
      pure presentation value so the header is assertable in both apps) is **not** in this plan
      — **approved and done on 2026-08-24, in this session rather than a separate one, at the
      user's direction and with one condition attached: check the table against acta's code first.**
      That check was the point. Reading `ActaApp.swift` and `ControlViewModel.swift` on
      `socket-transport` corrected four rows the proposal had wrong or thin — banners take an
      optional `xmark` and acta can show two at once; the primary action is `.controlSize(.large)`,
      which **dicta had not shipped**; acta's row primary is `.caption` where dicta's is `.callout`;
      and `MenuBarExtra` builds its content lazily, a hazard both apps hit and solved differently.
      The copy in `../acta/docs/ui-vocabulary.md` is uncommitted and asks acta for nothing; the
      optional presentation-value refactor there is still **not** in this plan
- [x] `CLAUDE.md`: the new targets and what each may link; the second bundle and its agent; the rule
      that the daemon cannot tell whether a UI is running; the watch connection shape and why it is
      not just a verb; the tail reader
- [x] `README.md`: installing and using the menu app, and that it is optional
- [x] mark `docs/ui-proposal.md` as **superseded by this plan** for anything the plan decided
      differently, rather than leaving two documents that disagree
- [x] no new tests; the documentation tests that already exist must still pass

## Post-Completion (human verification)

Everything a test cannot reach, with its pass condition, added to `docs/manual-checklist.md` as it is
written rather than at the end:

- The glyph tracks the agterm indicator through a whole dictation and never leads it.
- The panel opens without a blank frame, on a cold daemon and on a warm one.
- The fault banners appear on a machine with no models fetched, and with the microphone denied, and
  each one's single action fixes the thing it names.
- After a `target-gone` attempt, the text reaches the clipboard from the panel with no terminal.
- `Stop` from the panel types into the pane the chord was pressed in, not the one focused now.
- Opening the panel silences the push-to-talk trigger (D22) and it returns when the panel closes.
- Both LaunchAgents survive logout/login; a crashed daemon shows as "not running" and clears when it
  comes back.
- Installing the menu bundle prompts for no permission of any kind and does not re-prompt for the
  daemon's microphone.

## Not in this plan

- **Tier 2** — row expansion showing `recognised` vs `final` vs the rules that fired, and the D9b
  filter-command field. Both wait for step 4; the field would otherwise be a settings panel with one
  row in it.
- **A settings window and a dock icon.** Still out of scope, and §13 keeps saying so.
- **The agterm HUD panel** as an in-attempt surface. A real alternative, deferred because the request
  was consistency with acta and acta has no HUD; worth revisiting if the panel turns out to be opened
  rarely.
- **`actactl`**, and acta's presentation-value refactor. Both are acta's to schedule.
- **Any UI route that injects text.** Not deferred — refused (D28).
