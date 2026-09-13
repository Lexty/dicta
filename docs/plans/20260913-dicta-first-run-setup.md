# dicta — first-run setup: choosing where dictation goes, from a window

## Overview

The focused-field work (`docs/plans/completed/20260912-dicta-focused-fields.md`, branch
`dicta-focused-fields`) made the focused text field of any application a target. It left one thing
a non-technical person cannot do: **turn it on**.
- **The switch is a command-line flag.** `--focused-fields` exists only inside the daemon's
  LaunchAgent, written by `bash Scripts/install.sh --focused-fields`.
- **The grant prompt has no context.** `main.swift` calls `AXIsProcessTrustedWithOptions` at every
  start-up while the grant is missing, so the system's "control your computer" dialog arrives with
  no explanation.
- **A daemon with no agterm exits unless the flag was passed.** `DaemonOptions.agtermAtStartup`
  returns `.fatal` before the socket is bound, so a menu could not even tell it what the person
  chose.

This plan moves the choice into a **setup window in the menu bar app**, persisted in a file the
daemon owns, applied live, with the Accessibility request made from that window after it has
explained why. It changes nothing about how a dictation is captured, recognised or delivered.

The decisions it rests on — a joint recommendation with Codex, then the user's answers in the
brainstorm of 2026-09-13:

- **Fresh install: the primary action is the opt-in.** One window says what the product does and
  offers "Set up dictation". Choosing it is the conscious request D5 and invariant 14 require; there
  is no separate "everywhere or agterm?" question of equal weight. "Use only with agterm" is a
  secondary link, shown only when agterm is found. Having agterm installed is not taken as intent.
- **Update: behaviour is preserved, the capability is offered once.** An existing agterm-only user
  keeps agterm-only and sees "Dicta can now type into other apps" with Enable / Keep agterm only,
  once. A user already running with `--focused-fields` is not asked.
- **Until a choice is made**, agterm dictation works exactly as today, fields stay closed, and no
  accessibility call is made. Without agterm the daemon waits in a *not configured* state instead of
  exiting.
- **The daemon decides fresh versus update** when it finds no setup file: the flag, then whether
  the record holds any line.
- **The flag becomes a seed.** It is read only when the setup file does not exist yet; afterwards the
  file decides and the daemon logs that the flag was ignored.
- **The menu opens the window itself** when a choice or the one-time offer is pending, never during a
  dictation, and a "Set Up…" row reopens it.
- **Applied live (approach A).** A socket verb changes the setting and the daemon applies it without
  restarting: no lost speech, no launchd throttle.
- **The choice stays reversible from the window.** A person who enabled other apps can go back to
  agterm only, and one who declined can enable later, without `dictactl`.

The plan was reviewed with Codex on 2026-09-13 until both converged; the resolutions (no grant poll,
admission with generations, a replace that never loses the authoritative file, a state-to-screen
table, the hold keys in the snapshot) are folded into the sections below.

**This is a scope change to SPEC, not only an addition.** §13 and D27 currently put "a settings
window" out of scope, for a reason that still stands: a window that takes focus from agterm silences
the hold key under D22. Task 1 amends both, and the window is designed around that reason — it
activates only when it is opened on purpose or at the first snapshot after the menu launches, never
in the middle of a session.

**Out of scope, deliberately** (consumer-release requirements, not blockers for this work, as
agreed with Codex): Developer ID signing and notarization, one app instead of two bundles, the model
download inside the window with progress, choosing a new default hold key, and a quieter refusal
policy for holds outside text fields (`docs/backlog/field-refusal-before-a-switch.md`).

## Context (from discovery)

- **Branch.** `dicta-focused-fields` at `932803f`, not merged to `main`. This plan builds on it.
- **Files involved:**
  - `Sources/Dicta/main.swift` — start-up: options, `agtermAtStartup` (`:76`),
    `FocusedFieldWiring.make` (`:96`), `Daemon(...)` (`:111-140`), socket,
    `FocusedFieldWiring.startupLine` (`:166`), `requestTrust()` (`:171`), hold trigger
    (`:183-208`, custom keys and `--no-hold`), warm-up, the microphone request at start-up
    (`:252`), which this plan leaves where it is.
  - `Sources/DictaCore/DaemonOptions.swift` — `--focused-fields`; `agtermAtStartup(found:)`, whose
    `--no-hold` fatal (`:154-156`) guards a real dead end and stays.
  - `Sources/DictaCore/StatusSnapshot.swift` — `Readiness` with a per-case `blocksDictation`
    (`:42-47`); `Faculties` (its `focusedFields` fixed at construction, `:102-109`), held only inside
    the daemon today: the snapshot carries the verdict, not the facts, and nothing carries the hold
    keys or `--no-hold`.
  - `Sources/DictaCore/Presentation.swift:67-72` and `MenuModel.swift:132` — any blocking readiness
    draws a red triangle and a red banner. `MenuModel.Banner.Action` (`MenuModel.swift:39-46`) is
    switched over exhaustively by `StatusViewModel.perform` (`StatusViewModel.swift:344-358`).
  - `Sources/DictaCore/Wire.swift` — `Command` (`isServedConcurrently`, `isTypedByHand`), `Request`.
  - `Sources/DictaIPC/ControlSocket.swift:126` — `ControlTimeouts.read(for:)`.
  - `Sources/DictaCore/ClientCommand.swift` — `dictactl`; `ClientCommandTests.swift:32-43` requires
    every wire verb to parse; `DocumentationTests.swift:38-45` requires README to quote
    `ClientCommand.usage` verbatim.
  - `Sources/DictaCore/Paths.swift:42` — `config` (`config.json`) is reserved for D9b's filter
    command, so the setup state takes a file of its own.
  - `Sources/DictaRuntime/Daemon.swift` — `handle` switches over every `Command` with no default
    (`:504`); `let fields` (`:217`) read by `beginField` (`:651`) and `deliver` (`:1171`); handles
    stored in `onAcceptedStartLocked` (`:684-686`) and cleared in `apply` (`:788-790`);
    `snapshot()` (`:1683`), `publish()`, `observe(_:)` (`:1742`).
  - `Sources/DictaRuntime/FocusedField.swift` — `requestTrust()` is `static` (`:232`); the adapter
    lock is held across a whole `focusedElement` read; the injector's final validation checks
    `isTrusted` again (`:618`), which a closed gate must not remove from an accepted attempt.
  - `Sources/DictaRuntime/FocusedFieldWiring.swift` — `make(options:feedback:adapters:)`, `Wired`,
    `startupLine`; called by `DaemonOptionsTests.swift:156,172` and tested at `:195-206`.
  - `Sources/DictaRuntime/History.swift:105` — `FileHistory.entries()`; `Daemon` reads it once at
    construction for the next attempt id (`Daemon.swift:368`, a failure there counts as empty).
  - `Sources/DictaRuntime/HoldTrigger.swift` — `Configuration.focusedFields`, `fields`,
    `fieldsEnabled` (`:412`); the threshold's grant check and refusal (`:535`); `endField` uses
    `fields.pacer` and `fields.feedback` (`:580-596`).
  - `Sources/DictaMenu/DictaMenuApp.swift`, `StatusViewModel.swift` — `MenuBarExtra` only; the
    label's `.task` only calls `model.start()` (`DictaMenuApp.swift:44`); `send` deliberately drops
    the response (`:300-307`), because the watch stream is the UI's one source of state.
  - `Scripts/install.sh`, `Scripts/render-agent.sh`, `Scripts/launchagent.plist`.
  - `SPEC.md` — D5, D27 (`:463`), D31, invariants 13 and 14, §6 wire, §7, §13 (`:1488-1497`).
  - `docs/manual-checklist.md` — rows 13 and 14 (matched verbatim against §8's bold titles by
    `ChecklistTests.swift:223`), §7 rows (`:77`, `:83`, `:94`); the H procedures that name the flag
    as a precondition or a command: H11 (c), H19 (c) (`:336`), H24 (`:410`), H28 (a) (`:443`), (c)
    (`:448`, runs `install.sh --focused-fields`) and (e) (`:452-454`, expects `Basso`), H32
    (`:488`), H33 (`:499`); the last H item is H34.
  - `README.md`, `AGENTS.md` (finished plans move to `docs/plans/completed/`).
