# dicta — dictation into any focused text field

## Overview

Today dicta types into agterm and nowhere else:
- §13 lists "any injection target other than agterm" as out of scope.
- D22 and invariant 13 make the hold key a silent no-op in every other application.
- The daemon exits at start-up when `agtermctl` is missing (`Sources/Dicta/main.swift:137`).

A user outside this project has asked to dictate into VS Code, both its editor and its integrated
terminal, which none of that allows.

This plan makes **the focused text field of any application** a second kind of target, and leaves
the agterm path exactly as it is. The decisions it rests on were taken by the user on 2026-09-12:

- **Any focused field, in any app.** Not a VS Code extension, and not an allow-list.
- **agterm becomes optional.** The daemon starts and dictates on a machine with no agterm.
- **Accessibility is opt-in.** Posting keystrokes into another process needs a TCC grant. Without
  `--focused-fields` the daemon calls no AX or event-posting API, so no permission prompt ever
  appears. D5's promise becomes "no permission unless you ask for this", not "no permission, ever".
- **Delivery is Unicode keystrokes** (`CGEventKeyboardSetUnicodeString`), not the pasteboard with a
  synthetic ⌘V and not `kAXSelectedTextAttribute`. The reasons are recorded in D32 (Task 2).
- **agterm frontmost always takes the agterm path.** It is more precise (session plus pane), it has
  the indicator, and it needs no grant.

The shape in one sentence, because every task below follows from it: **a target is either an agterm
pane or a focused field; either is captured at the start of an attempt (the field by the daemon,
shortly after the hold passes the floor), re-validated before delivery, and never re-aimed at
whatever has focus instead (D4). What D4 guarantees for a field is narrower than for a pane — never
another application and never an unvalidated field, but no detection of focus moving inside the same
application during delivery — and SPEC says so.**

### What makes this plan different from the last two

**Most of the risk is in facts nobody on this project has measured.**
- How fast Unicode keystrokes can be posted before an app drops some.
- Whether Electron honours `postToPid`, and whether it exposes a focused element at all without an
  assistive client switching its accessibility tree on.
- Whether VS Code's auto-closing and suggestion-accepting characters rewrite typed text.
- Which TCC service posting actually needs, and whether the grant survives a rebuild.
- Whether an `osascript` notification from a LaunchAgent is shown.

Task 1 measures them and writes F11 **before** any production code, the way F6 and F8a were measured
before the hold trigger existed. The numbers the later tasks need are left open and filled in from
F11: chunk size, inter-chunk delay, AX messaging timeout, the sound mechanism and the notification
mechanism.

**One consequence of D21 had to be decided rather than measured.** The default hold keys are right
Control and right Command (`HoldTrigger.swift:144`), and the trigger sends `start` on key-down,
before it knows whether the hold will outlast the 300 ms floor (`HoldTrigger.swift:296-310`).

- **Why that is safe today.** It is safe only because D22 keeps the key silent outside agterm. The
  code's own comment names the reason: otherwise it would fire on "every `⌘V` and every `⌘W`".
- **What would go wrong with the option on and nothing else changed.** Every right-hand ⌘ shortcut
  in every app would:
  - open the microphone;
  - read AX under the handler lock;
  - leave an `aborted` line in the record;
  - when untrusted or in a password field, post a refusal notification.
- **Decision, confirmed by the user on 2026-09-13 with F11's durations in hand.** On the
  focused-field path, **nothing is sent until the hold has outlasted the floor.**
  - Refusals are also decided only then.
  - A combination **released before the floor** therefore costs nothing at all: no AX call, no
    microphone, no record line, no sound, no notification.
  - **A combination held past the floor still starts an attempt.** A source that sees only modifier
    state cannot tell the two apart. F11 measured the right-hand shortcuts ⌘C/⌘V/⌘Z/⌘S at 138–162 ms,
    all cleared by the floor, and ⌘Tab with a window being chosen at 490–675 ms, never cleared.
  - **An attempt whose hold switched the application is cancelled silently** (the user's decision,
    2026-09-13). ⌘Tab activates the chosen application when ⌘ is released, so the check comes at
    `up`: if the frontmost pid differs from the one captured at `down`, whether it changed during the
    hold or within a short settle window after the release, the attempt ends in `abort` — no text, no
    sound, no notification, like D21's floor — rather than `stop`. ⚠️ The settle window is not
    measured: F11 did not time the activation notification after a ⌘Tab release. Task 7 measures it
    on hardware before fixing the constant, and the window is added to `stop` on the field path only.
  - **The price outside agterm.** `Pop` arrives later by the floor, on top of the AX read, the
    socket round trip, capture start and feedback latency that every start already pays. Speech is
    not lost, because D13 already makes the user wait for `Pop`.
  - The agterm path keeps its key-down start. D21, which says the floor "is **not** a delay before
    recording begins", is amended to name the one path where it is.

## Context (from discovery)

- **Files involved (existing):**
  - `SPEC.md`: D4, D5, D13, D21, D22, D28, D30, §1, §2, §5, §6, §7, §8 (invariants 1, 3, 13, new
    14), §9 and §13 are amended.
  - `AGENTS.md`, `README.md`, `docs/manual-checklist.md`.
  - `Sources/DictaCore/Wire.swift`:
    - `Target` (line 235) and `Request` (line 250);
    - the header comment at lines 4–5 that prefers flat structs to enums with associated values.
  - `Sources/DictaCore/Record.swift` (`target`, line 109).
  - `Sources/DictaCore/SessionNames.swift`, `StatusSnapshot.swift`, `Presentation.swift`.
    - `Readiness.terminalMissing` blocks dictation (`StatusSnapshot.swift:36-40`);
    - `Presentation.swift:67,105` renders it as a fault.
  - `Sources/DictaMenu/StatusViewModel.swift` (it reads `target.sessionID` at lines 225 and 246).
  - `Sources/DictaRuntime/Daemon.swift`:
    - `TargetResolver` (line 23) and `Terminal` (line 72);
    - `init` calls `provider(nil)` (line 290);
    - `begin` (lines 488–534);
    - `deliver` (lines 946–995);
    - the untargeted `notifier` is `terminal.notifier` (line 1259);
    - `ParkedAttempt.decode`'s legacy bare-`Target` fallback (lines 1420–1427).
  - `Sources/DictaRuntime/HoldTrigger.swift`:
    - `FrontmostApplication` (line 39);
    - `SystemFrontmost`, whose observer stores only the bundle id (lines 80–88);
    - the default keys (line 144);
    - the sender (lines 296–340).
  - `Sources/DictaRuntime/Agterm.swift`. Every method that takes a `Target`:
    - `resolveTarget`/`resolveFocusedTarget`;
    - `validate` (218);
    - `inject` (328);
    - `notify` with its `osascript` fallback (370);
    - `clearIndicator` (384);
    - `statusArguments` (404), which carries the sounds at 394–402.
  - `Sources/DictaRuntime/Seams.swift` (`Injector`, `Notifier`, `DeliveryFailure`; `SystemClock.schedule`
    starts a thread per item, lines 228–243, which is why pacing gets its own seam).
  - `Sources/DictaCore/PushToTalk.swift` (`HoldWatch`, `HoldToTalk`, the floor).
  - `Sources/DictaCore/Replacements.swift` (rules can expand text, lines 190–214).
  - `Sources/Dicta/main.swift`:
    - top-level flag parsing (lines 43–95), which is not testable today;
    - the `agtermctl` guard (137);
    - top-level wiring (159–224), including `terminal = true` (209) and the trigger's notifier being
      `Agterm` (224).
  - `Scripts/install.sh`, `Scripts/launchagent.plist` (`ProgramArguments` is a `<string>` array,
    lines 24–27), `Scripts/linkage.sh`.
  - Tests:
    - `ChecklistTests.swift`: `everyCitationResolves` (190), `theInvariantsAreStillTen` checks
      `1...13` (201);
    - `TranscriberTests.swift` (`daemonCeilingsFitTheClientTimeout`, 351–375);
    - `BundleTests.swift`;
    - `Fakes.swift`;
    - the 13 test files that construct `Target(sessionID:pane:)` about 65 times: `AgtermTests`,
      `DaemonTests`, `DictationRowTests`, `ControlSocketTests` and others.
- **Files involved (new):**
  - `Sources/DictaCore/KeystrokeChunks.swift`
  - `Sources/DictaCore/FieldEligibility.swift`
  - `Sources/DictaCore/HoldRoute.swift`
  - `Sources/DictaCore/DaemonOptions.swift`
  - `Sources/DictaRuntime/FocusedField.swift`
  - `Sources/DictaRuntime/SystemFeedback.swift`
  - `Sources/DictaRuntime/FocusedFieldWiring.swift`
  - Tests: `KeystrokeChunksTests.swift`, `HoldRouteTests.swift`, `FocusedFieldTests.swift`,
    `SystemFeedbackTests.swift`, `DaemonOptionsTests.swift`
- **Related patterns:**
  - A decision is a pure value in `DictaCore`, its I/O in `DictaRuntime`, and its test in
    `DictaTestRunner` (D19).
  - Every call that touches the world goes through a seam with a fake, as `CommandRunner`,
    `ModifierSource` and `FrontmostApplication` already do.
  - `ChecklistTests` parses SPEC.md §7 and §8 against `docs/manual-checklist.md`. It matches row
    text and invariant titles **verbatim**. It requires every backticked `` `test: …` `` citation to
    name an existing test, whatever surrounds it. It requires H numbers to be contiguous. So a
    checklist line may only cite tests that already exist; until then it cites an H item written in
    the same commit.
- **Dependencies:** no new package. The daemon already links AppKit and CoreGraphics;
  `ApplicationServices` and `Carbon.HIToolbox` link without a linker setting.
- **Conventions:**
  - **English only in the repository, with no exceptions.** `lint.sh` fails on Cyrillic, so every
    Russian fixture (the probe's text, the chunker's tests) is written with `\u{…}` escapes.
  - `bash Scripts/test.sh` is the only gate (D18).
  - `AGENTS.md` is canonical.

## Development Approach

- **testing approach: TDD.**
  - For every pure decision (chunking, routing, the options parser, target coding, re-validation
    outcomes), write the red test first.
  - For system adapters that only a person can score, the test covers the half driven by fakes, and
    the rest is an H item.
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional - they are a required part of the checklist
  - write unit tests for new functions/methods
  - write unit tests for modified functions/methods
  - add new test cases for new code paths
  - update existing test cases if behavior changes
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- run tests after each change: `bash Scripts/test.sh`
- **checklist citations follow the code.** A task that creates a test named by an audit line adds
  the `` `test: …` `` citation to that line in the same task, next to the H item that stood in for
  it.
- **backward compatibility, stated precisely:**
  - Every existing `record.jsonl` line and `active-target` file still decodes.
  - Every agterm behaviour is unchanged whether `--focused-fields` is absent or present.
  - Compatibility is **one-way.** An older daemon skips field lines it cannot decode (`compactMap
    { try? … }`), so after a rollback `firstUnusedID` can reuse a field attempt's id. This is accepted
    and written in AGENTS.md.

## Testing Strategy

- **unit tests**: required for every task, run through `DictaTestRunner` with `bash Scripts/test.sh`,
  never `swift test` (D18).
