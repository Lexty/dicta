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
  - `Sources/Dicta/main.swift` — start-up: options, `agtermAtStartup` (`:121`),
    `FocusedFieldWiring.make` (`:96`), `Daemon(...)` (`:111-140`), socket, `requestTrust()`, hold
    trigger (`:183-198`), warm-up, microphone.
  - `Sources/DictaCore/DaemonOptions.swift` — `--focused-fields`; `agtermAtStartup(found:)`, whose
    `--no-hold` fatal (`:154-156`) guards a real dead end and stays.
  - `Sources/DictaCore/StatusSnapshot.swift` — `Readiness` with a per-case `blocksDictation`
    (`:42-47`); `Faculties` (its `focusedFields` fixed at construction, `:102-109`).
  - `Sources/DictaCore/Presentation.swift:67-72` and `MenuModel.swift:132` — any blocking readiness
    draws a red triangle and a red banner.
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
    lock is held across a whole `focusedElement` read.
  - `Sources/DictaRuntime/FocusedFieldWiring.swift` — `make(options:feedback:adapters:)`, `Wired`.
  - `Sources/DictaRuntime/HoldTrigger.swift` — `Configuration.focusedFields`, `fields`,
    `fieldsEnabled` (`:412`); the threshold's grant check and refusal (`:535`); `endField` uses
    `fields.pacer` and `fields.feedback` (`:580-596`).
  - `Sources/DictaMenu/DictaMenuApp.swift`, `StatusViewModel.swift` — `MenuBarExtra` only; the watch
    starts from `BarItem`'s `.task`; `send` deliberately drops the response (`:300-307`), because the
    watch stream is the UI's one source of state.
  - `Scripts/install.sh`, `Scripts/render-agent.sh`, `Scripts/launchagent.plist`.
  - `SPEC.md` — D5, D27 (`:463`), D31, invariants 13 and 14, §6 wire, §7, §13 (`:1488-1497`).
  - `docs/manual-checklist.md` — rows 13 and 14 (matched verbatim against §8's bold titles by
    `ChecklistTests.swift:223`), §7 rows, H11 (c), H28, H33; the last H item is H34.
  - `README.md`, `AGENTS.md` (`:112-113` says finished plans stay in `docs/plans/`).
- **Tests the checklist cites that this plan renames or removes** (each task that touches one
  updates the citation in the same task, or `ChecklistTests` fails):
  - "with focused fields off, the wiring is nil and constructs no system adapter" (Task 6)
  - "a missing agterm blocks dictation only with focused fields off" (Task 5)
  - "with focused fields off, the accessibility fake records zero calls in every scenario" (Task 8)
  - "with focused fields off, the hold key does nothing at all in another application" (Task 8,
    cited twice)
  - "with the grant missing, a threshold refuses once, audibly, and sends nothing" (Task 8)
  - "a missing agtermctl is fatal with focused fields off, and survived with them on" (Task 9)
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
                  `request-accessibility` -------+   snapshot.setup + faculties --> SetupModel