- **Tests the checklist cites that this plan renames or removes** (each task that touches one
  updates the citation in the same task, or `ChecklistTests` fails):
  - "with focused fields off, the wiring is nil and constructs no system adapter" (Task 6)
  - "a missing agterm blocks dictation only with focused fields off" (Task 5)
  - "with focused fields off, the accessibility fake records zero calls in every scenario" (Task 8)
  - "with focused fields off, the hold key does nothing at all in another application" (Task 8,
    cited twice)
  - "with the grant missing, a threshold refuses once, audibly, and sends nothing" (Task 8)
  - "a missing agtermctl is fatal with focused fields off, and survived with them on" (Task 9)
- **Cited tests whose expectations change without a forced rename** (checklist `:94`; "focused
  fields on" may stay as a description of the effective scope, but if one is renamed, all three are
  re-cited in the same task): "a missing agterm with focused fields on is an amber notice, and
  without them a fault", "a missing agterm with focused fields on is drawn as a working daemon, not
  a fault", "with no agterm, readiness blocks dictation only for a daemon without focused fields"
  (Task 5: the working-field cases gain `accessibility = true`, and missing-grant cases are added);
  the `optionOff` case of "a field start is refused before capture opens, for every reason it can be
  refused" (Task 7: it may survive as the gate-closed case, but `reasonMentions` at
  `DaemonTests.swift:2117` stops being `--focused-fields`).
- **Patterns to follow:**
  - Decisions are pure `DictaCore` values with tests (D19); `DictaMenu` is not importable by the
    test runner, so everything the window decides lives in `DictaCore`.
  - Accessibility adapters are built through `FocusedFieldWiring.Adapters`, whose test value counts
    calls — how "zero AX calls" is asserted.
  - No idle polling: the project refused 1 Hz `status` polling and a permanent ticker
    (`StatusViewModel.swift:164-170`, `Wire.swift:41-43`).
- **Facts already established:**
  - F11: the grant and its revocation are live without restart; `AXIsProcessTrusted` follows them,
    `CGPreflight*` do not; only `AXIsProcessTrustedWithOptions(prompt)` lists the bundle.
  - F8a: the frontmost application must come from ONE observer-backed `SystemFrontmost`.

## Development Approach

- **testing approach**: TDD — the failing test first, then the code, in every task.
- complete each task fully before moving to the next; small, focused changes.
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task:
  new functions, modified functions, new code paths, both success and error scenarios.
- **CRITICAL: all tests must pass before starting next task** — `bash Scripts/test.sh` (never
  `swift test`, D18) and `bash Scripts/lint.sh`.
- **CRITICAL: every task leaves the whole package building.** `Scripts/test.sh` runs `linkage.sh`
  first, which builds `Dicta`, `dictactl` and `DictaMenu`. A task that changes a signature fixes its
  callers — `main.swift` and `Daemon.swift` included — in that same task, with the smallest change
  that compiles, even when a later task replaces it.
- **CRITICAL: update this plan file when scope changes during implementation.**
- **Checklist citations follow the tests.** A §7 or §8 row may cite a test only once it exists; each
  task re-cites the rows its new tests cover, and renames the citations of tests it renames.
- The repository is English; the conversation with the user is Russian. Commit only when asked.

## Testing Strategy

- **unit tests**: required for every task, in `Sources/DictaTestRunner`, run by `Scripts/test.sh`.
- **no UI e2e framework exists.** The window's decisions are tested through the pure `SetupModel`;
  what only a person can see goes to `docs/manual-checklist.md` as H items (Task 1).