- **no UI e2e suite exists.** Anything only a person can score is an H item in
  `docs/manual-checklist.md`, written in Task 2 so that the audits can cite it from the start.
- **linked-binary properties** (which process may post events or touch AX) are enforced by
  `Scripts/linkage.sh` rather than an assertion, like invariants 8 and 11 (Task 11).

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview

**Routing at the press.** D22's prohibition becomes a table. The pure decision is `HoldRoute` in
`DictaCore`, and the facts it is fed are captured at the key-down edge in the poll loop: bundle id,
pid and name, all from the one observer-backed `FrontmostApplication`.

| frontmost at the press | `--focused-fields` off | on |
|---|---|---|
| agterm | agterm path, start on key-down (unchanged) | agterm path, start on key-down (unchanged) |
| any other app | silent no-op (unchanged) | **focused-field path, evaluated only once the hold outlasts the floor** |

**The floor as an event, not a sleep.**
- **Where the threshold comes from.** The sender processes edges serially and can be seconds behind
  (`HoldTrigger.swift:207-211, 274-282`). Sleeping in `begin` until the floor could not see an `up`
  already queued behind it, and measuring the hold at execution time would turn a short, queued
  shortcut into a long hold. The **poll loop** therefore emits the threshold: while the owning key is
  still down and its **sampled** hold reaches the floor, `HoldWatch` produces a third edge,
  `.threshold`.
- **Bound to its hold.** Every edge carries the hold's **generation**: the owner key plus a
  monotonic counter bumped on each owning `down`.
- **Queue order is history, not liveness.** A long hold released while the sender was blocked sits
  in the queue as `[down(g), threshold(g), up(g)]`. When the sender reaches `threshold(g)` it has not
  yet seen `up(g)`, so a check against its own pending hold would pass, and would start a dictation
  for a key that is no longer down. Liveness therefore comes from **`HoldLiveness`**:
  - a small synchronised snapshot `{owner key, generation, isHeld}`;
  - written by the **poll loop** at every owning `down` and `up`, independently of the queue;
  - read by the sender under its lock, which is never held across the grant check, AX or the socket.
- **What the sender does with each edge on the field path:**
  - `down`: records a pending hold and does nothing else;
  - `threshold(g)`: starts **only if `HoldLiveness` says generation g is still held right now**, and
    otherwise drops it;
  - `up`: stops the attempt if a start was committed for that generation, and otherwise discards the
    pending hold.
- **The two races at the threshold, spelled out:**
  - the poller records the release **before** the sender's liveness check: the threshold is dropped
    and nothing starts;
  - the release lands **after** the check, while `start` is being sent or has been accepted: the
    queued `up(g)` stops that attempt as an ordinary release, and D21's floor has already been
    passed, so it is a stop, not an abort.
- **The floor applies once.** `HoldToTalk`'s floor is not re-applied to an attempt started at the
  threshold, because it has already been passed by sampled time. The second-armed-key rule (whichever
  key went down first owns the gesture) holds for `threshold` exactly as for `up`.

**What happens on the focused-field path at a live `threshold`.** The sender thread, never the poll
loop, does the following in order:
1. Checks the grant, and refuses with a notification if it is missing.
2. Checks whether the frontmost pid is still the one captured at `down`. If not, it is a silent
   no-op, because the user switched away.
3. Sends `Request(cmd: .start, field: FieldTarget)`.

The daemon then refuses **before capture** if:
- Secure Input is enabled by **any** process. `IsSecureEventInputEnabled` is system-wide, so this is
  not a password-field detector, and nothing here promises that every password field is rejected;
- the focused element cannot be read;
- the element's pid is not the request's pid;
- the element is not **eligible** (below).

A release before the floor sends nothing at all on this path.

**Eligibility: a focused element is not necessarily a text field.** Plain characters posted to a
focused button, list or document body can act as commands or type-to-select, and SPEC §1 excludes
voice control. So admission needs a **content-free** eligibility policy, `FieldEligibility` in
DictaCore, which classifies AX metadata only:
- **inputs:** role, subrole, whether `kAXValueAttribute` is settable, whether
  `kAXSelectedTextRangeAttribute` exists;
- **never read:** the value, the selected text, the range's contents;
- **answers:** `.eligible`, `.ineligible` or `.unknown`;
- **what the daemon does:** `.ineligible` and `.unknown` are both refused before capture.

**The rule, from F11's table** (no stop point was hit: every positive field classified, every
negative was told apart):
- `.eligible`: role `AXTextArea` or `AXTextField`, **and** `kAXValueAttribute` settable, **and**
  subrole not `AXSecureTextField`;
- `.ineligible`: any other role, or a settable value missing, or the secure subrole. This covers
  F11's `AXGroup` tree and `AXWebArea` page, and the password field by subrole without reading it;
- `.unknown`: role or settability could not be read.
- **`kAXSelectedTextRangeAttribute` is dropped from the inputs.** F11 found Chromium puts it on a
  tree, so it discriminates nothing.
- **Other text roles** (`AXComboBox`, `AXSearchField`) were not measured and stay `.ineligible` until
  an H item shows them.

- **dicta's own menu bundle needs no row.** F11 measured that opening the DictaMenu panel does not
  make DictaMenu frontmost: the application under it stays frontmost. So D30's "silent ground" holds
  by construction for the panel, and a hold with the panel open over VS Code goes to VS Code exactly
  as one over agterm goes to agterm. D30 is amended in words, not given a routing row. Other
  applications, acta included, get no exemption either way.
- **Chords stay agterm-only.** They fire through agterm's keymap. Outside agterm, the hold key is the
  whole interface and `raw` is unreachable, which is accepted for v1 and stated in D31.
- **Electron's accessibility tree.** F11: VS Code and Slack expose no focused element (`noValue`)
  until `AXManualAccessibility` is set on the application, and a real one after. Safari and Telegram
  need nothing.
  - **Decided by the user on 2026-09-13:** when the application element answers `noValue` at start,
    dicta sets `AXManualAccessibility` on that application once, re-reads once, and refuses as
    `.unknown` if the element is still absent.
  - The attribute stays set for the life of that application process. That is a side effect on
    another application, which D31 states.
  - F11 saw no visible change in VS Code in a short check. Its performance cost, and how long
    Electron takes to build the tree after the attribute is set, were **not** measured; Task 5 times
    the second, and an H item covers the first.
- **The focused element is read through the application element, never the system-wide one.** F11:
  the system-wide `kAXFocusedUIElement` read failed with `cannotComplete` in every application and at
  every timeout, while `AXUIElementCreateApplication(pid)` for the observer's frontmost pid answered
  in 0.3–44 ms.

**Target identity.** `.focusedField` carries the bundle identifier, the application name and the pid
on the wire and in the record.
- **The `AXUIElement` never leaves the daemon.** It is parked beside the attempt in `DictaRuntime`,
  so `DictaCore` stays free of ApplicationServices.
- **Accuracy.** It is focus read shortly after the floor, which is looser than §5's pane, and §5
  states it.
- **D4 and invariant 3 are amended rather than over-claimed.** `postToPid` pins the **process**, not
  the element. Focus can move inside the app between the last check and the moment the app processes
  an event, even for a single chunk. The guarantee for a field target is therefore: never another
  application, never a field that failed re-validation, and **no detection of a move inside the
  same application during delivery**. SPEC says exactly that, and the audit wording follows.
- **The AX timeout.** A hung application can block an AX call for seconds. The daemon makes no other
  AX calls, so the timeout is set **once, process-globally, on the system-wide object** at wiring
  time. The system-wide object is used for nothing else, since its focused-element read does not
  work (F11). The value is 0.25 s: F11's slowest successful read was 44 ms, and no hung application
  was measured. The header (`AXUIElement.h:387-402`) says a per-element timeout does not carry
  over to `CFEqual` instances, so no element-level timeout is relied on, including any element
  `AXManualAccessibility` touches.
- **Serialised calls for the non-thread-safe API.** `IsSecureEventInputEnabled` is documented as "Not
  thread safe" (`CarbonEventsCore.h:3044-3064`). All `SystemFocusedFieldAccess` calls are serialised
  by one private lock inside the adapter. They are never made on the poll thread and never hop to the
  main run loop, which the workspace observer needs and a hop could deadlock. F11 checks that the
  call answers from a background thread the same way it does on main.
- **The daemon reads identity, never content.** It never reads an element's value or selected text
  (invariant 14).

**Delivery** is `FocusedFieldInjector`, behind the existing `Injector` seam, reached through
`Daemon.deliver`, so the sanitiser still runs last (invariant 1). The VS Code terminal submits on
Return exactly as agterm does.
1. **Plan and bound first**, before the last validation, so that nothing slow sits between that
   validation and the first event. `final` is split with `KeystrokeChunks`: a soft packing target of
   N UTF-16 units per chunk, never splitting a grapheme.
   - **Why the bound is needed.** `final` is not bounded upstream: recognised text is capped
     (`Daemon.swift:833`), but the dictionary can expand it (`Replacements.swift:190-214`), the
     filter can return anything, and `final` is parked with no cap (`Daemon.swift:917-931`).
   - **Two hard limits, enforced by the planner itself:**
     - `maxChunks` bounds the event count;
     - `maxEventUTF16` bounds every single event's payload. Grapheme preservation allows a chunk
       over the soft target, but one grapheme over the hard limit is **rejected**, never split: "a"
       followed by 100 000 U+0301 is one `Character` of 100 001 UTF-16 units.
   - **The planner's own work is bounded.**
     - The early length check counts **at most limit + 1** UTF-16 units and never takes a full
       `utf16.count`, which would scan all of an oversized input.
     - The limit `maxChunks × maxEventUTF16` is built with overflow-checked multiplication from
       validated positive constants.
     - The planner then stops at the first bound exceeded rather than building or counting a plan it
       will reject.
   - **A rejected plan** fails as `notStarted` before any event is posted. `final` stays in the record
     for recovery.
2. **Final validation**, immediately before the first event, with nothing expensive after it:
   - the monotonic delivery deadline has not passed. If it has, the result is `notStarted`, because
     nothing was posted yet;
   - the same pid is still frontmost;
   - the focused element is `CFEqual` to the parked handle;
   - **eligibility re-run on fresh `FieldFacts`**, because the same element can stop being editable
     while the user was speaking;
   - Secure Input is off, and the grant is still present;
   - **then, after every potentially blocking AX call has returned,** the cheap checks again: the
     deadline, where a pass is `notStarted`, and the frontmost pid, where a change is `targetGone`.
     An AX read can succeed after the deadline has passed or after the foreground app has changed,
     so the first post comes only after these.

   How a failed check is classified:
   - `targetGone` only when AX answered definitely: a different element or a different frontmost
     pid;
   - `notStarted` for an AX timeout or error, lost grant, Secure Input, or ineligible or unknown
     facts. AGENTS.md's rule that only a definite absence is called gone applies here too.
3. **Post** each chunk as a key-down and a key-up that carry the Unicode string:
   - with explicit empty flags, so a modifier still held cannot combine with them;
   - from a `.privateState` event source;
   - through `postToPid` to the captured pid.

   ⚠️ If F11 shows VS Code needs the HID tap instead, **stop and return to the design**. The HID tap
   delivers to whatever is frontmost when the event is processed, so a per-chunk check narrows D4's
   substitution race without closing it.