```

- **`SetupState`** (DictaCore): `scope` (`undecided` | `agtermOnly` | `otherApps`), `offerSeen`,
  `schema`. Three facts, never one revision number: a schema bump must not re-ask anybody.
- **`SetupMigration`** (DictaCore, pure): no file → flag → `otherApps`/seen; a record with any line
  (or an unreadable record) → `agtermOnly`/not seen; otherwise `undecided`/not seen.
- **`SetupStore`** (DictaRuntime): reads and writes `setup.json` (a new `Paths.setup`). An
  unreadable file is reported as a typed problem, treated as `agtermOnly` for behaviour, and never
  overwritten by the reader. A person's explicit `configure` over it moves the old file aside first.
- **`FocusedFieldSwitch`** (DictaRuntime): the field wiring, built lazily and at most once, on the
  first `otherApps`, and kept for the process; plus a gate that follows the scope. With the gate
  closed nobody calls the adapters.
- **The gate is read where a field attempt begins, and again before any accessibility call.** The
  trigger reads it at the press and again at the threshold; `beginField` reads it once at the top
  (serialised with `configure` under the handler lock, which is what makes one read enough). An
  accepted attempt delivers through the built wiring regardless of the gate — the wiring is never
  destroyed — so closing the gate cannot take a live attempt's handle or injector away.
- **The grant is requested only from the window**, through `request-accessibility`, only while the
  scope is `otherApps`. The start-up prompt goes.
- **The grant is observed without idle polling.** `setOpen(true)` checks it once, synchronously. A
  poll runs only while the scope is `otherApps` and the grant is missing, and stops once it is
  granted. A revocation is noticed by the checks the trigger and `beginField` already make, which
  report what they saw to readiness.
- **The window's every decision is `SetupModel`** (DictaCore), including what each button sends.
  `DictaMenu` renders it, sends the verbs, and reads every consequence — success or a failed write —
  from the watch stream, as it does today.

## Technical Details

**`setup.json`** (`Paths.current.setup`, next to `config.json`, which stays D9b's):

```json
{"schema": 1, "scope": "other-apps", "offerSeen": true}
```

- `scope` raw values: `undecided`, `agterm-only`, `other-apps`. Unknown keys are ignored on read.
  An unknown `scope`, a `schema` newer than the build, or invalid JSON is *unreadable*.
- Written by the daemon only: encode, write `setup.json.tmp` in the same directory, `rename(2)`,
  mode 0600. A `configure` over an unreadable file first renames it to `setup.json.unreadable`
  (replacing an older one), then writes; success clears the problem.
- `SetupStore(url:)` has no default URL (the `activeTargetFile` convention, `Daemon.swift:148-152`),
  so no test reaches the real file. `Scripts/run.sh` uses the real one, as it does the record.

**Migration** (`SetupMigration.initial(flag:record:)`, used only when the file does not exist;
`record` is `.lines(Int)` or `.unreadable`, derived by a pure `SetupMigration.recordFact` from the
history read `Daemon` already performs):

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
| `request-accessibility` | none | no | yes | `pipelineRead` | `dictactl request-accessibility` |

- `configure`: validate, then **persist, then set the gate, then observe and publish**, in that
  order under the handler lock. A failed write is `rejected` with the reason, changes nothing, and
  publishes `setup.problem = .saveFailed(reason)` so the window can show it from the stream.
  `scope: undecided` is refused: undeciding is not a choice a person makes.
- `request-accessibility`: `rejected` unless the scope is `otherApps`; otherwise
  `access.requestTrust()` (a seam on `FocusedFieldAccess`) and `accepted`. Starts the missing-grant
  poll. Never changes the scope.
- `pipelineRead`: both are serialised and can queue behind a running `stop`.
- Both are also added to `Daemon.handle`'s switch in Task 4 as refusals ("not available in this
  build"), replaced in Task 7, so the build never breaks between the two.

**Snapshot.** No duplicated facts:
- `StatusSnapshot.setup: SetupSnapshot?` (decoded with `decodeIfPresent`) = `scope` (effective),
  `offerSeen`, `problem: SetupProblem?` (`unreadable(reason)` | `newerSchema` | `saveFailed(reason)`).
- `StatusSnapshot.faculties: Faculties?` (decoded with `decodeIfPresent`) — the facts readiness is
  derived from, now also `scope` and `accessibility: Bool?`, so the checklist rows read microphone,
  models, agterm and the grant from one place.
- `accessibility` is `nil` whenever the scope is not `otherApps`: reporting it would be an AX call the
  person has not asked for.
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
  accessibility call), liveness, the grant (missing → abandon **silently**, report `accessibility =
  false` to readiness), the frontmost pid, then `start`.
- Only a `.started` field hold keeps the `FocusedFields` it captured, for `endField`'s pacer and
  feedback.
- `beginField` with the gate closed refuses as "dicta is not set up to type into other apps"
  (replacing "not started with --focused-fields"); with the grant missing it still refuses out loud,
  because a socket caller other than the trigger has nothing else showing it anything.

**Invariant 14, reworded** (Task 1): keystrokes are posted into another application, and its
accessibility read, only for attempts accepted while the person's choice was `otherApps`, and the
grant is checked only while that choice stands; never by `dictactl` or the menu; the daemon never
reads a field's value or selected text. Invariant 13 drops its `--focused-fields` wording the same
way.

**`SetupModel`** (DictaCore, pure).
- Inputs: the latest snapshot or none; `firstSnapshotOfThisLaunch: Bool`; `accessibilityRequested:
  Bool` (clicked in this window this launch).
- `shouldAutoOpen` — only for the first snapshot of this menu launch, and only if `state == .idle`
  and (`scope == .undecided` or (`scope == .agtermOnly` and `!offerSeen`) or `problem` is
  `unreadable`/`newerSchema`). A menu that starts during a dictation does not open the window this
  launch; the row and the banner still offer it. Never opened later, so it cannot steal focus from
  the pane just dictated into.
- `screen`: `.fresh(showsAgtermOnly: agtermFound)` | `.offer` | `.checklist(rows)` | `.problem`.
- Button payloads (all tested):

| screen | button | sends |
|---|---|---|
| fresh | Set up dictation | `configure(scope: otherApps, offerSeen: true)` |
| fresh | Use only with agterm | `configure(scope: agtermOnly, offerSeen: true)` |
| offer | Enable | `configure(scope: otherApps, offerSeen: true)` |
| offer | Keep agterm only / close | `configure(offerSeen: true)` |
| problem | Set up dictation / Use only with agterm | as on fresh |
| checklist | Allow Access… | `request-accessibility` |
| checklist | Open Accessibility Settings | the deep link, nothing sent |
| fresh / checklist | close | nothing (fresh asks again next launch) |

- Checklist rows from `faculties`: accessibility (`nil`/false → "Allow Access…", then once requested
  "Open Accessibility Settings"; true → done); models (missing → the existing fetch action; unknown →
  waiting); microphone (denied → open settings; unknown → "asked at the first dictation"); hold key
  (armed keys and "Hold it in any text field, wait for the sound, speak, let go.").

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

- [ ] D31: the scope is the person's choice in `setup.json`, made in the setup window or with
  `dictactl configure`; `--focused-fields` is a seed; the migration and per-state tables; the daemon
  no longer exits for a missing agterm (except under `--no-hold`)
- [ ] D5, invariant 13 and invariant 14 reworded as in Technical Details; the grant is requested only
  by `request-accessibility`; rewrite checklist rows 13 and 14 so their invariant cells contain the
  new bold titles verbatim (`ChecklistTests.swift:223`), keeping their existing citations for now
- [ ] D27 and §13: a setup window is in scope; it activates only when opened on purpose or at the
  first idle snapshot of a menu launch, never later, so it cannot take focus from agterm mid-session;
  the menu still makes no accessibility call
- [ ] §6 wire: the two verbs, fields, timeouts, `dictactl` spellings; readiness: the table above,
  `isFault`, `SetupSnapshot`, `faculties` in the snapshot
- [ ] §7 rows: `configure` cannot write; `setup.json` unreadable or newer (including "the one case a
  config file blocks a dictation"); `request-accessibility` outside `otherApps`; grant revoked while
  `otherApps` (readiness, no window, silent holds); the menu not running; `configure` during a
  dictation (affects the next start only); the hold on the field path without the grant becomes
  silent (replaces the notifying row, citation kept until Task 8)
- [ ] `docs/manual-checklist.md`: a row per new §7 row citing H items until a test exists; rewrite
  H11 (c), H28 (a) (no start-up dialog) and H33 (no flag); add H35 onwards (see Post-Completion)
- [ ] run `bash Scripts/lint.sh` and `bash Scripts/test.sh` — must pass before Task 2

### Task 2: `SetupState` and the migration, as pure values

**Files:**
- Create: `Sources/DictaCore/SetupState.swift`
- Modify: `Sources/DictaCore/Paths.swift`
- Create: `Sources/DictaTestRunner/SetupStateTests.swift`
- Modify: `Sources/DictaTestRunner/PathsTests.swift`

- [ ] write failing tests: the migration table row by row; `recordFact` from a successful read with
  zero, one (an aborted line counts) and many lines, and from a failed read
- [ ] write failing tests: JSON round trip; raw values; unknown keys ignored; unknown scope, newer
  schema and invalid JSON are unreadable with distinct `SetupProblem`s, never a default
- [ ] write failing tests: `Paths.setup` is `setup.json` in the support directory and distinct from
  `config`
- [ ] implement `SetupScope`, `SetupState`, `SetupProblem`, `SetupMigration.initial(flag:record:)`,
  `SetupMigration.recordFact`, `Paths.setup`
- [ ] run tests — must pass before Task 3

### Task 3: `SetupStore` — the daemon's one writer of `setup.json`

**Files:**
- Create: `Sources/DictaRuntime/SetupStore.swift`
- Create: `Sources/DictaTestRunner/SetupStoreTests.swift`
- Modify: `docs/manual-checklist.md`

- [ ] write failing tests in a temporary directory: absent → `.absent`; valid → `.loaded`; each
  unreadable kind → `.unreadable(problem)` and the file is byte-identical afterwards
- [ ] write failing tests: `save` goes through `setup.json.tmp` and rename, sets 0600; a failing save
  (read-only directory) throws with a reason and leaves the previous file intact
- [ ] write failing tests: `replace(_:)` over an unreadable file renames it to
  `setup.json.unreadable` first, then saves
- [ ] write failing tests for `bootstrap(flag:record:)`: each migration row writes the file; an
  existing file ignores the flag and says so; unreadable writes nothing and reports the problem; a
  failed first save is a `saveFailed` problem while the migrated state still applies
- [ ] implement `SetupStore(url:)` (no default) with `load`, `save`, `replace`, `bootstrap`
- [ ] re-cite the "setup.json unreadable" §7 row to these tests
- [ ] run tests — must pass before Task 4

### Task 4: the wire — `configure`, `request-accessibility`, and their `dictactl` spellings

**Files:**
- Modify: `Sources/DictaCore/Wire.swift`, `Sources/DictaCore/ClientCommand.swift`
- Modify: `Sources/DictaIPC/ControlSocket.swift` (`ControlTimeouts.read(for:)`)
- Modify: `Sources/DictaRuntime/Daemon.swift` (temporary refusal in `handle`)
- Modify: `README.md` (the quoted usage block)
- Modify: `Sources/DictaTestRunner/WireTests.swift`, `ClientCommandTests.swift`,
  `ControlSocketTests.swift`, `DaemonTests.swift`

- [ ] write failing tests: both verbs encode and decode (raw value `request-accessibility`);
  `Request.scope`/`offerSeen` round trip and are absent from every other verb's JSON
- [ ] write failing tests: neither is served concurrently; both are typed by hand; both read with
  `pipelineRead` (extend the existing table tests)
- [ ] write failing tests: `dictactl configure --scope other-apps|agterm-only`, `--offer-seen`, both;
  refusals for no option, `--scope undecided`, an unknown or empty scope;
  `dictactl request-accessibility` takes no option; give the parity test verb-specific arguments
  for `configure`, as it already does for `toggle` and `start`
- [ ] implement the cases, fields, tables and `ClientCommand` parsing and usage; update README's
  quoted usage block in this task (`DocumentationTests`)
- [ ] `Daemon.handle`: both verbs answer `rejected` "not available in this build" (test it), replaced
  in Task 7
- [ ] run tests — must pass before Task 5

### Task 5: readiness that follows the scope, and faults told apart from pending steps

**Files:**
- Modify: `Sources/DictaCore/StatusSnapshot.swift`, `Presentation.swift`, `MenuModel.swift`
- Modify: `Sources/DictaRuntime/Daemon.swift` (`Faculties(...)` at construction, `snapshot()`)
- Modify: `Sources/DictaTestRunner/SnapshotTests.swift`, `MenuModelTests.swift`,
  `SnapshotPublishingTests.swift`, `docs/manual-checklist.md`

- [ ] write failing tests: `Faculties.readiness` over every row of the readiness table, including
  `starting` before every notice, `accessibility` counted as unknown only under `otherApps`, and
  `terminalMissing` for an unreadable file without agterm
- [ ] write failing tests: `blocksDictation` and `isFault` for every case; `Presentation.of` draws the
  red triangle only for a fault; `MenuModel` banner red only for a fault, amber with `openSetup` for
  the three setup verdicts
- [ ] write failing tests: `StatusSnapshot` decodes JSON without `setup` or `faculties` (older
  daemon); `SetupSnapshot` and `faculties` round trip
- [ ] replace `Faculties.focusedFields` with `scope` and `accessibility`; add the verdicts,
  `isFault`, `SetupSnapshot`, the snapshot fields; in `Daemon`, construct `Faculties` with a scope
  derived from `fields != nil` until Task 7 replaces it
- [ ] rename the citation of "a missing agterm blocks dictation only with focused fields off"
- [ ] run tests — must pass before Task 6

### Task 6: `FocusedFieldSwitch` — wiring built once, a gate, and the grant observed

**Files:**
- Modify: `Sources/DictaRuntime/FocusedFieldWiring.swift`, `FocusedField.swift`
- Modify: `Sources/Dicta/main.swift` (build the switch where `make(options:)` was called)
- Modify: `Sources/DictaTestRunner/Fakes.swift`; create `FocusedFieldSwitchTests.swift`
- Modify: `docs/manual-checklist.md`

- [ ] write failing tests with counting adapters: a switch that was never opened calls no adapter
  (not even the trust check), `current` is `nil`
- [ ] write failing tests: opening builds the wiring once from the frontmost source given at
  construction (never a second `SystemFrontmost`) and checks the grant once, synchronously; closing
  and reopening builds nothing; `built` survives closing; `current` is `nil` while closed
- [ ] write failing tests: the missing-grant poll runs only while open AND the last check said
  missing, checks the gate before each tick, publishes only a change, and stops once granted or
  closed (a fake ticker, no sleeps)
- [ ] add `requestTrust()` to `FocusedFieldAccess` (the system adapter calls the existing static;
  the fake counts)
- [ ] implement `FocusedFieldSwitch(frontmost:feedback:adapters:onAccessibility:)` with
  `setOpen(_:)`, `current`, `built`; remove `make(options:)`; in `main.swift` build the switch and
  open it when `options.focusedFields`, so behaviour is unchanged until Task 9
- [ ] rename the citation of "with focused fields off, the wiring is nil and constructs no system
  adapter"
- [ ] run tests — must pass before Task 7

### Task 7: the daemon — `configure`, `request-accessibility`, and the gate at `beginField`

**Files:**
- Modify: `Sources/DictaRuntime/Daemon.swift`
- Modify: `Sources/Dicta/main.swift` (the new initialiser)
- Modify: `Sources/DictaTestRunner/DaemonTests.swift`, `Fakes.swift`, `docs/manual-checklist.md`

- [ ] write failing tests: `configure(otherApps)` persists through a fake store, opens the switch,
  publishes the scope, and the next field start is accepted — no restart; the order persist → gate →
  publish is observed by the fake store and switch
- [ ] write failing tests: a failed write is `rejected` with the reason, scope and gate unchanged, and
  the published snapshot carries `saveFailed`; a following successful `configure` clears it
- [ ] write failing tests: `configure` over an unreadable file goes through `replace`
- [ ] write failing tests: `configure(agtermOnly)` while a field attempt records — the attempt still
  delivers through its handle and the built injector; the NEXT field start is refused with zero
  accessibility calls and the new wording
- [ ] write failing tests: `configure(offerSeen: true)` alone persists and publishes without touching
  the gate; `scope: undecided` is refused
- [ ] write failing tests: `request-accessibility` under `undecided`/`agtermOnly` is refused with zero
  calls on the counting access; under `otherApps` it calls `requestTrust` once
- [ ] write failing tests: an `isTrusted` result seen by `beginField` reaches published readiness
- [ ] implement: `Daemon` takes the switch, a store seam and the bootstrap state; `beginField` reads
  `switch.current` once; `deliver` uses `switch.built`; `snapshot()` fills `setup` and `faculties`;
  remove the Task 4 refusal; keep `fieldHandle(for:)`
- [ ] re-cite the `configure`-cannot-write, `request-accessibility`-outside-`otherApps` and
  `configure`-during-a-dictation §7 rows to these tests
- [ ] run tests — must pass before Task 8

### Task 8: the hold trigger reads the gate at the press and at the threshold, and stays silent

**Files:**
- Modify: `Sources/DictaRuntime/HoldTrigger.swift`
- Modify: `Sources/Dicta/main.swift`
- Modify: `Sources/DictaTestRunner/HoldTriggerTests.swift`, `docs/manual-checklist.md`

- [ ] write failing tests: gate closed at the press → `.ignore`, zero accessibility calls, even if it
  opens during the hold
- [ ] write failing tests: gate open at the press and closed before the threshold → the hold is
  abandoned silently with zero accessibility calls and no `start` sent
- [ ] write failing tests: gate closed after a `.started` field hold → its release still stops it,
  using the `FocusedFields` it captured
- [ ] write failing tests: a threshold without the grant sends nothing, plays no sound, posts no
  notification, and reports the missing grant through the callback
- [ ] replace `Configuration.focusedFields` and `fields` with `@Sendable () -> FocusedFields?` read at
  the press and at the threshold; `FieldHold` carries `FocusedFields` only once `.started`
- [ ] rename the citations of "with focused fields off, the accessibility fake records zero calls in
  every scenario", "with focused fields off, the hold key does nothing at all in another
  application" (both places) and "with the grant missing, a threshold refuses once, audibly, and
  sends nothing"
- [ ] run tests — must pass before Task 9

### Task 9: start-up — bootstrap the choice, never exit for agterm, no prompt

**Files:**
- Modify: `Sources/Dicta/main.swift`, `Sources/DictaCore/DaemonOptions.swift`
- Modify: `Sources/DictaTestRunner/DaemonOptionsTests.swift`, `docs/manual-checklist.md`

- [ ] write failing tests: `agtermAtStartup(found:)` is `.fatal` only for `--no-hold` without agterm,
  whatever the scope; otherwise `.present` or `.optional`
- [ ] write failing tests: a pure `StartupLines.describe(...)` for the log lines — the scope and its
  origin (migrated, from file, flag ignored), "not configured: waiting for setup", a setup problem
- [ ] update the usage text: `--focused-fields` is "the initial choice when setup has not been done";
  update README's `Dicta --help` quotation if the documentation test covers it
- [ ] `main.swift`: build `SystemFrontmost` once; `SetupStore(url: Paths.current.setup).bootstrap`
  with `SetupMigration.recordFact` over `FileHistory().entries()`; open the switch for `otherApps`;
  remove `requestTrust()`; log the lines
- [ ] rename the citation of "a missing agtermctl is fatal with focused fields off, and survived with
  them on"
- [ ] run tests — must pass before Task 10

### Task 10: the installer stops choosing, and does not lose an existing choice

**Files:**
- Create: `Scripts/agent-seed.sh`
- Modify: `Scripts/install.sh`
- Modify: `Sources/DictaTestRunner/BundleTests.swift`

- [ ] write failing tests that RUN `agent-seed.sh <old-agent-plist> <setup-json>` for all four
  combinations (old agent with/without the flag × setup file present/absent), with paths containing
  a space: it prints `--focused-fields` only for "old agent had it and no setup file", else nothing
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

- [ ] write failing tests for `shouldAutoOpen`: no snapshot; not the first snapshot of the launch;
  busy; each scope with and without `offerSeen`; each problem
- [ ] write failing tests for `screen`: fresh with and without agterm; offer; checklist; problem
- [ ] write failing tests: every row of the button-payload table
- [ ] write failing tests for checklist rows over `faculties`, including `accessibilityRequested`
  switching the action to "Open Accessibility Settings", and a `saveFailed` problem shown on the
  screen that caused it
- [ ] write failing tests: no copy contains "every field"
- [ ] implement `SetupModel`
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
  Up…" row and the `openSetup` banner action
- [ ] auto-open from `BarItem`'s `.task` on the first snapshot of the launch when
  `SetupModel.shouldAutoOpen`; `NSApp.activate()` only then and on an explicit open
- [ ] `StatusViewModel`: `configure(...)` and `requestAccessibility()` through the existing `send`
  (the answer stays dropped; a failed write arrives as `setup.problem`); the Accessibility deep link
  through `NSWorkspace.open`; remember `accessibilityRequested` for this launch
- [ ] extend `MenuBundleTests`: the scene id is declared; `Scripts/linkage.sh` still passes the menu
  (no AX symbol) — everything the window decides is covered by Task 11
- [ ] run tests (including `Scripts/linkage.sh`) — must pass before Task 13

### Task 13: Verify acceptance criteria

- [ ] fresh (`undecided`, no agterm): the socket is served, readiness `setupNeeded` (amber, not a
  fault), zero accessibility calls, `shouldAutoOpen` true on the first snapshot
- [ ] existing agterm-only user: agterm dictation unchanged; offer shown once; every way of closing it
  records `offerSeen`
- [ ] `--focused-fields` users keep their mode across the upgrade, including the window in which
  `install.sh` rewrites the plist first
- [ ] `configure` applies without a restart, never to a live attempt; a failed write changes nothing
  and is visible on the stream
- [ ] the grant is requested only by `request-accessibility` under `otherApps`; no start-up prompt; no
  poll while granted or while the scope is not `otherApps`; a missing grant on a hold is silent
- [ ] every §7 row added in Task 1 that a machine can check cites a test; `ChecklistTests` pass
- [ ] run full test suite: `bash Scripts/test.sh`; `bash Scripts/lint.sh`
- [ ] no UI e2e suite exists; H items listed in Post-Completion

### Task 14: [Final] Update documentation

- [ ] `README.md`: Install without `--focused-fields`; "Dictating into any app" starts from the setup
  window and `dictactl configure`; the Accessibility paragraph follows the new flow
- [ ] `AGENTS.md`: where it stands; `setup.json` and its one writer; the gate read at the start of an
  attempt and before any accessibility call; the two verbs; `isFault` versus `blocksDictation`;
  correct the model-load sentence in any text copied from this plan (17 s was a one-time cost)
- [ ] finished plans: AGENTS.md (`:112-113`) says they stay in `docs/plans/`, but `f98782a` moved the
  focused-fields plan to `docs/plans/completed/`. Follow AGENTS.md: move that plan back, remove the
  empty directory, and leave this plan in `docs/plans/`

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
- Grant and revoke in System Settings: with the window open the row follows within a few seconds;
  with the grant revoked, a long hold in another app is silent and the banner turns amber.
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