- **scripts are run, not grepped**, wherever a decision lives in them (Task 10's seed helper).
- **linkage**: `Scripts/linkage.sh` runs first; the menu gains no AX symbol.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview

**One persisted choice, one owner, one live gate.**

```
setup.json -- read at start (or migrated) --> SetupStore --> FocusedFieldSwitch --> beginField
    ^                                            |               (gate + built wiring)
    +-- write <-- `configure` <-- setup window   |                                 --> trigger
                  `accessibility` ---------------+   snapshot.setup/faculties/hold --> SetupModel
```

- **`SetupState`** (DictaCore): `scope` (`undecided` | `agtermOnly` | `otherApps`), `offerSeen`,
  `schema`. Three facts, never one revision number: a schema bump must not re-ask anybody.
- **`SetupMigration`** (DictaCore, pure): no file → flag → `otherApps`/seen; a record with any line
  (or an unreadable record) → `agtermOnly`/not seen; otherwise `undecided`/not seen.
- **`SetupStore`** (DictaRuntime): reads and writes `setup.json` (a new `Paths.setup`). An
  unreadable file is reported as a typed load problem, treated as `agtermOnly` for behaviour, and
  never overwritten by the reader. The store keeps that load problem until a successful explicit
  replacement, so every `configure` while it stands — a retry after a failed one included — goes
  through `replace`, which preserves the original as a backup. A failed write is a separate, last
  write error, cleared by the next successful write; it never replaces the load problem.
- **`FocusedFieldSwitch`** (DictaRuntime): the field wiring, built lazily and at most once, on the
  first `otherApps`, and kept for the process; a gate that follows the scope; a **generation**
  bumped on every `setOpen`; and the last known grant. With the gate closed no new check is
  admitted.
- **Admission, not a lock across calls.** A reader is admitted by reading `current`, which returns
  the wiring and the generation, or `nil` while closed. The trigger reads it at the press and again
  at the threshold; `beginField` reads it once at the top, serialised with `configure` under
  `ControlServer`'s handler lock (`ControlSocket.swift:377`), which is what makes one read enough
  there. The trigger is not under that lock, so a close can land between its threshold read and its
  trust check: that one admitted trust check may still run, but nothing newly admitted does — no
  field read follows it, because the `start` it would send is refused by `beginField`'s re-read.
  A grant result is reported with the generation it was admitted under and **discarded** if that
  generation is no longer current or the gate is closed, so a result from a previous open never
  overwrites the grant of a new one.
- **An accepted attempt finishes under the rules it was accepted under.** It delivers through the
  built wiring regardless of the gate — the wiring is never destroyed — including the injector's
  final validation and its grant check (`FocusedField.swift:618`). A `.started` hold's release
  stops it through the wiring it captured, whatever the generation is by then. Final validation is
  never removed to satisfy the invariant's wording; the wording exempts it.
- **The grant is requested only from the window**, through `accessibility` with `prompt`, only while
  the scope is `otherApps`. The start-up prompt goes.
- **The grant is observed with no poll at all.** It is checked when the switch opens, when the window
  asks (`accessibility` without `prompt`: on opening the checklist and each time the window becomes
  key again, which is the person coming back from System Settings), after a prompt, and by the
  checks every field start already makes at the threshold and in `beginField`, which report both
  `true` and `false`. Every result updates the switch's last known grant and readiness together, so
  the two cannot disagree. No timer, no lease: a revocation while nobody looks is noticed at the
  next check, not within seconds.
- **The window's every decision is `SetupModel`** (DictaCore), including the screen for each state
  and what each button sends. `DictaMenu` renders it, sends the verbs, and reads every consequence
  — success or a failed write — from the watch stream, as it does today.

## Technical Details

**`setup.json`** (`Paths.current.setup`, next to `config.json`, which stays D9b's):

```json
{"schema": 1, "scope": "other-apps", "offerSeen": true}
```

- `scope` raw values: `undecided`, `agterm-only`, `other-apps`. Unknown keys are ignored on read.
  An unknown `scope`, a `schema` newer than the build, or invalid JSON is *unreadable*.
- Written by the daemon only: encode, write `setup.json.tmp` in the same directory with mode 0600,
  `fsync` it, `rename(2)` it over `setup.json`. Every step's failure is thrown and ends the
  operation; a failed `fsync` refuses it too.
- `replace` — a `configure` over an unreadable file — never leaves a moment without the
  authoritative path: write and `fsync` `setup.json.tmp`; remove an older `setup.json.unreadable`;
  `link(2)` `setup.json` to `setup.json.unreadable` (the original stays where it is); then
  `rename(2)` the temporary file over `setup.json`. A failure at any step before the rename leaves
  `setup.json` byte-identical, so a restart still reports it unreadable and never re-migrates — not
  even with a legacy `--focused-fields` still in the agent. Success clears the problem. This is the
  operational failure contract, not a power-loss transaction; there is no journal.
- `SetupStore(url:)` has no default URL (the `activeTargetFile` convention, `Daemon.swift:148-152`),
  so no test reaches the real file. `Scripts/run.sh` uses the real one, as it does the record.

**Migration** (`SetupMigration.initial(flag:record:)`, used only when the file does not exist;
`record` is `.lines(Int)` or `.unreadable`, derived by a pure `SetupMigration.recordFact` from a
`FileHistory().entries()` read in `main.swift`. That is a second full read of the record at start-up,
next to `Daemon`'s own (`Daemon.swift:368`), accepted for this increment rather than engineered
away):

| `--focused-fields` | record | scope | offerSeen |
|---|---|---|---|
| yes | any | `otherApps` | `true` |
| no | one line or more (any outcome), or unreadable | `agtermOnly` | `false` |
| no | no lines, or no file | `undecided` | `false` |

**Behaviour per state** (the daemon no longer exits for a missing agterm, except under `--no-hold`,
where nothing could ever start a dictation — that exit stays):

| scope | agterm found | agterm not found |
|---|---|---|
| `undecided` | agterm path as today; gate closed; no AX | *not configured*: socket served; holds do nothing; no AX |
| `agtermOnly` | agterm path as today; gate closed; no AX | agterm missing, as today's `terminalMissing` |
| `otherApps` | agterm path and fields | fields only |
| unreadable file | as `agtermOnly` | as `agtermOnly` — the one case where a config file blocks a dictation, stated in §7 |

**Wire** (`Command`):

| verb | `Request` fields | concurrent | typed by hand | read timeout | `dictactl` |
|---|---|---|---|---|---|
| `configure` | `scope?`, `offerSeen?` (at least one) | no | yes | `pipelineRead` | `dictactl configure [--scope agterm-only\|other-apps] [--offer-seen]` |
| `accessibility` | `prompt?` | no | yes | `pipelineRead` | `dictactl accessibility [--prompt]` |

- `configure`: validate, then **persist, then set the gate, then observe and publish**, in that
  order under the handler lock. A failed write is `rejected` with the reason, changes nothing —
  the load problem included — and publishes `setup.saveError = reason` so the window can show it
  from the stream.
  `scope: undecided` is refused: undeciding is not a choice a person makes.
- `accessibility`: `rejected` unless the scope is `otherApps`, with zero accessibility calls. With
  `prompt: true` it calls `access.requestTrust()` (a seam on `FocusedFieldAccess`) and then takes a
  fresh `isTrusted` — asking is not evidence of a grant; without `prompt` only the `isTrusted`.
  Either way it reports the result through the switch (grant and readiness together), publishes,
  and answers `accepted`. It is the only verb that can prompt, and it never changes the scope.
- `pipelineRead`: both are serialised and can queue behind a running `stop`.
- No `status` or `watch` ever becomes an accessibility probe, and no `configure` is sent merely to
  re-read the grant.
- Both are also added to `Daemon.handle`'s switch in Task 4 as refusals ("not available in this
  build"), replaced in Task 7, so the build never breaks between the two.

**Snapshot.** No duplicated facts:
- `StatusSnapshot.setup: SetupSnapshot?` = `scope` (effective),
  `offerSeen`, `loadProblem: SetupLoadProblem?` (`unreadable(reason)` | `newerSchema`, standing
  until a successful replacement) and `saveError: String?` (the last failed write, cleared by the
  next successful one). Two fields, because a failed replacement must leave the window on the
  problem screen with its error, and the next retry must still replace.
- `StatusSnapshot.faculties: Faculties?` — the facts readiness is derived from, with `scope` and
  `accessibility: Bool?` in place of `focusedFields`, so the checklist rows read microphone, models,
  agterm and the grant from one place.
- `accessibility` is `nil` whenever the scope is not `otherApps`: reporting it would be an AX call the
  person has not asked for.
- `StatusSnapshot.hold: HoldSnapshot?` — what the trigger was armed with: `.armed(keys: [String])`
  (the display names of the effective keys, custom ones included) or `.disabled` (`--no-hold`). An
  explicit `.disabled` rather than `nil`, because an older daemon's snapshot lacks the field too, and
  its user must not be told that no hold key is armed. `nil` means "not reported": the window then
  names no gesture.
- `StatusSnapshot.faculties` is new on the wire (today the facts stay inside the daemon and only the
  verdict is sent). The optional fields decode from older JSON with synthesized `Codable`; the
  old-JSON tests are what hold that.
- The running menu between the daemon's reload and its own (`install.sh`) decodes a snapshot with
  new `Readiness` raw values it does not know; the two ship together and are reloaded seconds
  apart, which is accepted rather than engineered around.

**Readiness.** One verdict, and now two properties instead of one:
- `blocksDictation` — whether a hold or chord pressed now would be refused (unchanged meaning).
- `isFault` — whether something is broken, as opposed to a step the person has not done yet. Only a
  fault draws the red triangle and a red banner; a pending step is amber with the quiet glyph.

| verdict | when | blocks | fault |
|---|---|---|---|
| `microphoneDenied` | microphone denied | yes | yes |
| `modelsMissing` | models missing | yes | yes |
| `terminalMissing` | scope `agtermOnly` (or unreadable), no agterm | yes | yes |
| `starting` | anything still unknown | no | no |
| `setupNeeded` | scope `undecided`, no agterm | yes | no |
| `accessibilityNeeded` | scope `otherApps`, grant missing, no agterm | yes | no |
| `accessibilityForFields` | scope `otherApps`, grant missing, agterm found | no | no |
| `fieldsOnly` | scope `otherApps`, no agterm | no | no |
| `ready` | otherwise | no | no |

- The notices come AFTER `starting`, preserving the rule at `StatusSnapshot.swift:107-108`: a notice
  must not claim a readiness nobody has established. "Unknown" includes `accessibility` only when the
  scope is `otherApps`.
- `Presentation.of` and `MenuModel.banner` switch from `blocksDictation` to `isFault` for red; the
  banner action for the three setup verdicts is `openSetup`.

**Trigger and daemon without the grant, and after the gate closes.**
- At the press, a closed gate means `.ignore` (silent, as D22).
- At the threshold, in order: the gate again (closed → abandon silently, **before** any
  accessibility call), liveness, the grant (reported either way with the admitted generation;
  missing → abandon **silently**), the frontmost pid, then `start`.
- Only a `.started` field hold keeps the `FocusedFields` it captured, for `endField`'s pacer and
  feedback.
- `beginField` with the gate closed refuses as "dicta is not set up to type into other apps"
  (replacing "not started with --focused-fields"); with the grant missing it still refuses out loud,
  because a socket caller other than the trigger has nothing else showing it anything.

**Invariant 14, reworded** (Task 1): accessibility calls are made only for checks admitted while the
person's choice was `otherApps`, and for the final validation and delivery of an attempt accepted
under it; keystrokes are posted into another application only for such an attempt, into a target
that re-validated immediately before delivery; never by `dictactl` or the menu; the daemon never
reads a field's value or selected text. Invariant 13 drops its `--focused-fields` wording the same
way.

**`SetupModel`** (DictaCore, pure).
- Inputs: the latest snapshot or none; `firstSnapshotOfThisLaunch: Bool`; `accessibilityRequested:
  Bool` (clicked in this window this launch).
- **`FirstSnapshotLatch`** (DictaCore, a small value type): `StatusViewModel.receive` asks it on
  every snapshot; it answers `true` exactly once per menu process, on the first real snapshot —
  consumed even when that snapshot is busy — and never resets on a reconnect or on closing the
  window.
- `shouldAutoOpen` — only when the latch says first, and only if `state == .idle` and (`scope ==
  .undecided` or (`scope == .agtermOnly` and `!offerSeen`) or `loadProblem != nil`). `saveError`
  alone is never a reason, and never suppresses one: a failed first bootstrap save still opens the
  first-run screen. A menu whose first snapshot is busy forfeits the auto-open for this
  launch, deliberately; the row and the banner still offer it. Never opened later, so it cannot
  steal focus from the pane just dictated into.
- `screen` — one row per state, all tested:

| state | screen |
|---|---|
| `loadProblem != nil` (whatever `saveError` says) | `.problem` (choose again, as on fresh) |
| `undecided` | `.fresh(showsAgtermOnly: agtermFound)` |
| `agtermOnly`, `!offerSeen` | `.offer(firstTime: true)` — "Dicta can now type into other apps" |
| `agtermOnly`, `offerSeen` | `.offer(firstTime: false)` — an ordinary enable screen, no "now" |
| `otherApps` | `.checklist(rows)`, with a "Use only with agterm" control |
| no snapshot, or no `setup` in it | `.unavailable` (an older daemon; nothing to send) |

- `saveError` is not a screen and not an input to the table: it is shown inline on the screen the
  table picks, which is the one whose operation failed, because a failed write changes neither the
  scope nor the load problem. A successful replacement clears both.
- Button payloads (all tested):

| screen | button | sends |
|---|---|---|
| fresh | Set up dictation | `configure(scope: otherApps, offerSeen: true)` |
| fresh | Use only with agterm | `configure(scope: agtermOnly, offerSeen: true)` |
| offer (first time) | Enable | `configure(scope: otherApps, offerSeen: true)` |
| offer (first time) | Keep agterm only / close | `configure(offerSeen: true)` |
| offer (not first time) | Enable | `configure(scope: otherApps, offerSeen: true)` |
| offer (not first time) | close | nothing |
| problem | Set up dictation / Use only with agterm | as on fresh |
| checklist | Allow Access… | `accessibility(prompt: true)` |
| checklist | Open Accessibility Settings | the deep link, and `accessibility(prompt: false)` |
| checklist | Use only with agterm | `configure(scope: agtermOnly, offerSeen: true)` |
| checklist | the window opens or becomes key | `accessibility(prompt: false)` |
| fresh / checklist | close | nothing (fresh asks again next launch) |

- The "opens or becomes key" check is sent only when the latest snapshot's scope is `otherApps` (the
  daemon's refusal stays authoritative if that snapshot is stale), and it never prompts — including
  when the system dialog hands focus back to the window.
- Checklist rows from `faculties` and `hold`: accessibility (`nil`/false → "Allow Access…", then once
  requested "Open Accessibility Settings"; true → done); models (missing → the existing fetch
  action; unknown → waiting); microphone (denied → open settings; unknown → "waiting for the
  microphone permission asked at start-up" — the request stays in `main.swift`, and the window
  neither owns nor sequences it); hold key (`.armed(keys)` → the key names and "Hold it in any text
  field, wait for the sound, speak, let go."; `.disabled` → "no hold key is armed (`--no-hold`)";
  `nil` → no gesture row).

**Window copy** (English UI):
- Fresh — "Dictate into text fields in your apps"; "Hold the key, wait for the sound, speak, and let
  go." / "Speech is recognised on this Mac." / "Dicta needs the microphone, and Accessibility
  permission to type into other apps."
- Offer — "Dicta can now type into other apps".
- Accessibility row — "Lets Dicta type the words it heard into the app you are using."
- Deep link: `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`.
- Never "every field": search fields, combo boxes and unknown elements are refused (D31).

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): SPEC and checklist, the pure types, the store, the
  wire, readiness, the switch, the daemon, the trigger, start-up, the installer, the model, the
  window, documentation.
- **Post-Completion** (no checkboxes): scoring the new H items on hardware, on a clean account.

## Implementation Steps

### Task 1: SPEC and checklist — the choice replaces the flag, and a setup window enters scope

**Files:**
- Modify: `SPEC.md`
- Modify: `docs/manual-checklist.md`

- [x] D31: the scope is the person's choice in `setup.json`, made in the setup window or with
  `dictactl configure`; `--focused-fields` is a seed; the migration and per-state tables; the daemon
  no longer exits for a missing agterm (except under `--no-hold`)
- [x] D5, invariant 13 and invariant 14 reworded as in Technical Details (admission, and the
  exemption of an accepted attempt's final validation); the grant is requested only by
  `accessibility` with `prompt`; rewrite checklist rows 13 and 14 so their invariant cells contain
  the new bold titles verbatim (`ChecklistTests.swift:223`), keeping their existing citations for now
- [x] D27 and §13: a setup window is in scope; it activates only when opened on purpose or at the
  first snapshot of a menu launch, only if that snapshot is idle, never later, so it cannot take
  focus from agterm mid-session; the menu still makes no accessibility call
- [x] §6 wire: the two verbs, fields, timeouts, `dictactl` spellings; readiness: the table above,
  `isFault`, `SetupSnapshot`, `faculties` and `hold` in the snapshot
- [x] §7 rows: `configure` cannot write, including a failed replace over an unreadable file;
  `setup.json` unreadable or newer (including "the one case a config file blocks a dictation");
  `accessibility` outside `otherApps`; grant revoked while `otherApps` (noticed at the next check,
  readiness, no window, silent holds); the menu not running; `configure` during a dictation
  (affects the next start only); the gate closing between the threshold's read and its trust check;
  the hold on the field path without the grant becomes silent (replaces the notifying row at
  checklist `:83`, citation kept until Task 8)
- [x] `docs/manual-checklist.md`: a row per new §7 row citing H items until a test exists; rewrite
  every procedure that names the flag, so each states the persisted scope as its precondition and
  none runs `install.sh --focused-fields`: H11 (c), H19 (c), H24, H28 (a) (no start-up dialog; the
  hold without the grant is silent), H28 (c), H28 (e) (silence under a Focus mode too, not `Basso`),
  H32, H33; in the `:83` row, drop H28 (e) and the generic sound-and-notification test as evidence
  for the missing-grant hold (that test stays cited where a refusal is still audible); add H35
  onwards (see Post-Completion), keeping the H numbers contiguous
- [x] run `bash Scripts/lint.sh` and `bash Scripts/test.sh` — must pass before Task 2

### Task 2: `SetupState` and the migration, as pure values

**Files:**
- Create: `Sources/DictaCore/SetupState.swift`
- Modify: `Sources/DictaCore/Paths.swift`
- Create: `Sources/DictaTestRunner/SetupStateTests.swift`
- Modify: `Sources/DictaTestRunner/PathsTests.swift`

- [x] write failing tests: the migration table row by row; `recordFact` from a successful read with
  zero, one (an aborted line counts) and many lines, and from a failed read
- [x] write failing tests: JSON round trip; raw values; unknown keys ignored; unknown scope, newer
  schema and invalid JSON are unreadable with distinct `SetupLoadProblem`s, never a default
- [x] write failing tests: `Paths.setup` is `setup.json` in the support directory and distinct from
  `config`
- [x] implement `SetupScope`, `SetupState`, `SetupLoadProblem`,
  `SetupMigration.initial(flag:record:)`, `SetupMigration.recordFact`, `Paths.setup`
  (`SetupLoadProblem` is `unreadable(reason:)` | `newerSchema(found:)`; an unknown scope is
  `unreadable` with a reason naming it; `recordFact` takes a `Result<[RecordEntry], any Error>`)
- [x] run tests — must pass before Task 3

### Task 3: `SetupStore` — the daemon's one writer of `setup.json`

**Files:**
- Create: `Sources/DictaRuntime/SetupStore.swift`
- Create: `Sources/DictaTestRunner/SetupStoreTests.swift`
- Modify: `docs/manual-checklist.md`

- [x] write failing tests in a temporary directory: absent → `.absent`; valid → `.loaded`; each
  unreadable kind → `.unreadable(problem)` and the file is byte-identical afterwards
- [x] write failing tests: `save` goes through `setup.json.tmp`, `fsync` and rename, sets 0600; a
  failing save (read-only directory) throws with a reason and leaves the previous file intact
- [x] write failing tests: `replace(_:)` over an unreadable file leaves `setup.json.unreadable` with
  the old bytes and `setup.json` with the new state; an older `.unreadable` is replaced
- [x] write failing tests through a filesystem seam that fails one named step (the temporary write,
  `fsync`, removing the old backup, `link`, `rename`): each failure throws, and `setup.json` is
  byte-identical afterwards; then `bootstrap(flag: true, ...)` over the result still reports
  `unreadable` and applies `agtermOnly` — the failed replace never turns into a migration
- [x] write failing tests for `bootstrap(flag:record:)`: each migration row writes the file; an
  existing file ignores the flag and says so; unreadable writes nothing and reports the problem; a
  failed first save is a save error while the migrated state still applies
- [x] write failing tests: after a failed `replace`, the store still reports the load problem and
  the next `configure`-style write goes through `replace` again; a successful one clears the load
  problem and the save error
- [x] implement `SetupStore(url:)` (no default) with `load`, `save`, `replace`, `bootstrap`
- [x] re-cite the "setup.json unreadable" §7 row to these tests
- [x] run tests — must pass before Task 4

### Task 4: the wire — `configure`, `accessibility`, and their `dictactl` spellings

**Files:**
- Modify: `Sources/DictaCore/Wire.swift`, `Sources/DictaCore/ClientCommand.swift`
- Modify: `Sources/DictaIPC/ControlSocket.swift` (`ControlTimeouts.read(for:)`)
- Modify: `Sources/DictaRuntime/Daemon.swift` (temporary refusal in `handle`)
- Modify: `README.md` (the quoted usage block)
- Modify: `Sources/DictaTestRunner/WireTests.swift`, `ClientCommandTests.swift`,
  `ControlSocketTests.swift`, `DaemonTests.swift`

- [x] write failing tests: both verbs encode and decode; `Request.scope`/`offerSeen`/`prompt` round
  trip and are absent from every other verb's JSON
- [x] write failing tests: neither is served concurrently; both are typed by hand; both read with
  `pipelineRead` (extend the existing table tests)
- [x] write failing tests: `dictactl configure --scope other-apps|agterm-only`, `--offer-seen`, both;
  refusals for no option, `--scope undecided`, an unknown or empty scope;
  `dictactl accessibility` with and without `--prompt`, refusing any other option; give the parity
  test verb-specific arguments for `configure`, as it already does for `toggle` and `start`
- [x] implement the cases, fields, tables and `ClientCommand` parsing and usage; update README's
  quoted usage block in this task (`DocumentationTests`)
- [x] `Daemon.handle`: both verbs answer `rejected` "not available in this build" (test it), replaced
  in Task 7
- [x] run tests — must pass before Task 5

### Task 5: readiness that follows the scope, and faults told apart from pending steps

**Files:**
- Modify: `Sources/DictaCore/StatusSnapshot.swift`, `Presentation.swift`, `MenuModel.swift`
- Modify: `Sources/DictaRuntime/Daemon.swift` (`Faculties(...)` at construction, `snapshot()`)
- Modify: `Sources/DictaMenu/StatusViewModel.swift` (an interim `openSetup` case in `perform`)
- Modify: `Sources/DictaTestRunner/SnapshotTests.swift`, `MenuModelTests.swift`,
  `SnapshotPublishingTests.swift`, `DaemonTests.swift`, `docs/manual-checklist.md`

- [x] set `accessibility = true` explicitly in the `observe` closure of
  `noAgtermReadinessFollowsTheOption` (`DaemonTests.swift:2522-2542`), whose field-on daemon would
  otherwise sit at `starting` instead of `fieldsOnly`; add its missing-grant counterpart
- [x] write failing tests: `Faculties.readiness` over every row of the readiness table, including
  `starting` before every notice, `accessibility` counted as unknown only under `otherApps`, and
  `terminalMissing` for an unreadable file without agterm; the existing working-field cases gain
  `accessibility = true` explicitly, and the missing-grant cases (`accessibilityNeeded`,
  `accessibilityForFields`) are added beside them
- [x] write failing tests: `blocksDictation` and `isFault` for every case; `Presentation.of` draws the
  red triangle only for a fault; `MenuModel` banner red only for a fault, amber with `openSetup` for
  the three setup verdicts
- [x] write failing tests: `StatusSnapshot` decodes JSON without `setup`, `faculties` or `hold`
  (older daemon); `SetupSnapshot`, `faculties` and both `HoldSnapshot` cases (custom keys,
  `.disabled`) round trip
- [x] replace `Faculties.focusedFields` with `scope` and `accessibility`; add the verdicts,
  `isFault`, `SetupSnapshot`, `HoldSnapshot`, the snapshot fields, `Banner.Action.openSetup`; in
  `Daemon`, construct `Faculties` with a scope derived from `fields != nil` until Task 7 replaces
  it, and leave `hold` `nil` until Task 7 gives `Daemon` a place for it; in
  `StatusViewModel.perform`, `openSetup` does nothing yet (a temporary case, replaced in Task 12);
  `snapshot()` already carries `faculties`, read under the same lock as the verdict (Task 7 keeps
  it); `setup` stays `nil` until Task 7
- [x] rename the citation of "a missing agterm blocks dictation only with focused fields off"; if
  any of the three `:94` tests listed in Context is renamed, re-cite all three here (renamed to "a
  missing agterm is a fault only under agterm-only"; none of the three was renamed; row `:98` now
  also cites the missing-grant readiness and banner tests)
- [x] run tests — must pass before Task 6

### Task 6: `FocusedFieldSwitch` — wiring built once, a gate, and the grant observed

**Files:**
- Modify: `Sources/DictaRuntime/FocusedFieldWiring.swift`, `FocusedField.swift`
- Modify: `Sources/Dicta/main.swift` (build one `SystemFrontmost` and the switch where
  `make(options:)` was called; the start-up line; the trigger's frontmost source)
- Modify: `Sources/DictaTestRunner/Fakes.swift`, `DaemonOptionsTests.swift` (its `make` and
  `startupLine` tests move out); create `FocusedFieldSwitchTests.swift`
- Modify: `docs/manual-checklist.md`

- [x] write failing tests with counting adapters: a switch that was never opened calls no adapter
  (not even the trust check), `current` is `nil`
- [x] write failing tests: opening builds the wiring once from the frontmost source given at
  construction (never a second `SystemFrontmost`) and checks the grant once, synchronously; closing
  and reopening builds nothing; `built` survives closing; `current` is `nil` while closed; every
  `setOpen` bumps the generation `current` returns
- [x] write failing tests: a grant report with the current generation updates the last known grant
  and calls `onAccessibility`; a report from a closed switch, or from the generation before a
  close-and-reopen, is discarded and does not overwrite the new generation's grant
- [x] write failing tests: no timer exists — after any sequence of opens, closes and reports, the
  counting access records exactly the checks that were asked for
- [x] move `DaemonOptionsTests`' `make(options:)` and `startupLine` tests to
  `FocusedFieldSwitchTests` against the switch, keeping the checklist-cited names or re-citing them
- [x] add `requestTrust()` to `FocusedFieldAccess` (the system adapter calls the existing static;
  the fake counts)
- [x] implement `FocusedFieldSwitch(frontmost:feedback:adapters:onAccessibility:)` with
  `setOpen(_:)`, `current` (wiring and generation), `built`, `report(trusted:generation:) -> Bool`
  (whether the generation was current and the report accepted), and a
  `startupLine`; remove `make(options:)`; in `main.swift` build `SystemFrontmost` once, hand it to
  both the switch and the trigger, and open the switch when `options.focusedFields`, so behaviour
  is unchanged until Task 9
- [x] rename the citation of "with focused fields off, the wiring is nil and constructs no system
  adapter" (now "a switch never opened constructs no system adapter and makes no accessibility
  call", in the checklist's row 14 and AGENTS.md)
- [x] ➕ `main.swift` publishes the grant the opening checked (`$0.accessibility`) beside
  `$0.terminal`: since Task 5 a `--focused-fields` daemon otherwise sat at `starting`. The switch's
  `onAccessibility` is a no-op there until Task 7 hands the switch to the daemon, because the
  daemon does not exist when the switch first opens; the start-up `requestTrust` reads the switch's
  grant instead of a second trust check. Every `setOpen` also clears the last known grant, so a
  grant always belongs to the generation that checked it
- [x] run tests — must pass before Task 7

### Task 7: the daemon — `configure`, `accessibility`, and the gate at `beginField`

**Files:**
- Modify: `Sources/DictaRuntime/Daemon.swift`
- Modify: `Sources/Dicta/main.swift` (the new initialiser)
- Modify: `Sources/DictaTestRunner/DaemonTests.swift`, `Fakes.swift`, `docs/manual-checklist.md`

- [x] write failing tests: `configure(otherApps)` persists through a fake store, opens the switch,
  publishes the scope, and the next field start is accepted — no restart; the order persist → gate →
  publish is observed by the fake store and switch
- [x] write failing tests: a failed write is `rejected` with the reason, scope and gate unchanged, and
  the published snapshot carries `saveError`; a following successful `configure` clears it
- [x] write failing tests: `configure` over an unreadable file goes through `replace`; the full
  sequence unreadable (and newer schema) → a `configure` whose replace fails → the published
  snapshot carries `loadProblem` alongside `saveError` → a retry that goes through `replace` and
  succeeds → a published snapshot with neither field set (the screens for these snapshots are
  Task 11's, where `SetupModel` exists)
- [x] write failing tests: `configure(agtermOnly)` while a field attempt records — the attempt still
  delivers through its handle and the built injector, and its final validation still checks the
  grant; the NEXT field start is refused with zero accessibility calls and the new wording
- [x] write failing tests: `configure(offerSeen: true)` alone persists and publishes without touching
  the gate; `scope: undecided` is refused
- [x] write failing tests: `accessibility` under `undecided`/`agtermOnly` is refused with zero calls
  on the counting access; under `otherApps` without `prompt` it makes one `isTrusted` and no
  `requestTrust`; with `prompt` it makes one `requestTrust` followed by one `isTrusted`, and the
  published grant is that `isTrusted`, not the fact that it asked
- [x] write failing tests: `beginField`'s `isTrusted` result, `true` and `false`, reaches both the
  switch's last known grant and published readiness
- [x] rewrite the `optionOff` case of "a field start is refused before capture opens, for every
  reason it can be refused" as the gate-closed case; its `reasonMentions` (`DaemonTests.swift:2117`)
  names the new wording, not `--focused-fields`; re-cite row 14 if the case is renamed
- [x] implement: `Daemon` takes the switch, a store seam and the bootstrap state; `beginField` reads
  `switch.current` once; `deliver` uses `switch.built`; `snapshot()` fills `setup`, `faculties`
  and the `hold` it was constructed with (`main.swift` passes `nil` until Task 9); remove the Task 4
  refusal; keep `fieldHandle(for:)`
- [x] re-cite the `configure`-cannot-write, `accessibility`-outside-`otherApps` and
  `configure`-during-a-dictation §7 rows to these tests
- [x] ➕ the switch's `Adapters` gained an `injector` factory (default: `FocusedFieldInjector`), so a
  daemon test's wiring is built by the switch out of fakes; `tellAccessibility(to:)` replaces the
  switch's grant recipient, and the daemon installs itself there and then opens the switch for
  `other-apps`, so the opening's check reaches readiness like any other. `Daemon.Setup` is
  `fieldSwitch`, `store` (`SetupPersisting`, which `SetupStore` adopts) and `state`; `setup` defaults
  to `nil`, a daemon that is agterm only and refuses both verbs. A snapshot masks the grant outside
  `other-apps`, so a report landing around a close cannot claim a grant nobody may look at. Until
  Task 9, `main.swift` hands the daemon `SetupStore(url: Paths.current.setup)` with a state still
  derived from the flag, not bootstrapped
- [x] run tests — must pass before Task 8

### Task 8: the hold trigger reads the gate at the press and at the threshold, and stays silent

**Files:**
- Modify: `Sources/DictaRuntime/HoldTrigger.swift`
- Modify: `Sources/Dicta/main.swift`
- Modify: `Sources/DictaTestRunner/HoldTriggerTests.swift`, `docs/manual-checklist.md`

- [ ] write failing tests: gate closed at the press → `.ignore`, zero accessibility calls, even if it
  opens during the hold
- [ ] write failing tests: gate open at the press and closed before the threshold → the hold is
  abandoned silently with zero accessibility calls and no `start` sent
- [ ] write failing tests: gate closed (and closed-and-reopened) after a `.started` field hold → its
  release still stops it, using the `FocusedFields` it captured
- [ ] write failing tests: the gate closes between the threshold's gate read and its `isTrusted` →
  that one admitted check may run; `switch.report` returns that its generation was stale, the
  trigger abandons on that answer, no frontmost read or field read follows, and no `start` is sent
- [ ] write failing tests, separately, with the daemon in the loop: the gate closes after the
  threshold's accepted report but before the socket handles its `start` → `beginField` refuses it
  with zero further calls
- [ ] write failing tests: a threshold without the grant sends nothing, plays no sound, posts no
  notification, and reports `false` with its generation; a threshold with the grant reports `true`
- [ ] replace `Configuration.focusedFields` and `fields` with `@Sendable () ->
  (FocusedFields, generation)?` read at the press and at the threshold, and a report callback;
  `FieldHold` carries `FocusedFields` only once `.started`
- [ ] rename the citations of "with focused fields off, the accessibility fake records zero calls in
  every scenario", "with focused fields off, the hold key does nothing at all in another
  application" (both places) and "with the grant missing, a threshold refuses once, audibly, and
  sends nothing"
- [ ] run tests — must pass before Task 9

### Task 9: start-up — bootstrap the choice, never exit for agterm, no prompt

**Files:**
- Modify: `Sources/Dicta/main.swift`, `Sources/DictaCore/DaemonOptions.swift`
- Modify: `Sources/DictaCore/StatusSnapshot.swift` (`HoldSnapshot.of`)
- Modify: `Sources/DictaTestRunner/DaemonOptionsTests.swift`, `SnapshotTests.swift`,
  `docs/manual-checklist.md`

- [ ] write failing tests: `agtermAtStartup(found:)` is `.fatal` only for `--no-hold` without agterm,
  whatever the scope; otherwise `.present` or `.optional`
- [ ] write failing tests: a pure `StartupLines.describe(...)` for the log lines — the scope and its
  origin (migrated, from file, flag ignored), "not configured: waiting for setup", a setup problem
- [ ] update the usage text: `--focused-fields` is "the initial choice when setup has not been done";
  update README's `Dicta --help` quotation if the documentation test covers it
- [ ] write failing tests: a pure `HoldSnapshot.of(armHoldTrigger:keys:)` gives `.armed` with the
  default keys, `.armed` with custom keys, and `.disabled` under `--no-hold`
- [ ] `main.swift`: `SetupStore(url: Paths.current.setup).bootstrap` with `SetupMigration.recordFact`
  over a `FileHistory().entries()` read (the second start-up read, as stated in Technical Details);
  open the switch for `otherApps`; remove `requestTrust()`; hand the daemon its `HoldSnapshot`;
  log the lines
- [ ] rename the citation of "a missing agtermctl is fatal with focused fields off, and survived with
  them on"
- [ ] run tests — must pass before Task 10

### Task 10: the installer stops choosing, and does not lose an existing choice

**Files:**
- Create: `Scripts/agent-seed.sh`
- Modify: `Scripts/install.sh`
- Modify: `Sources/DictaTestRunner/BundleTests.swift`

- [ ] write failing tests that RUN `agent-seed.sh <old-agent-plist> <setup-json>` for all four
  combinations (old agent with/without the flag × setup file present/absent), plus no old agent at
  all (a first install) and a present but unreadable setup file (present: no reseed), with paths
  containing a space: it prints `--focused-fields` only for "old agent had it and no setup file",
  else nothing
- [ ] write failing tests: `install.sh --focused-fields` is refused, naming the menu's "Set Up…" and
  `dictactl configure`; `install.sh` passes `agent-seed.sh`'s output to `render-agent.sh` (asserted
  by text, the decision itself by the run above)
- [ ] implement both scripts; the closing steps name the setup window instead of the Accessibility
  step
- [ ] ⚠️ `install.sh` itself is not run by tests (it replaces the live agent); H33 scores it
- [ ] run tests — must pass before Task 11

### Task 11: `SetupModel` — every decision the window makes

**Files:**
- Create: `Sources/DictaCore/SetupModel.swift`
- Create: `Sources/DictaTestRunner/SetupModelTests.swift`
- Modify: `Sources/DictaTestRunner/DaemonTests.swift` (the daemon-to-model sequence)

- [ ] write failing tests for `FirstSnapshotLatch`: `true` once, on the first snapshot even when it
  is busy; `false` for every later one, across a simulated reconnect and a window close
- [ ] write failing tests for `shouldAutoOpen`: no snapshot; not the first snapshot of the launch;
  busy; each scope with and without `offerSeen`; each load problem; `saveError` combined with each
  of those (it neither opens the window alone nor suppresses an open that is otherwise due)
- [ ] write failing tests: every row of the state-to-screen table, including `.unavailable` for a
  snapshot without `setup`
- [ ] write failing tests: every row of the button-payload table; the becoming-key check is sent only
  under `otherApps` and is never `prompt: true`, including right after "Allow Access…" was clicked
- [ ] write failing tests for checklist rows over `faculties` and `hold`, including
  `accessibilityRequested` switching the action to "Open Accessibility Settings", custom keys,
  `.disabled`, `hold == nil` naming no gesture, the microphone's start-up wording, and a
  `saveError` shown inline on the screen the table picks, `.problem` included, with its controls
- [ ] write failing tests: no copy contains "every field"
- [ ] write failing tests in `DaemonTests`: Task 7's failed-replace sequence carried through to
  `SetupModel.screen` — `.problem` with the error inline after the failure, `.checklist` or
  `.offer` with no error after the successful retry
- [ ] implement `SetupModel` and `FirstSnapshotLatch`
- [ ] run tests — must pass before Task 12

### Task 12: the setup window in `DictaMenu`

**Files:**
- Modify: `Sources/DictaMenu/DictaMenuApp.swift`, `StatusViewModel.swift`
- Create: `Sources/DictaMenu/SetupWindow.swift`
- Modify: `Sources/DictaTestRunner/MenuBundleTests.swift`

- [ ] ⚠️ measure first, on hardware: whether `@Environment(\.openWindow)` from the `MenuBarExtra`
  label opens a `Window` scene in this `LSUIElement` app and `NSApp.activate()` brings it forward;
  record the result here, and if it does not work, open through `NSApp` from the view model instead
- [ ] add `Window("Set Up Dicta", id: "setup")` rendering `SetupModel.screen`; the panel gains a "Set
  Up…" row, and `perform(.openSetup)` replaces Task 5's temporary no-op
- [ ] `StatusViewModel.receive` consults `FirstSnapshotLatch` and, when `SetupModel.shouldAutoOpen`,
  asks the scene to open (the label's `.task` only starts the model); `NSApp.activate()` only then
  and on an explicit open
- [ ] `StatusViewModel`: `configure(...)` and `accessibility(prompt:)` through the existing `send`
  (the answer stays dropped; a failed write arrives as `setup.saveError`); the non-prompting check on
  opening and on the window becoming key, as `SetupModel` decides; the Accessibility deep link
  through `NSWorkspace.open`; remember `accessibilityRequested` for this launch
- [ ] extend `MenuBundleTests` only where it asserts something real: `Scripts/linkage.sh` still
  passes the menu (no AX symbol); the latch and every decision are covered by Task 11
- [ ] run tests (including `Scripts/linkage.sh`) — must pass before Task 13

### Task 13: Verify acceptance criteria

- [ ] fresh (`undecided`, no agterm): the socket is served, readiness `setupNeeded` (amber, not a
  fault), zero accessibility calls, `shouldAutoOpen` true on the first snapshot
- [ ] existing agterm-only user: agterm dictation unchanged; offer shown once; every way of closing it
  records `offerSeen`
- [ ] `--focused-fields` users keep their mode across the upgrade, including the window in which
  `install.sh` rewrites the plist first
- [ ] `configure` applies without a restart, never to a live attempt; a failed write — a failed
  replace over an unreadable file included — changes nothing and is visible on the stream
- [ ] the grant is requested only by `accessibility` with `prompt` under `otherApps`; no start-up
  prompt; no timer anywhere checks the grant; a missing grant on a hold is silent
- [ ] a stale grant report (closed, or an earlier generation) never reaches readiness; an accepted
  attempt's final validation still runs after the gate closes
- [ ] from the window alone, a person can enable other apps after declining and return to agterm
  only after enabling
- [ ] every §7 row added in Task 1 that a machine can check cites a test; `ChecklistTests` pass
- [ ] run full test suite: `bash Scripts/test.sh`; `bash Scripts/lint.sh`
- [ ] no UI e2e suite exists; H items listed in Post-Completion

### Task 14: [Final] Update documentation

- [ ] `README.md`: Install without `--focused-fields`; "Dictating into any app" starts from the setup
  window and `dictactl configure`; the Accessibility paragraph follows the new flow
- [ ] `AGENTS.md`: where it stands; `setup.json` and its one writer; admission by generation, and the
  exemption of an accepted attempt's final validation; no grant poll; the two verbs; `isFault`
  versus `blocksDictation`;
  correct the model-load sentence in any text copied from this plan (17 s was a one-time cost)
- [ ] move this plan to `docs/plans/completed/` and update the paths that cite it (AGENTS.md)

## Post-Completion

*Items requiring manual intervention or external systems — no checkboxes, informational only*

**Manual verification** (H35 onwards in `docs/manual-checklist.md`):
- A fresh install on a clean macOS account with no agterm and no `setup.json`: the window opens on
  its own after login, "Set up dictation", "Allow Access…" shows the system dialog, the row turns
  green without a restart, and the first hold in TextEdit and VS Code types.
- An update from agterm-only (record non-empty): agterm dictation works before any answer; the offer
  appears once; "Keep agterm only" and closing the window both stop it reappearing after a logout.
- An update from a `--focused-fields` install: no window, fields still work, the log says the flag
  seeded the choice on the first start and was ignored afterwards.
- Grant and revoke in System Settings: the checklist row follows when the person comes back to the
  window, and the menu bar follows at the next hold; nothing is promised while the person stays in
  System Settings. With the grant revoked, a long hold in another app is silent and the banner turns
  amber. The system dialog handing focus back to the window causes a check, never a second dialog.
- From the window only: enable other apps, return to agterm only, enable again; each takes effect at
  the next hold without a restart.
- With custom hold keys, the checklist names those keys; under `--no-hold` it says no key is armed.
- The window never appears in the middle of a dictation, and never takes focus from agterm after the
  first snapshot of a menu launch.
- `setup.json` made unreadable by hand: agterm dictation still works, the log shows no accessibility
  call, the window opens with the problem, and choosing again keeps `setup.json.unreadable`.
- Measure and record: whether a second `AXIsProcessTrustedWithOptions(prompt)` while the first dialog
  is open shows a second dialog (F11 measured one call).

**Out of scope, recorded for the consumer release:**
- Developer ID signing and notarization; one app named Dicta instead of two bundles.
- Model download inside the window with progress, retry and resume.
- A tested activation gesture for laptops and "everywhere" use; the refusal policy for holds outside
  text fields.