4. **Before every chunk after the first,** re-check the frontmost pid and the deadline.
   - Either failing aborts as `mayBePartial`, never retried. D20 refuses an abort, so the deadline is
     the only thing that can stop a delivery that runs long.
   - **A move inside the same app** (editor → terminal) mid-delivery is not detected, and neither is
     the OS dispatch race inside one application. Both are stated in §7 rather than hidden.
   - **Pacing** between chunks goes through a small synchronous `Pacer` seam: `Thread.sleep` in
     production, a recorder in tests. It is **not** `Clock.schedule`, which starts a real thread per
     item (`Seams.swift:228-243`).

**The pasteboard is never touched.** It stays the recovery channel D28 gives the user.

**Feedback without agterm.** A field target has no session indicator, so D13's feedback for it is
sounds and notifications.
- `SystemFeedback` plays `Pop`, `Tink` and `Basso`, and notifies through whichever mechanism F11
  chooses. The daemon still has no `NSApplication` (F8a).
- `SystemFeedback` also becomes the notifier for **untargeted** refusals and for the hold trigger
  whenever agterm is absent.
- The menu-bar strip works unchanged (D27) and stays optional. It and the record name the application
  instead of a session.

**agterm optional.**
- **`--focused-fields` on and `agtermctl` missing.** Start-up logs the fact and carries on:
  - a session chord, or the hold key in front of agterm, is refused with that reason;
  - `Readiness.terminalMissing` stops blocking dictation;
  - the menu presents it as a notice, not a fault.
- **`--focused-fields` off.** A missing `agtermctl` stays **fatal**, as today, because nothing could
  be delivered.

## Technical Details

**`Target` (DictaCore, Wire.swift)**

```swift
public enum Target: Codable, Sendable, Equatable {
    case agterm(AgtermTarget)          // today's struct, renamed; fields unchanged
    case focusedField(FieldTarget)
    public init(sessionID: String, pane: Pane)   // builds .agterm, keeps ~65 test call sites compiling
}
public struct AgtermTarget: Codable, Sendable, Equatable { public var sessionID: String; public var pane: Pane }
public struct FieldTarget: Codable, Sendable, Equatable {
    public var bundleID: String?   // an app may have none
    public var appName: String
    public var pid: Int32
}
```

- **Custom `Codable`.**
  - `.agterm` encodes to exactly today's flat object `{"pane": …, "sessionID": …}` (the record uses
    `.sortedKeys`), so old lines decode and new agterm lines are byte-identical.
  - `.focusedField` encodes as `{"field": {"appName": …, "bundleID": …, "pid": …}}`.
  - Decoding keys on the presence of `field`. An object carrying neither shape is a decode error,
    never a guess.
- **Wire.swift's header comment** (flat structs rather than enums with associated values) is
  updated to explain the exception: backward-compatible JSON, with type-level exclusion of a field
  target from the agterm adapter.
- **`Agterm` takes `AgtermTarget` internally.** Its `Injector`/`Notifier` conformances receiving a
  `.focusedField` throw `notStarted` or do nothing, never a guess. In practice the daemon never
  routes one there, and a test asserts both.
- **`ParkedAttempt.decode`'s legacy bare-`Target` fallback** keeps decoding into `.agterm`.

**`Request` (Wire.swift)**
- Gains `field: FieldTarget?`, the same type rather than a duplicate.
- `Request.conflict` in DictaCore is a pure check: `field` together with `focus` or `sessionID` is
  refused, and the daemon applies it in `begin`.

**`KeystrokeChunks` (DictaCore)**
- `static func plan(_ text: String, targetUTF16: Int, maxEventUTF16: Int, maxChunks: Int) ->
  DeliveryPlan`.
- `DeliveryPlan` is `.chunks([String])`, `.tooManyChunks` or `.graphemeTooLong`. A rejection carries
  no count, because the planner stops at the bound rather than counting the rest.
- Splits on `Character` boundaries and packs greedily up to `targetUTF16`. A single grapheme longer
  than `targetUTF16` becomes its own chunk if it fits `maxEventUTF16`, and is `.graphemeTooLong` if
  it does not.
- The bound is checked on the **packed** result, because grapheme packing leaves slack and "length /
  targetUTF16" is not a chunk count.
- It stops at the first exceeded bound. Text longer than `maxChunks × maxEventUTF16` UTF-16 units is
  rejected before iterating graphemes, by counting at most limit + 1 units; the limit is built with
  overflow-checked multiplication.
- `targetUTF16 < 1` is clamped to 1, and asserted; `maxEventUTF16 >= targetUTF16`.
- The defaults come from F11.

**`FieldEligibility` (DictaCore)**
- `static func classify(_ facts: FieldFacts) -> Eligibility`.
- `FieldFacts` holds role, subrole, `valueSettable: Bool?` and `hasSelectedTextRange: Bool?`. `nil`
  means AX did not answer.
- The rules are F11's table.
- `.unknown` is its own answer and is refused, never promoted to `.eligible`.

**`HoldRoute` (DictaCore)**
- `static func decide(frontmost: FrontmostFacts, agtermBundleID: String, ownBundleIDs: Set<String>,
  focusedFieldsEnabled: Bool) -> HoldRoute`.
- Cases: `.agterm`, `.ignore`, `.focusedFieldAfterFloor(FieldTarget)`.
- The grant, Secure Input and element checks are not in it: they need AX and happen later.

**`HoldWatch` / `HoldToTalk` (DictaCore)**
- `HoldWatch` gains a `.threshold` edge and a `generation`, both computed from **sampled** times in
  the poll loop.
- It is emitted only while the field route is pending for the owner key. The agterm route's
  behaviour is byte-for-byte unchanged, and its existing tests stay as they are.

**Seams (DictaRuntime, FocusedField.swift)**
- `protocol FocusedFieldAccess: Sendable` with `isTrusted`, `isSecureInputOn`,
  `focusedElement(expectedPID:) throws -> FieldHandle` and `isSame(_:as:)`.
  - **No `frontmostPID`.** The frontmost fact comes only from the shared observer-backed
    `FrontmostApplication`. A second, unobserved source would bring back F8a's frozen value.
- `focusedElement(expectedPID:)` also returns the `FieldFacts` for eligibility, which are metadata
  only.
- `protocol EventPoster: Sendable` with `post(unicode: String, toPID: Int32)`.
- `protocol Pacer: Sendable` with `pause(_ seconds: TimeInterval)`, synchronous. Production uses
  `Thread.sleep`; tests use a recorder, and the recorder also advances the fake monotonic deadline.
- `FieldHandle` is opaque, so fakes use a token.
- `SystemFrontmost`'s notification closure stores bundle id, pid and localized name together. It is
  **one instance**, shared by the trigger and the injector, and it is constructed whenever
  `--focused-fields` is on, **even under `--no-hold`**, so the observer exists.

**Composition (DictaRuntime, FocusedFieldWiring.swift)**
- `FocusedFieldWiring.make(options: DaemonOptions, frontmost:) -> FieldTrio?` returns `nil` when the
  option is off, and then **constructs no system adapter**.
- `main.swift` calls it. `DaemonOptions` (DictaCore) replaces top-level flag parsing, so both are
  testable.

**Daemon wiring**
- `TerminalProvider` becomes `@Sendable (String?) -> Terminal?`, and `init` tolerates `nil`.
- `begin` branches on `request.field` versus `sessionID`/`focus`.
- **Field handle ownership is bound to the accepted attempt.** Today `begin` resolves a target
  **before** the state machine refuses a busy start (`Daemon.swift:508-533`), and `adoptTerminal`
  already guards the live attempt against being rebound (`Daemon.swift:1268-1277`). The field path
  needs the same protection:
  - `begin` resolves the handle into a **local**, with all AX work done before any lock is taken;
  - **insertion happens inside the same `stateLock` acquisition that accepts the start.** `apply`
    runs `machine.apply` under `stateLock`, then releases it before `sync` and the effects
    (`Daemon.swift:618-652`). Inserting after `apply` returns would allow accept → unlock → an abort
    or fault runs its cleanup → relock → insert, which resurrects the handle of an attempt that has
    already ended. So `apply` is refactored to take an optional `onAcceptedStartLocked` step, and the
    handle is stored there as `fieldHandles[attemptID]`, before another transition can see the
    accepted state and before any `beginCapture` effect;
  - a refused start drops its local handle and touches nothing stored;
  - release is **by id** and only for that id, so a late teardown of attempt N cannot remove N+1's
    handle.

  This matters because `apply`/`sync` run on capture and watchdog threads as well
  (`Daemon.swift:588-633`).
- The untargeted `notifier` is the agterm notifier when present and `SystemFeedback` otherwise.
- `activeTargetFile` stores the new encoding. The §7 stale-indicator cleanup applies to `.agterm`
  only.

**Ceilings.** Delivery runs inline under the handler lock, so `daemonCeilingsFitTheClientTimeout`
(`TranscriberTests.swift:351-375`) gains a **delivery ceiling**, derived from the enforced bounds
rather than the frame limit:

`maxChunks × (pacing delay + per-chunk frontmost check) + (count of AX calls on the delivery path × AX
timeout) + feedback calls × their ceiling`

- The AX calls are counted as the code makes them (re-validation: element read, `CFEqual`, trust,
  Secure Input), not as a fixed multiple.
- The monotonic delivery deadline is set **below** that ceiling, so the injector stops itself as
  `mayBePartial` before the client's `pipelineRead` could expire.

**D29.** A waiting `dictate` claim still wins over any target. The focused-field path changes nothing
about `returned`.

**SPEC text Task 2 writes (verbatim rows get audit lines in the same task):**

- **Invariant 13** is reworded to: "The hold trigger never starts an attempt while another
  application is frontmost, unless `--focused-fields` routes the hold to that application's focused
  field (D31)". The §7 row "hold key pressed while agterm is not frontmost" is reworded to say "with
  `--focused-fields` off".
- **New invariant 14:** "Keystrokes are posted into another application only when `--focused-fields`
  is on, only into a focused-field target that re-validated immediately before delivery, never by
  `dictactl` or the menu-bar UI; and the daemon never reads a field's value or selected text".
- **D4 and invariant 3** gain the focused-field limitation: never another application, never an
  unvalidated field, and a move inside the same application during delivery is not detected.
- **D21** names the one path where the floor delays the start.
- **§2 Target** and **§9's target schema** describe both shapes.
- **New §7 rows:**
  - a hold on the focused-field path released before the floor (nothing sent: no AX call, no
    microphone, no record line, no sound);
  - the hold outlasts the floor with the option on but no grant;
  - the hold outlasts the floor while Secure Input is enabled by any process;
  - the focused element cannot be read at start;
  - the focused element is not eligible, or its eligibility is unknown (refused before capture);
  - `final` exceeds the delivery bound (`notStarted`, text in the record);
  - the delivery deadline passes mid-delivery (`mayBePartial`, never retried);
  - the focused field is gone before delivery (`targetGone`);
  - AX cannot answer at re-validation (`notStarted`);
  - focus moves to another app mid-delivery (`mayBePartial`, never retried);
  - focus moves inside the same app mid-delivery (not detected, and stated);
  - the receiving app silently drops or rewrites posted events. This is silent by construction:
    `CGEventPost` has no error channel, and an AX read-back is not in v1;
  - a chord or the hold key in front of agterm while `agtermctl` is absent and the option is on
    (refused with the reason).
- **D30/H19:** the panel stays silent ground under the option because it never becomes frontmost
  (F11), not because of a routing rule.
- **New §7 row:** a hold on the focused-field path whose release switched the application (⌘Tab):
  silently aborted, with no text, no sound and no notification.

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): the probe and F11, the spec and checklist, code,
  tests, scripts and docs in this repository.
- **Post-Completion** (no checkboxes): scoring on real applications, the interested user's machine,
  and a machine without agterm.

## Implementation Steps

### Task 1: Probe — measure focused-field delivery before designing against it (F11)

**Files:**
- Create (temporary, deleted at the end of this task): `Sources/FieldProbe/main.swift` and its target
  in `Package.swift`
- Modify: `SPEC.md` (§4: F11)

- [x] build a throwaway `FieldProbe` executable. Sign it into a bundle with the scheme
  `Scripts/bundle.sh` uses, and run it **as a LaunchAgent with the installed daemon's identity
  scheme and run-loop shape**: a background thread for the work and a main run loop with the
  workspace observer. An interactively launched probe, or `Scripts/run.sh`, would measure a
  different identity and launch mode.
  - It posts a fixed ~2000-character line into the focused field after a countdown.
  - The line mixes escaped Cyrillic, Latin, emoji, `.`, `()`, quotes and brackets.
- [x] measure delivery in the VS Code editor, the VS Code integrated terminal, Safari (textarea),
  Slack and Telegram:
  - characters lost or rewritten, comparing delivered bytes with the source. This catches
    auto-closing pairs and suggestion-accepting commit characters, and covers Apple's warning that a
    framework may ignore the Unicode string and translate the keycode instead;
  - chunk sizes 1, 20 and 40 against inter-chunk delays of 0, 2 and 5 ms, with total time;
  - `postToPid` against the HID tap;
  - a keycode-0 event with the Russian layout active;
  - delivery while **physically held right Command, right Control and Shift** are down;
  - frontmost pid against `AXUIElementGetPid` of the focused element, especially in Electron's helper
    processes.
- [x] measure AX identity and eligibility:
  - in VS Code, with and without `AXManualAccessibility` set, whether `kAXFocusedUIElement` answers,
    and whether it tells the editor from the terminal (`CFEqual` stable across 5 s, and different
    after focus moves);
  - the side effects of setting that attribute (screen-reader mode, visible slowness);
  - read latency under a process-global `AXUIElementSetMessagingTimeout`;
  - the role, subrole, `kAXValueAttribute` settability and `kAXSelectedTextRangeAttribute` presence
    for every **positive** field above;
  - the same for **negatives** in each app: a focused button, list, sidebar tree and document body.
    These facts become `FieldEligibility`'s table.
- [x] measure TCC under the LaunchAgent identity:
  - `AXIsProcessTrusted` and `CGPreflightPostEventAccess` separately, and whether each predicts
    **actual** posting and **actual** AX reads (never inferring one from the other, and never
    substituting Input Monitoring);
  - which call prompts or lists `Dicta.app`;
  - whether a grant takes effect without a restart;
  - whether it survives a rebuild and re-sign;
  - what revocation does to a running process.
- [x] measure feedback and edges:
  - whether `NSSound(named:)` plays without `NSApplication`, or `afplay` is needed;
  - which notification mechanism is actually shown from the LaunchAgent;
  - `IsSecureEventInputEnabled` from a background thread against main;
  - global Secure Input left enabled by another process, separately from a focused password field;
  - whether opening the DictaMenu panel makes it frontmost;
  - how long right-hand `⌘Tab` and other held combinations actually last, against the floor.
- [x] write F11 into SPEC.md §4 with dates, apps and numbers, then delete the probe:
  - the chosen chunk size, delay, `maxChunks`, messaging timeout, sound mechanism, notification
    mechanism and TCC predicate;
  - the eligibility table, and the `AXManualAccessibility` finding;
  - the probe's commit hash, recorded before deleting it, the way `3dda6cb` is cited;
  - then delete `FieldProbe` and its target. No code survives, so no test is added; the gate is
    `bash Scripts/test.sh` and `bash Scripts/lint.sh` staying green.
- [x] ⚠️ **stop points.** Report to the user and return to design if any of these holds:
  - Unicode posting is unusable in VS Code;
  - VS Code needs the HID tap;
  - VS Code's editor or terminal classify as `.unknown` or `.ineligible` even with
    `AXManualAccessibility`;
  - no notification mechanism is shown from a LaunchAgent;
  - posting works without the predicate the design would check, or the reverse.
- [x] ⚠️ ask the user to confirm the floor-deferred start now, with F11's held-combination durations
  in hand, before Task 2 writes it.

- ➕ **Outcome (2026-09-13).** F11 is in SPEC.md §4; the probe was commit `c3b9aba`, and it was
  deleted in the commit that wrote F11.
  - **No stop point hit.**
  - **Values fixed:**
    - predicate `AXIsProcessTrusted` only, prompting with `AXIsProcessTrustedWithOptions`;
    - `postToPid`; the HID tap was not needed and not measured with the grant;
    - `targetUTF16` 20, measured in all six applications with no gap and no loss;
    - `maxEventUTF16` 200, accepted whole by VS Code only (⚠️ an H item confirms Safari, Slack,
      Telegram and the terminal at 200 before the hard limit may be relied on);
    - no inter-chunk delay needed for correctness;
    - AX messaging timeout 0.25 s;
    - sounds through `NSSound`;
    - notifications through `osascript`, suppressed by Focus modes.
  - **Not measured:**
    - a process leaving Secure Input stuck;
    - chunk sizes 1 and 40 outside TextEdit, and the 2 ms delay;
    - the duration of VS Code's JavaScript-mode stall;
    - `AXManualAccessibility`'s performance cost;
    - the ⌘Tab activation lag.

### Task 2: The decisions and their audits, in the spec and the checklist, before any code

**Files:**
- Modify: `SPEC.md`
- Modify: `docs/manual-checklist.md`
- Modify: `Sources/DictaTestRunner/ChecklistTests.swift`

- [x] write the red test first: `theInvariantsAreStillTen` becomes `theInvariantsAreStillFourteen`,
  with its name updated and `Array(1...14)`. Watch it fail.
- [x] add D31 (the focused field as a second target kind), covering:
  - opt-in;
  - the routing table (no row for dicta's own bundles: F11 shows the panel never becomes frontmost);
  - the silent cancel when the hold switched the application;
  - the threshold-edge start and its reason, as confirmed by the user;
  - `FieldEligibility` and its refusal of `.unknown`;
  - chords agterm-only and `raw` unreachable outside agterm;
  - dicta setting `AXManualAccessibility` on an application that answers `noValue` (decided by the
    user on 2026-09-13), and its side effect on other applications;
  - F11's feedback limit: under a Focus mode the notification is suppressed and the sound is the only
    signal outside agterm (D13 and the §7 refusal rows say so).
- [x] add D32 (Unicode keystrokes to the pid), covering:
  - why not the pasteboard with ⌘V;
  - why not `kAXSelectedTextAttribute`;
  - why not the HID tap;
  - the delivery bound and deadline.
- [x] amend:
  - D4 and invariant 3 (the focused-field limitation);
  - D5 (the permission promise becomes conditional);
  - D13 (feedback without an indicator);
  - D21 (the one path where the floor delays the start);
  - D22 (the table replaces the prohibition);
  - D28 (the UI never posts events either);
  - D30 (the panel is silent ground);
  - §1;
  - §2 Target, §5 and §9's target schema;
  - §6 (interaction and feedback columns);
  - §13 (remove "any injection target other than agterm", keep "any injection from the UI");
  - invariant 13 and its §7 row, reworded verbatim as in Technical Details.
- [x] add invariant 14 and every new §7 row from Technical Details.
- [x] in `docs/manual-checklist.md`, write the H items now, numbered H24 onwards:
  - the VS Code editor;
  - the VS Code integrated terminal;
  - Slack;
  - Safari;
  - the grant prompt and its revocation;
  - global Secure Input;
  - a focused non-text element being refused;
  - switching apps mid-delivery;
  - a right-hand ⌘ combination released before the floor costing nothing;
  - a machine without agterm.
- [x] add the audit lines for:
  - invariants 3, 13 and 14;
  - every new or reworded §7 row;
  - H19.

  Each cites **only H items or tests that already exist**. Later tasks add their own test citations.
- [x] run tests. The audit and invariant tests must be green before Task 3.

- ➕ **Outcome (2026-09-13).** D31 and D32 are in SPEC.md, with every amendment listed above,
  invariant 14 and fourteen new §7 rows (plus the reworded D22 row). The checklist gained H24–H34.
  - **H items beyond the ten listed:** H34 (the delivery bound), because the bound's §7 row needed
    something to cite before Task 9's test exists; Telegram is folded into H27, and the 200-unit
    event check into H25–H27.
  - **H19 was rewritten, not just cited.** It expected an open panel to silence the hold key, which
    F11 contradicts (the panel never becomes frontmost). D30's reasoning was corrected the same way.
  - **Rows no person can reach:** "the delivery deadline passes mid-delivery" cites H31 (b), the
    other road to `mayBePartial`, and says so; Task 9 adds the real test.
  - **Stated gaps in invariant 14's audit line:** nothing holds "never by `dictactl` or the menu bar"
    until Task 11, and nothing holds "never reads a value" yet.
  - Tests: 583 in 34 suites green under Xcode 26.6; lint clean. The audit was probed by renaming
    a new §7 line and invariant 14 in the checklist: 3 issues, then restored.

### Task 3: `Target` becomes a sum, and old records still decode

**Files:**
- Modify: `Sources/DictaCore/Wire.swift`, `Record.swift`, `SessionNames.swift`, `StatusSnapshot.swift`
- Modify: `Sources/DictaMenu/StatusViewModel.swift`
- Modify: `Sources/DictaRuntime/Agterm.swift`, `Daemon.swift` (`activeTargetFile`, `ParkedAttempt`)
- Modify: `Sources/DictaTestRunner/WireTests.swift`, `RecordTests.swift`, `AgtermTests.swift`,
  `DaemonTests.swift`, `Fakes.swift`, and any test that reads `.sessionID`/`.pane` directly (grep
  the 11 reads)

- [x] write the red tests first:
  - a `record.jsonl` line produced by the current build, checked in as a literal, decodes to
    `.agterm` and re-encodes byte-identical;
  - `.focusedField` round-trips;
  - an object with neither shape fails to decode;
  - an `active-target` file and a legacy bare-`Target` parked attempt still decode.
- [x] introduce `AgtermTarget`, the `Target` enum, the `init(sessionID:pane:)` convenience and the
  custom `Codable`, and update Wire.swift's header comment.
- [x] switch `Agterm`'s internals to `AgtermTarget`. Test that its injector, given a `.focusedField`,
  throws `notStarted` with no subprocess run, and that its notifier does nothing.
- [x] update `SessionNames` and `StatusViewModel` to switch on the case. Add the field caption (the
  app name) as a pure DictaCore function, with a test.
- [x] run tests — must pass before next task

- ➕ **Outcome (2026-09-13).** `Target` is `.agterm(AgtermTarget)` or `.focusedField(FieldTarget)`
  with a hand-written `Codable`; the agterm case keeps the flat object.
  - **The byte-identical literal was checked against the old build first:** the record test passed
    on the agterm-only `Target` before the enum existed, so it is what that build wrote.
  - **Added beyond the list:** `Target.sessionID: String?` (nil for a field), which the menu's name
    lookup and the agterm notifier use instead of a switch at each site; `Agterm.validate` now takes
    `AgtermTarget`.
  - **Deferred as planned:** `clearStaleIndicator` still hands any parked target to the agterm
    notifier, which ignores a field; routing by case is Task 8's.
  - Tests: 592 in 34 suites green under Xcode 26.6 (Swift 6.3.3), nine new; lint clean.

### Task 4: `KeystrokeChunks` and `FieldEligibility` — the pure decisions of delivery

**Files:**
- Create: `Sources/DictaCore/KeystrokeChunks.swift`, `Sources/DictaCore/FieldEligibility.swift`
- Create: `Sources/DictaTestRunner/KeystrokeChunksTests.swift`, `FieldEligibilityTests.swift`

- [x] write the red tests first for `KeystrokeChunks`:
  - empty text gives no chunks;
  - ASCII splits at exactly `targetUTF16`;
  - escaped Cyrillic splits correctly;
  - a surrogate-pair emoji at a boundary is never split;
  - a ZWJ family emoji longer than the limit is its own chunk;
  - a combining accent stays with its base;
  - `targetUTF16 < 1` is clamped to 1;
  - joining the chunks reproduces the input;
  - a text whose **packed** chunk count exceeds `maxChunks` is `.tooManyChunks`, including a case where
    length / `targetUTF16` is under the bound but grapheme packing is over it (`.tooManyChunks`);
  - one grapheme over `maxEventUTF16` ("a" followed by many escaped U+0301) is `.graphemeTooLong`,
    including when it is the only grapheme;
  - text over `maxChunks × maxEventUTF16` is rejected by the bounded pre-count: an internal, testable
    counting helper inspects exactly limit + 1 units on an oversized input, and a text of exactly the
    limit passes the pre-count (a deterministic boundary assertion, not a timing test);
  - constants whose product would overflow are rejected at construction;
  - dictionary-expanded text over the bound is `.tooManyChunks`.
- [x] write the red tests first for `FieldEligibility`: every row of F11's table, both positives and
  negatives, plus all-`nil` facts giving `.unknown`, and a role that is eligible except that the
  value is not settable.
- [x] implement both with F11's defaults and table.
- [x] run tests — must pass before next task

- ➕ **Outcome (2026-09-13).** `KeystrokeChunks` and `FieldEligibility` are in DictaCore with no
  I/O; 27 new tests in two suites.
  - **Shape.** `KeystrokeChunks` is a value with a failable `init(targetUTF16:maxEventUTF16:maxChunks:)`
    and `plan(_:)`, rather than one static function, so that "rejected at construction" is testable:
    `nil` for `maxChunks < 1`, `maxEventUTF16` under the clamped target, or an overflowing limit.
    `KeystrokeChunks.standard` is 20 / 200 / 4 000. The pre-count is the public
    `boundedUTF16Count(_:limit:)`, generic over the unit sequence, because the tests use no
    `@testable` and a counting sequence is the only way to see it draw exactly limit + 1 units.
  - **`maxChunks` = 4 000 is a choice, not an F11 value.** It fits the largest recognised text the
    wire carries (`RecognisedText.maxBytes`, all ASCII: 3 226 chunks), so it only refuses what the
    dictionary or the filter grew. Task 9's delivery ceiling multiplies by it and may lower it.
  - **"Clamped and asserted".** The clamp is not an `assert`, which would trap the debug test run;
    the other constraint (`maxEventUTF16 >= targetUTF16`) is a construction refusal instead.
  - **Eligibility order.** A definite negative wins over a missing fact: the secure subrole, a known
    non-text role or a non-settable value is `.ineligible` whatever else went unread; otherwise a
    missing role or settability is `.unknown`. Both refuse.
  - ⚠️ **`AXSearchField` is a subrole on macOS, not a role.** D31 lists it among unmeasured roles
    that stay ineligible; the rule as written (text role, settable, not secure) admits an
    `AXTextField` whose subrole is `AXSearchField`. The test covers it only as a role. Left as the
    spec's rule states; a human item or a spec amendment should settle which is meant.
  - Mutation check: breaking the packing boundary, the secure-subrole rule and the pre-count bound
    together gave 9 failures. Tests: 619 in 36 suites green under Xcode 26.6 (Swift 6.3.3); lint
    clean (swiftlint not installed, built-in checks only).

### Task 5: Seams, fakes, and a frontmost source that knows the pid

**Files:**
- Create: `Sources/DictaRuntime/FocusedField.swift` (protocols, `FieldHandle`, `Pacer`, system
  adapters)
- Modify: `Sources/DictaRuntime/HoldTrigger.swift` (`FrontmostApplication`, `SystemFrontmost`)
- Modify: `Sources/DictaTestRunner/Fakes.swift`, `HoldTriggerTests.swift`
- Create: `Sources/DictaTestRunner/FocusedFieldTests.swift`

- [x] write the red test first: a scripted `FrontmostApplication` fake reports bundle id, pid and name
  as **one** value from one activation, and the trigger's captured `Pending` carries all three.
- [x] extend `FrontmostApplication`. `SystemFrontmost`'s notification closure stores all three from
  the notification's `NSRunningApplication`, and never re-reads
  `NSWorkspace.shared.frontmostApplication` (F8a).
- [x] define `FocusedFieldAccess`, `EventPoster`, `Pacer` and `FieldHandle`, and add their fakes. The
  fakes are exercised by later tasks rather than tested for their own sake.
- [x] implement the system adapters:
  - `SystemFocusedFieldAccess`:
    - `AXIsProcessTrusted`, never `CGPreflightPostEventAccess`, which F11 found stale in both
      directions within one process;
    - `IsSecureEventInputEnabled`;
    - the focused-element read through `AXUIElementCreateApplication(pid)` returning metadata-only
      `FieldFacts`;
    - `AXUIElementGetPid` against the expected pid, and `CFEqual`;
    - `AXManualAccessibility`, set once per application process on `noValue`, then one re-read.

    Every call is serialised by one private lock and never hops to main. The process-global messaging
    timeout (0.25 s) is set once, in the initializer, on the system-wide object.
  - ⚠️ on hardware: time how long VS Code takes to answer after `AXManualAccessibility` is first set,
    and record it in F11 before the re-read's wait is fixed. (skipped - not automatable: needs VS
    Code on screen; the wait is a provisional constant, see the outcome.)
  - `SystemEventPoster`: a `.privateState` source, key-down and key-up carrying the Unicode string,
    `flags = []` on both, and `postToPid`.
  - `ThreadPacer`.
- [x] write tests:
  - the table mapping `AXError` to "definitely different" / "cannot tell" / "no element";
  - a concurrency test that `SystemFocusedFieldAccess`'s lock serialises calls, using an injected
    probe function in place of the Carbon call.
- [x] run tests — must pass before next task

- ➕ **Outcome (2026-09-13).** The seams, their fakes and the system adapters are in
  `Sources/DictaRuntime/FocusedField.swift`; nothing constructs an adapter yet (Task 10 wires them).
  - **Frontmost.** `FrontmostFacts` (bundle id, pid, name) is in DictaCore beside `HoldWatch`, because
    Task 7's `HoldRoute` takes it. `FrontmostApplication` now has one property, `current`, and
    `SystemFrontmost` builds it from the notification's `NSRunningApplication`. `Pending.frontmost`
    carries it from the one read that also decides `wasFrontmost`; an `up` reads nothing.
  - **The system-frontmost test posts the activation notification by hand**, naming a running
    application that is neither the test process nor the cached frontmost one. The first draft named
    the first running application, which happened to be the cached one (loginwindow in this shell),
    so a mutation reading the cache survived; the fixed test kills it. `NSRunningApplication.current`
    reports pid -1 in a bundle-less process and could not be used.
  - **`FocusedFieldError`** is the three-way table: `noValue` → `noElement`, `invalidUIElement` →
    `definitelyDifferent`, every other error → `cannotTell`. A focused element owned by another pid is
    also `definitelyDifferent`.
  - **`AXManualAccessibility`** is read before it is set, rather than remembered by pid, so "once per
    application process" holds across pid reuse; already on, or refused by the application, means no
    re-read. ⚠️ The wait before the one re-read (`manualAccessibilitySettle`, 0.25 s) is **not
    measured**; too short costs one refused first dictation per application launch.
  - **`hasSelectedTextRange`** comes from the attribute-name list, so the range itself is never read.
  - **Deviation:** `EventPoster.post` throws (`EventPostFailure`) when the events cannot even be built,
    rather than dropping the chunk silently; a posted event still has no error channel.
  - **`SystemEventPoster.keystrokes(for:)`** builds the pair without posting, so a test reads back
    keycode 0, key-down/key-up, empty flags and the whole string, including a 200-unit chunk.
  - **Fakes:** `FakeFocusedFieldAccess` (call log, scripted answers, a hook inside the read),
    `FakeEventPoster` (a hook after chunk k), `FakePacer` (advances a `FakeClock`); `FakeFrontmost`
    is scripted and counts reads.
  - Mutation check: dropping the lock, mapping `invalidUIElement` to `cannotTell`, dropping the empty
    flags, reading frontmost twice at a press, and reading the workspace cache in the observer each
    failed a new test. Tests: 628 in 37 suites green under Xcode 26.6 (Swift 6.3.3), nine new; lint
    clean (swiftlint not installed, built-in checks only); linkage clean.

### Task 6: `SystemFeedback` and an optional `Terminal` — plumbing the daemon's field path will need

**Files:**
- Create: `Sources/DictaRuntime/SystemFeedback.swift`, `Sources/DictaTestRunner/SystemFeedbackTests.swift`
- Modify: `Sources/DictaRuntime/Agterm.swift` (share the notification builder and its escaping)
- Modify: `Sources/DictaRuntime/Daemon.swift` (`TerminalProvider` returns `Terminal?`, the
  untargeted notifier falls back)
- Modify: `Sources/DictaTestRunner/DaemonTests.swift`
- Modify: `docs/manual-checklist.md` (citations)

- [x] write the red tests first:
  - listening plays `Pop`, done plays `Tink`, a failure plays `Basso` and notifies, through the
    `CommandRunner` fake or a sound seam depending on F11;
  - `clearIndicator` is a no-op;
  - the notification text is escaped for F11's mechanism (quotes, backslashes, a multi-line reason);
  - a daemon whose provider returns `nil` refuses a session chord and a `focus` start with a reason
    naming `agtermctl`, and its untargeted refusals notify through `SystemFeedback`.
- [x] implement `SystemFeedback: Notifier`, extract the shared notification builder from
  `Agterm.notify`, make `TerminalProvider` optional, and have `init` tolerate `nil`.
- [x] parameterise the D13 ordering test over both notifiers: no `Pop` before capture confirms it is
  running.
- [x] add citations, then run tests — must pass before next task

- ➕ **Outcome (2026-09-13).** `SystemFeedback` is in `Sources/DictaRuntime/SystemFeedback.swift`;
  nothing routes a field target to it yet (Task 8), and `main.swift` hands it to the daemon while
  `agtermctl` is still required (Task 10 makes it optional).
  - **Sound seam.** F11 chose `NSSound`, so the seam is `SoundPlayer` (`SystemSoundPlayer` in
    production, `FakeSoundPlayer` in the fakes) rather than the `CommandRunner`. Notifications go
    through the runner to `osascript`. `working` is silent, as it is in agterm.
  - **Target-agnostic.** `SystemFeedback` plays and notifies for any target, since which attempts
    reach it is the daemon's routing; that is also what lets the D13 test drive it with an agterm
    target.
  - **Shared builder.** `ScriptNotification` holds the `osascript` arguments and the escaping that
    `Agterm.quoted` used to; `Agterm.notify`'s fallback calls it, and a test asserts both notifiers
    post identical arguments.
  - **Daemon.** `TerminalProvider` returns `Terminal?`; the designated `init` takes `feedback: any
    Notifier` with no default (a default would play real sounds from tests), and the fixed-terminal
    convenience init passes its notifier. With no terminal, `begin` refuses before resolving with
    "`<verb>` needs agterm: agtermctl is not installed, so dicta cannot reach agterm", opening
    nothing, and every untargeted notification falls back to `feedback`. `deliver` classifies a
    missing injector as `notStarted` (unreachable while an attempt holds its agterm);
    `clearStaleIndicator` does nothing without an agterm.
  - **D13 over both notifiers** is `test: no Pop is heard before capture confirms it is running,
    through either notifier`, counting `Pop` in `agtermctl session status` arguments and in the
    sound player.
  - **Citations:** invariant 4, the "agtermctl is absent" §7 row, and the no-grant row (the sound
    and notification pair).
  - Mutation check: announcing `listening` before `capture.begin`, `done` → `Pop`, dropping the
    `\n` escape and a refusal reason not naming `agtermctl` each failed a new test. Tests: 637 in
    38 suites green under Xcode 26.6 (Swift 6.3.3), nine new; lint clean (swiftlint not installed,
    built-in checks only); linkage clean.

### Task 7: `HoldRoute`, the threshold edge, and the trigger's field path

**Files:**
- Create: `Sources/DictaCore/HoldRoute.swift`, `Sources/DictaTestRunner/HoldRouteTests.swift`
- Modify: `Sources/DictaCore/PushToTalk.swift` (`HoldWatch` threshold edge and generation)
- Create: `HoldLiveness` in `Sources/DictaRuntime/HoldTrigger.swift` (the poller-written snapshot)
- Modify: `Sources/DictaCore/Wire.swift` (`Request.field`, `Request.conflict`)
- Modify: `Sources/DictaRuntime/HoldTrigger.swift`
- Modify: `Sources/DictaTestRunner/HoldTriggerTests.swift`, `WireTests.swift` and the existing
  `HoldWatch` tests
- Modify: `docs/manual-checklist.md` (citations)

- [x] write the red tests first, pure:
  - every cell of the routing table: {agterm, other} × {off, on}, plus a nil bundle identifier;
  - `Request.conflict` refuses `field` together with `focus` or with `sessionID`, and accepts each
    alone;
  - `HoldWatch` emits `threshold` once, from sampled time, only while the field route is pending;
  - no `threshold` between a sampled `down` and `up` shorter than the floor;
  - `threshold` carries the owner's generation;
  - the second armed key's edges do not produce a `threshold` for, or end, the owner's hold;
  - the agterm route's edge sequence is unchanged.
- [x] implement `HoldRoute.decide`, the threshold edge and generation, and `Request.field`/`conflict`.
- [x] implement `HoldLiveness`, written by the poll loop at every owning `down` and `up` (in
  `sample()`, before the edge is queued) and read by the sender under its own lock, which is released
  before any grant, AX or socket work.
- [x] in the trigger's sender, act on the field path:
  - `down` records the pending hold;
  - `threshold(g)` starts only if `HoldLiveness` says g is the current owner generation **and still
    held**. The sender then checks the grant (a refusal notifies) and the frontmost pid (a change is
    a silent no-op), then sends `start` with `field`;
  - `up(g)` stops if a start was committed for g, unless the frontmost pid differs from the one
    captured at `down(g)` by the end of the settle window, in which case it aborts silently; with no
    committed start it discards;
  - a `threshold` failing the liveness check is dropped;
  - `HoldToTalk`'s floor is not applied a second time to the threshold-started attempt.
- [x] write `HoldTriggerTests` with fakes and a blocked sender:
  - a short `down`/`up` both queued behind a sender blocked on a previous request produce **zero**
    `FocusedFieldAccess` calls, requests and notifications once it unblocks;
  - a **long** hold released while the sender was blocked, queued as `[down(g), threshold(g),
    up(g)]`, produces zero `FocusedFieldAccess` calls, requests and notifications: liveness already
    says released;
  - the same with `[down(g), threshold(g), up(g), down(g+1)]` queued, where g+1 is held: `threshold(g)`
    is dropped, and only a later `threshold(g+1)` may start;
  - the poller records the release **before** the sender's liveness check: the threshold is
    discarded, and nothing is sent;
  - the release lands **after** the liveness check (the fake socket blocks the start): the start is
    committed, and the queued `up(g)` then stops it as a stop, not an abort;
  - a started field attempt whose frontmost pid changes during the hold, or within the settle window
    after `up(g)`, is aborted with no notification and no sound; one whose pid never changes is
    stopped;
- [x] ⚠️ on hardware, before fixing the settle window's constant: time the activation notification
  after a right-hand ⌘Tab release, over repeated switches, and record it in F11; (skipped - not
  automatable: needs a person pressing ⌘Tab; the window is a provisional constant, see the outcome.
  The three bullets below are tests, and were written.)
  - with the grant missing, a threshold notifies once and sends nothing;
  - with the option off, the `FocusedFieldAccess` fake records **zero** calls in every scenario;
  - the existing test `the hold key does nothing at all while another application is frontmost`
    becomes its "with focused fields off" form, and its checklist citation is renamed in this task.
- [x] add the citations to invariant 13's and the §7 audit lines, then run tests — must pass before
  next task

- ➕ **Outcome (2026-09-13).** `HoldRoute` is in `Sources/DictaCore/HoldRoute.swift`; `HoldWatch` has
  the threshold edge and the generation; `Request` has `field` and `conflict`; `HoldLiveness` and the
  trigger's field path are in `HoldTrigger.swift`. Nothing constructs the field path yet (Task 10
  wires it), and the daemon does not yet act on `field` (Task 8).
  - **`HoldRoute.decide` takes no `ownBundleIDs`.** Technical Details predates F11, which removed
    dicta's own bundles from the table (D30, D31); `frontmost` is optional, and nothing frontmost is
    `.ignore` either way. A field target's `appName` falls back to the bundle id, then `pid N`.
  - **Edge shape.** `.threshold` is a third case of `ModifierWatch.Edge`, which `ModifierWatch` never
    produces. The generation is `HoldWatch.generation`, not a field of `HoldEdge`, so every existing
    `HoldEdge` equality stayed as it was; `Pending` carries `generation` and the `down`'s `route`. The
    timed call is a new `sample(_:at:)` beside the untimed one, and the poll loop now reads the clock
    on every sample rather than only on an edge.
  - **Wiring shape.** `Configuration.focusedFields` plus an optional `HoldTrigger.FocusedFields`
    (access, feedback notifier, pacer); the route opens only when both are present, so the option-off
    test hands the trigger a live fake and asserts it is never called. Field-path refusals go through
    `FocusedFields.feedback` (the agterm notifier is silent for a field target): the missing grant,
    a daemon refusal and a send error each play `blocked` and notify; the silent cases are a stale
    threshold, a switch before the threshold and a switch at the release (the abort's answer is not
    reported).
  - **The settle window is `HoldTrigger.defaultSettleWindow` = 0.25 s, ⚠️ not measured.** It is
    measured from the sampled release, so a sender already that far behind waits no longer, and it
    runs through the `Pacer` seam. The pid is compared at the release and again after the wait.
  - **"Blocked sender" is the queue, not a thread.** The tests collect `sample()`'s `Pending`s
    without performing them and then perform them in order, which is exactly what the sender finds
    when it unblocks; the release-during-start race uses a new `FakeDaemonDoor.duringSend` hook that
    releases the key and samples while the start is on the wire.
  - **Citations:** invariant 13 (routing, option off, liveness), the renamed D22 row, and the
    released-before-the-floor, switched-application and no-grant §7 rows. The renamed test is
    `with focused fields off, the hold key does nothing at all in another application`, because the
    plan's wording overran lint's 100 columns.
  - Mutation check: dropping the liveness check, dropping the re-check after the settle wait,
    dropping the session conflict and ignoring the floor in the threshold together failed 10 tests.
    Tests: 667 in 41 suites green under Xcode 26.6 (Swift 6.3.3), 30 new; lint clean (swiftlint not
    installed, built-in checks only); linkage clean.

### Task 8: The daemon's focused-field start path, with refusals before capture and owned handles

**Files:**
- Modify: `Sources/DictaRuntime/Daemon.swift`
- Modify: `Sources/DictaTestRunner/DaemonTests.swift`
- Modify: `docs/manual-checklist.md` (citations)

- [x] write the red tests first, with fakes:
  - a `field` start with the grant, no Secure Input, and a readable, **eligible** element with a
    matching pid starts capture, and the snapshot's target is `.focusedField`;
  - each of these is refused with **the capture fake recording no start**: no grant, Secure Input,
    unreadable element, pid mismatch, `.ineligible`, `.unknown`, option off, `Request.conflict`;
  - a waiting `dictate` claim still returns the text (D29).
- [x] write the red ownership tests:
  - a field start refused because an attempt is busy (field or agterm) neither overwrites nor
    releases the live attempt's handle;
  - a late teardown of attempt N (a fault, a watchdog firing on another thread) after attempt N+1
    was accepted leaves N+1's handle in place;
  - **acceptance and abort interleaved:** an `abort` is injected on another thread at the point
    between the machine accepting a field start and `apply` releasing `stateLock` (a test hook in
    `onAcceptedStartLocked`). The hook **only launches or signals** the abort contender and then
    returns. It never waits for the abort inside the hook, because the abort needs the same
    `stateLock`. The test joins and asserts only after the lock is released: `fieldHandles` holds no
    handle for the aborted attempt, and the handle was never observable without its accepted
    attempt;
  - a handle is released after `injected`, `cancelled`, `capture-fault`, `target-gone` and a refusal.
- [x] implement the branch in `begin`:
  - resolve into a local, with no lock held across AX;
  - refactor `apply` to take an optional `onAcceptedStartLocked` step that runs inside the same
    `stateLock` acquisition as `machine.apply`, and store `fieldHandles[attemptID]` there;
  - release by id on every ending.
- [x] route injection and feedback by target case.
- [x] add citations, then run tests — must pass before next task

- ➕ **Outcome (2026-09-13).** The daemon acts on `Request.field`: `beginField` in `Daemon.swift`
  refuses before capture, holds field handles by attempt id, and routes delivery and feedback by
  target case. Nothing constructs `Daemon.FocusedFields` in `main.swift` yet (Task 10 wires it), and
  no production `FieldInjector` exists yet (Task 9).
  - **Deviation: a `FieldInjector` seam rather than `Injector`.** The handle has to reach delivery
    and `Target` (DictaCore) cannot carry an `AXUIElement`, so `FieldInjector.inject(_:into:handle:)`
    sits beside `Injector` in `FocusedField.swift`; Task 9's `FocusedFieldInjector` conforms to it.
    `Daemon.FocusedFields` is `{access, injector}`, handed to the designated `init` as `fields:`
    (default `nil`, the option off).
  - **Order in `begin`.** `Request.conflict` first, for every start or toggle; then a `field` request
    leaves the agterm road before `adoptTerminal`, so it needs no `agtermctl`. Checks: option on, grant,
    Secure Input, one focused-element read for the request's pid, `FieldEligibility`. Every refusal
    goes through `reject(_:for:)` to `feedback`, aimed at the field; a conflict stays untargeted.
  - **Ownership.** `apply` takes `onAcceptedStartLocked`, called inside the `machine.apply` critical
    section only when the phase went from no attempt to one; the same section drops the handle of
    whichever attempt the event ended, by that id. So a handle is never observable without its live
    attempt, and release covers every ending with no per-ending code. Test surface:
    `fieldHandle(for:)`, `fieldHandleAttempts` (live id and held ids from one acquisition) and
    `duringFieldAcceptance(_:)`, the hook inside that section.
  - **Routing.** `notifier(for:)` answers `feedback` for a `.focusedField` target and agterm's notifier
    (or `feedback` without agterm) otherwise; announcements, notifications, config and record trouble
    and the undecodable-frame notice all go through it.
  - **The interleaving test waits for the contender thread to be running, plus 20 ms, inside the
    hook** -- never for the abort. Without that, moving the insert after the unlock still passed,
    because the insert beat an unscheduled thread. The late-teardown test aborts attempt N while
    `warming`: a journalling attempt's late fault is swallowed before any transition and proved nothing
    (a "clear every handle on a fault" mutation survived until this was changed).
  - ⚠️ **A field refusal is notified twice.** The daemon notifies through `feedback`, and the trigger
    (Task 7) also notifies a daemon refusal through its own feedback. The agterm path already doubles
    the same way (`reject` plus the trigger's `notifier.notify`); left consistent, and worth one fix
    for both paths rather than two.
  - **Citations:** invariants 3 and 14, and the no-grant, Secure Input, unreadable element,
    ineligible/unknown and gone-before-delivery §7 rows.
  - Mutation check: inserting the handle after `apply` released the lock (2 issues), clearing every
    handle on a fault (2), routing a field's feedback to agterm (4) and skipping eligibility (6) each
    failed. Tests: 676 in 41 suites green under Xcode 26.6 (Swift 6.3.3), nine new (17 cases); lint
    clean (swiftlint not installed, built-in checks only); linkage clean.

### Task 9: `FocusedFieldInjector` — re-validate, bound, pace, post, abort mid-way

**Files:**
- Modify: `Sources/DictaRuntime/FocusedField.swift`
- Modify: `Sources/DictaTestRunner/FocusedFieldTests.swift`, `DaemonTests.swift`,
  `TranscriberTests.swift`
- Modify: `docs/manual-checklist.md` (citations)

- [x] write the red tests first:
  - **happy path:** the chunks posted to the captured pid concatenate to `final`, every event
    carries empty flags, and pacing goes through the `Pacer` fake;
  - **order:** planning runs before the final validation, and nothing but posting follows it (the
    fakes record call order);
  - **definite change before delivery:** a different element or frontmost pid is `targetGone` with
    zero events;
  - **same handle, changed eligibility:** fresh `FieldFacts` classify `.ineligible` or `.unknown` at
    the final validation, giving `notStarted` with zero events;
  - **deadline expired before the first event:** `notStarted` with zero events, not `mayBePartial`;
  - **AX succeeds late:** a fake AX read that succeeds but advances the clock past the deadline gives
    zero posts and `notStarted`; one that succeeds while the frontmost pid changes gives zero posts
    and `targetGone`;
  - **AX cannot answer at re-validation:** a timeout or error is `notStarted` with zero events;
  - **grant revoked, or Secure Input on:** `notStarted` with zero events;
  - **frontmost pid changes after chunk k:** `mayBePartial`, exactly k chunks, no retry;
  - **delivery deadline passes after chunk k:** `mayBePartial`, exactly k chunks;
  - **`final` over the bound:** a dictionary rule expanding the recognised text past `maxChunks`, and
    separately a single oversized grapheme, are `notStarted` with zero events, and `final` is in the
    record;
  - **invariant 1:** `test: a focused-field delivery posts only the sanitised single line`, driven
    through `Daemon.deliver` with a newline before sanitising;
  - **invariant 10:** recognised text reaches the record before the first event.
- [x] implement the injector in the order plan → final validation (deadline, pid, element,
  eligibility, Secure Input, grant, then deadline and pid again once AX has returned) → post. Use the `Pacer`, `KeystrokeChunks`' two rejections and
  the monotonic deadline.
- [x] add the delivery ceiling to `daemonCeilingsFitTheClientTimeout`, counting the AX and feedback
  calls actually made. Set the deadline below the ceiling, and grow the client timeout only if the
  assertion shows it must.
- [x] assert D20 on this path: an abort during `injecting` is refused.
- [x] add citations for invariants 1, 3, 10 and 14 and the delivery §7 rows, then run tests — must
  pass before next task

- ➕ **Outcome (2026-09-13).** `FocusedFieldInjector` is in `Sources/DictaRuntime/FocusedField.swift`
  and conforms to Task 8's `FieldInjector`; nothing constructs it in `main.swift` yet (Task 10).
  - **Order.** The deadline is read once when `inject` is handed the text, then the plan, then the
    final validation in D32's order, then posts. `test: planning comes before the final validation,
    and nothing but posting follows it` logs every seam call, the clock included, into one sequence.
  - **Classification.** `noElement` and `definitelyDifferent` at re-validation are `targetGone` (the
    application answered definitely), `cannotTell` is `notStarted`. **Nothing frontmost** is
    `notStarted` before the first event, since it names no other application, and `mayBePartial`
    after one. An event that cannot be built is `notStarted` for the first chunk and `mayBePartial`
    after.
  - **Monotonic deadline.** `now` is a closure, `ProcessInfo.systemUptime` in production, the
    `FakeClock` in tests. `deliveryDeadline` = 10 s (F11: 108 events in 22 ms, so the largest standard
    plan is about a second); `chunkPause` = 0 (F11).
  - **Deviation: the delivery ceiling is built on the deadline, not on `maxChunks`.** The plan's
    formula (`maxChunks × (pause + check) + AX calls × timeout`) is near zero with no pause and would
    undercount posting. `FocusedFieldInjector.worstCaseSeconds` is the deadline, plus one validation
    read that began just before it (`SystemFocusedFieldAccess.worstCaseMessagesPerRead` = 9 messages,
    counted off the code, at the 0.25 s timeout, plus the settle), plus one pause and a per-chunk
    allowance (0.01 s, fifty times F11's per-event cost; not measured per event). Feedback is
    `SystemFeedback.worstCaseCallsPerStop` = 4 `osascript` calls. The field stop is 60 + 30 + 12.51 + 32
    s against `pipelineRead` 240, so the client timeout did not grow.
  - **Through the daemon:** invariant 1 (the hostile transcript posted as the sanitised line in
    several chunks), invariant 10 (the record read from inside the first post), the bound with
    **final** in the record (a dictionary rule and a long grapheme, against a small planner), and
    D20 (an abort from inside a post refused while the rest is posted). `Harness` gained
    `fieldInjector:`; `EventPostFailure` gained a public `init`.
  - **Citations:** invariants 1, 3, 10 and 14; the abort-during-injection, bound, deadline,
    gone-before-delivery, AX-cannot-answer and other-application-mid-delivery §7 rows. Invariant 14's
    "never reads a value" and "never by the client or the menu bar" are still uncited (Task 11 closes
    the second).
  - Mutation check: dropping the re-check after AX, `cannotTell` → `targetGone`, dropping the per-chunk
    frontmost check and skipping eligibility together failed 19 issues; validating before planning,
    5; ignoring the deadline mid-delivery, 9. Tests: 695 in 42 suites green under Xcode 26.6 (Swift
    6.3.3), 19 new (29 cases); lint clean (swiftlint not installed, built-in checks only); linkage
    clean.

### Task 10: `DaemonOptions`, composition, readiness, installer

**Files:**
- Create: `Sources/DictaCore/DaemonOptions.swift`, `Sources/DictaTestRunner/DaemonOptionsTests.swift`
- Create: `Sources/DictaRuntime/FocusedFieldWiring.swift`
- Modify: `Sources/Dicta/main.swift`
- Modify: `Sources/DictaCore/StatusSnapshot.swift`, `Presentation.swift`, `MenuModel.swift` and their
  tests
- Modify: `Scripts/install.sh`, `Scripts/launchagent.plist`, `Sources/DictaTestRunner/BundleTests.swift`
- Modify: `docs/manual-checklist.md` (citations)

- [x] write the red tests first:
  - `DaemonOptions` parses every existing flag exactly as `main.swift` does today, including
    unknown-option and empty-argument errors, plus `--focused-fields`, which is off by default;
  - `FocusedFieldWiring.make` returns `nil` and constructs no system adapter when the option is off
    (an injected factory counts constructions);
  - when the option is on, it constructs one shared `SystemFrontmost`, even with `--no-hold`;
  - `terminalMissing` blocks dictation only when the option is off, and `Presentation`/`MenuModel`
    render the on case as a notice, not a fault;
  - the stale-indicator cleanup is skipped for a `.focusedField` in `activeTargetFile`.
- [x] move flag parsing into `DaemonOptions` and wiring into `FocusedFieldWiring`, keeping `main.swift`
  thin:
  - option off: a missing `agtermctl` stays fatal;
  - option on: it is logged and optional;
  - add the start-up line `focused fields: on|off, accessibility: granted|not granted`.
- [x] installer:
  - `install.sh --focused-fields` substitutes a **whole** `<string>--focused-fields</string>` line,
    or removes the placeholder line;
  - the keymap step prints only when `agtermctl` is found;
  - re-running without the flag turns the option off, and the script says so;
  - the plist comment that calls a missing `agtermctl` fatal is updated.
- [x] write a `BundleTests` test: the plist generated for both settings passes `plutil -lint`, with
  no empty `<string></string>` in `ProgramArguments`.
- [x] add citations, then run tests — must pass before next task

- ➕ **Outcome (2026-09-13).** `main.swift` now parses through `DaemonOptions` (DictaCore) and composes
  the field path through `FocusedFieldWiring` (DictaRuntime); with `--focused-fields` a missing
  `agtermctl` is logged and survived, and without it it stays fatal.
  - **Deviation: readiness gained a case rather than a conditional verdict.** `Readiness` is one verdict
    with a context-free `blocksDictation`, so the option-on fact is a new non-blocking
    `.fieldsOnly` (`"fields-only"` on the wire), derived by `Faculties.readiness` only once start-up
    has settled; `.terminalMissing` is now produced only with the option off. `Faculties` gained
    `focusedFields`, which `Daemon.init` sets from `fields != nil`, so the verdict cannot disagree with
    what the daemon was built with. The menu draws it as an idle, quiet `mic` saying "Ready, without
    agterm", with an amber banner and no action; red stays the option-off fault's.
  - **Deviation: the start-up line with the option off is `focused fields: off, accessibility: not
    checked`.** The trust check is an accessibility call, and the option off makes none (invariant
    14). With it on it reads `granted` or `not granted` through the wired access.
  - **Deviation: `make(options:feedback:adapters:)`, not `make(options:frontmost:)`.** `Adapters`
    holds three factories (frontmost, access, poster), `.system` in production and counting fakes in
    the tests; `Wired` carries the one frontmost source plus the daemon's and the trigger's
    `FocusedFields`. The trigger's notifier falls back to `SystemFeedback` when there is no agterm.
    `DaemonOptions.agtermAtStartup(found:)` is the fatal/optional decision.
  - **Deviation: a new `Scripts/render-agent.sh`.** The agent's rendering moved out of `install.sh` so
    `BundleTests` runs the exact rendering for both settings through `plutil -lint` without a test
    ever being one broken argument away from a real install. The template's `ProgramArguments` has a
    whole `<string>__DICTA_FOCUSED_FIELDS__</string>` line, replaced whole or deleted.
  - **Installer.** Unknown arguments are refused (a typo must not install the option silently off);
    the agent being replaced is read first, so re-running without the flag prints `focused fields:
    turned OFF`; the keymap step prints only when `agtermctl` is found at the daemon's candidate paths
    or on `PATH`; with the option on, a step names the Accessibility grant. ⚠️ `install.sh` itself was
    not run: it would rebuild and replace the live agent on this machine. H33 scores it.
  - **Stale indicator.** `clearStaleIndicator` asks the provider only for a parked `.agterm`; a parked
    field's file is removed and nothing is notified.
  - **Citations:** invariant 14 ("only when on", the wiring), the stale-indicator row, and the
    agtermctl-absent-with-the-option-on row (start-up, readiness, menu, rendered agent).
  - Mutation check: the readiness ignoring the option, the cleanup ignoring the target case, the
    frontmost factory called before the option guard, the renderer substituting the placeholder
    with nothing, and the notice banner drawn red together failed 11 issues in 7 tests, each
    mutation caught. Tests: 712 in 43 suites green under Xcode 26.6 (Swift 6.3.3), 17 new (29
    cases); lint clean (swiftlint not installed, built-in checks only); linkage clean. Smoke-checked
    on the debug binary: `--help` lists `--focused-fields`, `--bogus` and `--control ""` exit 2 with
    the old lines.

### Task 11: Linkage gate — only the daemon may post events or touch AX

**Files:**
- Modify: `Scripts/linkage.sh`

- [x] first run the new patterns against the **current** `dictactl` and `DictaMenu` binaries and
  confirm they match nothing. SwiftUI's accessibility symbols must not trip an AX pattern; narrow it
  to exact C function names if they do.
- [x] extend the `dictactl` and `DictaMenu` checks to fail by name on `CGEventPost`,
  `CGEventPostToPid`, `CGEventKeyboardSetUnicodeString`, `AXUIElementCreateSystemWide` and
  `AXUIElementCopyAttributeValue`.
- [x] probe the gate:
  - add a `CGEvent.postToPid` call to `dictactl` and watch `linkage.sh` fail by name;
  - remove the call and watch the gate pass;
  - quote the observed failure line in the script comment.
- [x] confirm invariant 11's four symbols are still absent from `Dicta`.
- [x] run `bash Scripts/test.sh` (it runs linkage first) — must pass before next task
  - Probe: the five names, anchored as exact C symbols, matched nothing in the current `dictactl`
    and `DictaMenu` (no SwiftUI accessibility symbol tripped them) and four in `Dicta`
    (`_AXUIElementCopyAttributeValue`, `_AXUIElementCreateSystemWide`,
    `_CGEventKeyboardSetUnicodeString`, `_CGEventPostToPid`), the positive control. A `postToPid`
    call added to `dictactl` failed the gate with exit 1 on `U _CGEventPostToPid`; reverted, it
    passed. Invariant 11's four symbols are still absent from `Dicta`. ➕ Added
    `test: linkage.sh forbids the client and the menu posting keystrokes or reading accessibility`
    (mutation: dropping the menu's call fails it) and cited it with the gate in invariant 14's
    checklist row, replacing the "not held by anything yet" gap. Tests: 713 in 43 suites green
    under Xcode 26.6 (Swift 6.3.3), 1 new; lint clean (swiftlint not installed, built-in checks
    only).

### Task 12: Verify acceptance criteria

- [x] verify every Overview decision is implemented:
  - any focused field;
  - agterm optional;
  - opt-in, with zero AX calls when off;
  - Unicode keystrokes to the pid;
  - agterm-first routing;
  - right-hand combinations released before the floor costing nothing.
- [x] verify every new or reworded §7 row and invariants 1, 13 and 14 cite a test or an H item
  (`ChecklistTests` enforces this).
- [x] run the full suite with `bash Scripts/test.sh`, and report the test count and the toolchain it
  ran under.
- [x] run `bash Scripts/lint.sh`.
- [x] run `bash Scripts/coverage.sh`: `DictaCore` stays above its 80% floor.
  - Verified against the code: `HoldRoute.decide` routes agterm first with the option on or off, any
    other application to its field only with the option on; `DaemonOptions.agtermAtStartup` keeps a
    missing `agtermctl` fatal only with the option off, and `main.swift` builds the terminal as
    optional; `FocusedFieldWiring.make` returns `nil` before calling any adapter with the option off;
    `SystemEventPoster` posts keycode-0 events carrying the Unicode string, flags empty, through
    `postToPid`; `HoldTriggerTests` holds that a press sends nothing and calls no accessibility
    until the threshold, and that a short or queued combination costs nothing. Every Audit 2 row and
    invariants 1, 13 and 14 cite a test or an H item, and `ChecklistTests` passes.
  - ➕ Invariant 14's last clause, "never reads a field's value or selected text", was the one
    clause the checklist still named as held by nothing. Closed: `SystemFocusedFieldAccess` now copies
    attributes only through `copy(_:of:into:)`, typed by the closed `ReadAttribute` list (focused
    element, `AXManualAccessibility`, role, subrole), and `test: the adapter can copy only identity
    attributes, never a field's value or selected text` holds the list and that `Sources/` has exactly
    one `AXUIElementCopyAttributeValue(` and no multiple or parameterized copy. Mutation check: an
    `AXValue` case and a copy around the funnel each failed it. The checklist row's stale "Only human
    items yet" opening went with the gap.
  - Tests: 714 in 43 suites green under Xcode 26.6 (Swift 6.3.3), 1 new; linkage clean; lint clean
    (swiftlint not installed, built-in checks only); coverage: DictaCore at 98.69% lines, floor 80%.

### Task 13: [Final] Update documentation

- [x] `README.md`:
  - Requirements: agterm becomes optional;
  - a "Dictating into any app" section covering `--focused-fields`, the grant, the floor's extra delay before
    `Pop`, password fields, chords and `raw` staying agterm-only, the pasteboard never
    being used, and VS Code's accessibility-mode note from F11;
  - installing without agterm.
- [x] `AGENTS.md`:
  - "Where it stands";
  - rules worth not relearning:
    - AX never on the poll thread;
    - one observer-backed frontmost source;
    - flags zeroed on every posted event;
    - the element never leaves the daemon, and its value is never read;
    - `postToPid` and why not the HID tap;
    - the field path starts on the poll loop's threshold edge, never by sleeping in the sender, and why;
    - `IsSecureEventInputEnabled` is system-wide and not thread safe;
    - field handles are owned by accepted attempt id;
    - the option off means zero AX calls, and which test holds that;
    - one-way record compatibility.
- [x] repository convention: plans stay in `docs/plans/` as historical run records (both earlier
  plans are there), so this file is not moved to `docs/plans/completed/`.

- ➕ **Outcome (2026-09-13).** `README.md` gained "Dictating into any app" (the option, the grant, the
  floor's later `Pop`, what is refused, where the text goes and does not, feedback, chords and `raw`
  agterm-only, no pasteboard, and F11's VS Code and Electron notes), the optional agterm in
  Requirements, installing with `--focused-fields` and without agterm, the field shape of `target`,
  and the daemon's usage block quoted as `Dicta --help` prints it. `AGENTS.md` gained the plan in
  "Where it stands", the installer and linkage changes in Commands, the new files in Structure, and a
  section "Focused fields, and why the permission is opt-in" carrying every listed rule; the D21 rule
  now names the one path where the floor delays the start. The plan stays in `docs/plans/`, and
  AGENTS.md says that is the convention.
  - ⚠️ **The grant is never prompted for.** The daemon checks `AXIsProcessTrusted` only
    (`FocusedField.swift`), while F11 found that only `AXIsProcessTrustedWithOptions` with the prompt
    option adds `Dicta.app` to the Accessibility list. `install.sh`'s comment ("TCC adds the entry the
    first time the daemon checks") and H28 (a) ("`Dicta` is now listed") both assume otherwise. The
    README tells the user to add `~/Applications/Dicta.app` with `+` if it is not listed, which holds
    either way; H28 (a) will settle it, and a prompting check is the likely fix.
    ➕ Fixed in review: `main.swift` calls `SystemFocusedFieldAccess.requestTrust()`
    (`AXIsProcessTrustedWithOptions` with the prompt option) once at start-up, with the option on and
    the grant missing; the installer comment and README now say so. H28 (a) still scores it.
  - Tests: 714 in 43 suites green under Xcode 26.6 (Swift 6.3.3), none new (documentation only;
    `DocumentationTests` still pass); lint clean (swiftlint not installed, built-in checks only).


## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification:**
- Score H24 onwards on this machine:
  - the VS Code editor and integrated terminal, with Claude Code running in the terminal;
  - Slack and Safari;
  - a password field;
  - an app switch during a long delivery;
  - a day of ordinary right-hand ⌘ combinations released before the floor with the option on,
    which must produce no sound, no notification and no record lines; and a count of the
    held-past-the-floor ones that did start an attempt.
- The grant flow from a clean state:
  1. `tccutil reset Accessibility dev.personal.dicta`;
  2. enable `--focused-fields`;
  3. confirm the refusal notification;
  4. grant;
  5. confirm delivery;
  6. rebuild and reinstall, and confirm the grant still holds.
- A user account with no agterm: install, fetch models, dictate into VS Code with the hold key.

**External:**
- The interested VS Code user builds and installs on their own machine. `Scripts/setup-signing.sh`
  creates their local identity, so the grant attaches to it. Collect which apps dropped or rewrote
  characters, as input for revisiting F11's chunk size and delay.
