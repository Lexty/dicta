# A minimal UI for dicta — the design argument

**Decided 2026-08-23.** The user reversed §13 in the part that says "a menu bar" and accepted the
second bundle. The plan of work is `docs/plans/completed/20260823-dicta-menu-ui.md`, which supersedes this
document wherever the two differ; what stays here is the reasoning, which the plan does not repeat.

**Nothing was built when this was written**, and Tier 0 and Tier 1 have been built since — see the
section immediately below for where this document is now wrong. This is the design argument and the
shape that follows from it, written so the decision could be taken before any code existed. It is deliberately consistent with `acta`'s menu-bar
UI, because the two tools sit in the same menu bar on the same machine and a user should not have to
learn two idioms.

Status of the surrounding work when this was written (2026-08-23), gathered from the sessions that
own it rather than from `main`:

- `main` is `4c2ac7c`. `dicta-8f` owns the main checkout, has nothing in flight, and holds a pending
  `SPEC.md` edit for F4, §10 (a) and H5.
- `dicta-cf` holds two uncommitted branches: `dicta-push-to-talk` (hold right Control instead of a
  chord; rewrites §6 substantially, adds invariants 11–13, decisions D21–D26, facts F6–F8a) and
  `dicta-record-window` (adds `speechStartedAt`, `speechEndedAt`, `audioSeconds` to §9; cancelled
  attempts now carry `recognised` with an empty `final`).
- `acta` is on branch `socket-transport`, eight commits ahead of `main`, and already has
  `Command.watch` with coalescing to the newest state, plus app icons for the stable and dev
  flavors. `actactl` is not started.

**Decision numbers: D27 and D28 are this document's; `dicta-cf` holds D21–D26 and D29; everything
from D30 up is free.** D29 was briefly claimed here and given up on cost — theirs is implemented
across fourteen files, this was two paragraphs — so the UI's "no Start" decision is **D30**.

`dicta-cf`'s D29 is `dictactl dictate`: the caller blocks, the user dictates, and the text is
returned on **stdout** rather than typed anywhere (`PROMPT=$(dictactl dictate)`), because agterm's
picker is a native text field `session type` cannot reach. It touches this design in three places,
each marked below: a twelfth `AttemptOutcome` (`returned`), a second concurrently-served verb, and a
new `ControlTimeouts` entry.

---

## What building it decided differently (2026-08-24)

Tier 0 and Tier 1 are built. The plan supersedes this document wherever the two differ, and so does
the code — but a general clause is not a list, and a reader who came here for the shape deserves to
know which parts of it did not survive contact. Each item below is a place where this document is
now **wrong**, not merely incomplete.

- **§5.1's vocabulary table now lives in `docs/ui-vocabulary.md`**, in both repositories, with the
  two conventions and the divergence table. That file is the one to keep current; this section of
  the proposal is history.
- **§5.2's central claim is false.** "This is the 90% of the UI: passive, always visible" describes
  what was built and not what it achieved: `mic` → `mic.fill` changes a fill inside an unchanged
  silhouette of unchanged width, and peripheral vision does not read that. Observed by the user
  against the installed build (SPEC.md **F9**). The menu-bar item now carries a **running clock**
  while the microphone is open, which changes the item's width and therefore reflows the strip. The
  glyph table itself shipped unchanged.
- **The timer's home moved with it.** §5.3 put it in the panel header, where it still is — but
  during a dictation the panel is closed, because the user is looking at the pane they are dictating
  into, so the header's copy is seen by nobody. The strip is where it earns its place.
- **The "last dictation did not land" banner was not built, and is not owed.** §5.3 asked for a
  dismissible orange banner carrying the notification's sentence. It is a line on the **row** that
  failed instead, taken verbatim from §9's `error`, which is better in two ways: one event cannot
  acquire two wordings, and the reason for the attempt *before* the last one is exactly as worth
  having. Rows whose `error` merely repeats the outcome's own name show none — 870 of 902 entries in
  the real record are `aborted` carrying `"aborted"`.
- **A row with no `final` is labelled by its OWN outcome, not "cancelled".** The plan said
  `cancelled` for every such row, which was true when only an abort could produce one; D26 put D15's
  cap in the same shape, and calling a ten-minute dictation stopped by the cap "cancelled" would
  hide the one fact that explains it. The rows say `recognised only` to declare that the words above
  were never typed anywhere.
- **The live target line resolves the session name in the MENU**, out of its own tree read, not in
  the daemon: asking the daemon would put a subprocess on the transition path, which F4 vetoes.
- **§5.1's `DEV` tag is not adopted.** It belongs to an app launched by hand; dicta's menu is a
  LaunchAgent with one installed copy.
- **Tier 2 is untouched, as recommended**: no row expansion, no `Settings` disclosure, no filter
  field. All three wait for step 4.
- **§10's five things to measure were all measured, and two of them were wrong.** The status item
  does appear under a `gui/$UID` LaunchAgent; a `watch` connection costs the keypress path nothing
  above the noise floor; the daemon's TCC grant did not move; the unbounded reader was a real defect
  and `DictaRecord` is the fix. The two this document could not have predicted are **F9a** — the
  menu opened no connection at all until its panel was first opened, because `MenuBarExtra` builds
  its content lazily — and **F9b** — a watcher that attached was told nothing until the daemon's
  next transition, so the strip lied after every restart until somebody dictated.

---

## 1. This argues against two written decisions, and says so

`SPEC.md` §13 lists "a settings window, a menu bar, or a dock icon (D11)" as deliberately not in
scope, and D13 says feedback in v1 is agterm's own status indicator plus sounds, with no GUI. A UI
proposal here is not filling a gap. It is asking to reverse part of two decisions, and it owes the
same standard of reasoning they were written to.

**What D11 actually forbids.** D11 is about the microphone TCC grant: it attaches to a signed bundle
identity, a bare executable would have it attributed to the launching terminal, and a second binary
opening the device would fracture it. Nothing in that reasoning is about pixels. §12 and §13 turned
it into "no menu bar" because at the time the bundle existed *only* as a TCC anchor, and any other
use of it would have been scope creep. That inference still holds for **the daemon's own bundle**.
It does not hold for a second bundle that never opens the microphone — which is exactly the position
`dictactl` already occupies and has occupied since D12.

**What D13 actually forbids.** D13 is about feedback *during an attempt*: no live partial text, and
nothing announced before capture confirms it is running. The proposal below keeps both. It adds no
in-attempt surface the user is expected to look at; the menu-bar glyph follows the same rule as the
agterm indicator and lights on `listening`, never on the keypress.

**What is left after that.** The honest residue of §13 that this proposal does reverse is the flat
"no menu bar". The case for reversing it is in §2. The case for keeping the *daemon* exactly as it
is — no `NSApplication`, no window, no dock icon — is in §4, and this proposal keeps it entirely.

That reversal was granted. §9 records what would have been done instead, because two of its four
items are worth doing anyway.

---

## 2. The four jobs that have no home today

Not "what could a window show" but "what does the user do today that has no good route".

**1. "Is dicta going to work if I press the key?"** Today: run `dictactl status` in a terminal, or
read `~/Library/Logs/dicta.log`. Every startup fault — models not fetched, microphone denied,
`agtermctl` missing, launchd throttle-looping on a bundle that will not start — is written to stderr
and lands in a file nobody reads. The user discovers it by pressing the key and getting silence.
This is the same failure `acta` treats as first-class with its status header and red banner, and it
is the strongest single argument for a menu-bar item: a lamp that is *visible without being asked*.

**2. "What did it actually hear?"** Today: `dictactl last` and `dictactl last --recognised`. The
record already holds far more than that pair — outcome, mode, which replacement rules fired, the
target. Step 3 of §10 is scored on a replacement misfire being diagnosable from the record alone;
today that means reading JSON lines by hand.

**3. "The text did not land — where is it?"** On `target-gone`, `injection-failed` or
`injection-partial`, invariant 10 guarantees the text is in the record and the notification says so.
The route from there to the clipboard is a terminal command in a session that may be the one that
just died.

**4. "Fix the dictionary."** `replacements.conf` lives at a path nobody remembers, under
`~/Library/Application Support/dev.personal.dicta/`. `FileDictionary` re-reads it per attempt, so an
edit fires on the next chord — the feedback loop is already excellent and the only friction is
finding the file.

Three of the four are read-only. That is the shape of the answer: **a lamp and a receipt drawer, not
a control panel.**

---

## 3. What the UI must never do

These are the constraints that make the design small. Each is derived, not preferred.

1. **It never injects.** No "re-send" button, ever. Injecting text at a target the UI chose is D4's
   forbidden substitution with a nicer button on it — the UI has no `$AGT_SESSION_ID` and no chord
   to have captured one. Recovery is **copy to clipboard**, and the user pastes where they meant to.
1a. **`final` is what the UI acts on; `recognised` is only ever displayed.** This is the structural
   form of the rule above, and it is stronger than "no button offers to re-send": every affordance
   that produces text — the copy button, anything a future step adds — reads `final`, and a row
   whose `final` is empty has nothing to give. `dictactl last` already answers off `final` for this
   exact reason, and cancelled attempts (which `dicta-record-window` gives a `recognised` and an
   empty `final`) then fall out correctly with no special case to remember.

   **The limit of that rule, since it is easy to over-claim** — and this document over-claimed it
   once. `final` distinguishes rows that produced text from rows that did not. It says nothing about
   *where the text went*, so it does not separate D29's `returned` (handed to a calling script) from
   `injected` (typed into a pane): both have a full `final`, and every affordance one row has, the
   other has too. That is correct here only because rule 1 leaves exactly one affordance — copy —
   and copying text the user dictated is harmless wherever it went. **Reason from the field, not
   from the outcome's name.** An outcome that must be treated differently needs a check on the
   outcome, and the rule will not do it for you.
2. **It has no Start.** Same reason: a click has no session to aim at, and D22 means agterm is not
   even frontmost while the menu is open. **Stop and Abort are allowed**, because an attempt already
   owns a target that was captured at start and is never substituted. That asymmetry — no Start, yes
   Stop — is the design's clearest fingerprint and is worth stating in the spec.
3. **It shows no partial text** (D1, D13). The recent list is the record, and the record only exists
   after an attempt ends.
4. **It is never on the attempt path.** Nothing the daemon does for a dictation may wait on the UI,
   and the UI being absent, closed, crashed or never installed changes no outcome.
5. **It is not expected to be on screen during a dictation.** D22 refuses to start unless agterm is
   frontmost, so an open menu panel silences the trigger by construction. This is not a bug to fight
   — it is the correct behaviour, and the design leans into it: **the menu is where you go between
   dictations.** The glyph, which is passive and needs no focus, carries the in-attempt half.

---

## 4. Where it lives — and why not in the daemon

Three options were considered. The second is recommended.

### A. A `MenuBarExtra` inside `Dicta.app` (acta's own architecture) — rejected

This is what `acta` does: one app hosts the menu and the control socket, and the menu observes the
façade in-process. It is tempting precisely because it needs no new protocol, and because the daemon
already runs `RunLoop.main.run()` on the main thread for the sleep observer.

It is rejected for three reasons, in descending order of force:

- **`Scripts/linkage.sh` on `dicta-cf`'s branch reads the built `Dicta` binary for
  `_OBJC_CLASS_$_NSEvent`, `CGEventTapCreate`, `CGEventTapEnable` and `IOHIDManager`, and fails by
  name** (invariant 11). A SwiftUI status item drags `NSEvent` in unavoidably. The gate exists so
  that macOS never starts demanding Input Monitoring or Accessibility for a tool that today asks for
  neither, and a UI is a bad reason to weaken it.
- **The daemon's process shape is load-bearing and measured.** F6 and F8a on that branch record that
  `NSEvent.modifierFlags` returns nothing in this process and that `NSWorkspace.frontmostApplication`
  is frozen unless an activation observer is registered. Push-to-talk rests on both. Introducing an
  `NSApplication` changes the shape those measurements were taken in, and every one of them would
  have to be retaken to know whether it still holds.
- **D11's caution, honestly applied.** The TCC grant is identity-based and survives rebuilds — that
  was measured in Task 8 — so adding code does not by itself endanger it. But the bundle currently
  exists for exactly one purpose, and the smallest possible daemon is the one whose grant is easiest
  to reason about.

### B. A second bundle: `Dicta Menu.app` — recommended

**The menu app is `dictactl` with a face.** That single sentence is the whole justification, and it
is the project's own existing logic rather than a new one: dicta already ships a client that speaks
the control socket, links `DictaCore` + `DictaIPC` and nothing else, and never opens the microphone
(D12, invariant 8). A second client of that exact shape costs the daemon nothing.

What it buys:

- The daemon does not change shape at all. No `NSApplication`, no new symbols, F6/F8a stay valid,
  invariant 11's gate stays as strict as it is.
- Invariants 8 and 12 extend to it mechanically: `linkage.sh` gains a row asserting that
  `DictaMenu` binds **no AVFoundation, no CoreML, no FluidAudio** — it may bind AppKit/SwiftUI, which
  is the one difference from `dictactl`'s row — and no `CGEventTap*` / `IOHIDManager` /
  `NSEvent.addGlobalMonitorForEvents` either, so it can never become a second trigger path.
- It can be absent. Not installed, quit, crashed — the daemon and the chords are unaffected, which
  is rule 4 of §3 enforced by construction rather than by discipline.
- Its own bundle identity (`dev.personal.dicta.menu`), signed by the same local identity, so nothing
  about the daemon's designated requirement moves. It must get the **same identity-based signing
  treatment** `bundle.sh` already asserts for the daemon — the menu app needs no TCC grant of its
  own, but a second bundle signed ad-hoc beside one signed for a stable requirement is an
  inconsistency that will be read as an accident later.

What it costs: a second LaunchAgent (or login item) in `Scripts/install.sh`, and a way for it to
learn the daemon's state — see §6.

### C. An agterm HUD panel instead of a menu bar — deferred, not rejected

agterm can post a passive HUD panel over a session while the user keeps typing. That is arguably
more in dicta's spirit than any menu bar: feedback where the eyes already are, no focus stolen, no
window. It is not proposed here for one reason — the request was consistency with `acta`, and `acta`
has no HUD. Worth revisiting if the menu turns out to be opened rarely.

---

## 5. The shape

### 5.1 The vocabulary shared with acta

Read out of `Sources/Acta/ActaApp.swift` as it stands on `socket-transport`. dicta adopts all of it
unchanged; §7 discusses what, if anything, acta should change.

| element | rule |
|---|---|
| container | `MenuBarExtra`, `.menuBarExtraStyle(.window)`, `LSUIElement`, no dock icon |
| panel | `.frame(width: 300)`, `.padding(12)`, `VStack(spacing: 10)`, `Divider()` between sections |
| header | tinted SF Symbol + app name `.headline` + one-line status `.caption`/`.secondary`, trailing monospaced timer in red while active |
| banner | icon + `.caption` text on `tint.opacity(0.12)` in a `RoundedRectangle(cornerRadius: 6)`, optional `xmark` dismiss |
| colours | red = broken now; orange = landed but degraded, or needs attention; green = fine; grey = nothing there |
| primary action | `.borderedProminent`, `.controlSize(.large)`, full-width `Label`, tinted red when it is a stop |
| list | `.caption`/`.secondary` section title, rows of a 7 pt status `Circle` + `.caption` primary line + `.caption2`/`.secondary` secondary line + trailing borderless icon button |
| settings | a `DisclosureGroup` inside the same panel, labelled `Label("…", systemImage: "gearshape").font(.caption)`. **No separate settings window in either app.** |
| footer | `HStack` at `.caption`: a verb on the left, `Spacer`, an exit verb on the right |
| dev flavor | a visible `DEV` tag beside the glyph, and the revision in `.caption2`/`.tertiary` |
| first frame | the view model seeds its state **synchronously** at construction, so the panel never opens blank — `acta`'s `ControlViewModel` does this and it is the detail most worth copying |

Two rules that are conventions rather than code, both learned from what is already there:

- **A control that cannot do what it says must not exist.** This is why the footers differ: `acta`
  has `Quit` because quitting acta quits it; dicta has no `Quit`, because the LaunchAgent has
  `KeepAlive` and launchd would restart the daemon within ten seconds. dicta's right-hand footer verb
  is **`Restart`** (`launchctl kickstart -k`), which is honest and is also the thing you want right
  after `--fetch-models`.
- **Every app in the family owns one glyph and keeps it.** `acta` keeps `waveform`. dicta takes the
  `mic` family. Two items in one menu bar must be distinguishable at a glance and by shape, not only
  by position.

### 5.2 The menu-bar glyph (the part that matters most)

This is the 90% of the UI: passive, always visible, never focused, no click.

| daemon state | glyph | tint |
|---|---|---|
| ready, idle | `mic` | secondary |
| warming | `mic` | secondary — status text carries "Starting…" |
| recording | `mic.fill` | red |
| processing / injecting | `mic.badge.plus` (or `ellipsis.circle`) | amber |
| cannot dictate — mic denied, models missing, `agtermctl` absent | `exclamationmark.triangle.fill` | red |
| daemon not running (socket absent) | `mic.slash` | tertiary |

D13's rule applies here in full: **the glyph lights on `listening`, not on the keypress.** The four
states above the fault rows are exactly §6's Feedback table, so the glyph and the agterm indicator
can never disagree — they are driven by the same transitions.

The last row is the one `acta` cannot have and dicta must: a menu app whose daemon is gone. An
absent socket means "not running", with no launch-on-demand — the same rule `acta` wrote into
`actactl`'s constraints.

### 5.3 The panel, section by section

```
┌─ Dicta ───────────────────────── 0:42 ─┐   ← header: glyph, name, status line, timer
│ ▲ Models are not downloaded.            │   ← banner (only when there is one)
│   [ Fetch Models… ]                     │
├─────────────────────────────────────────┤
│ → claude-code · left                    │   ← target, only while an attempt is live
│ [        Stop and type        ]         │   ← primary action, only while an attempt is live
├─────────────────────────────────────────┤
│ Recent Dictations                       │
│ ● now, in 12s. Let me check the...  [⧉] │
│ ● 4m ago — cancelled                [⧉] │
│ ● 11m ago — target gone             [⧉] │
├─────────────────────────────────────────┤
│ ▸ Settings                              │
├─────────────────────────────────────────┤
│ Open Record              Restart        │
└─────────────────────────────────────────┘
```

**Header.** Glyph and tint per §5.2. Status line in one sentence: `Ready`, `Starting…`,
`Listening — hold ⌃ to stop`, `Recognising…`, `Typing…`, `Microphone denied`. Naming the trigger in
the status line costs one string and answers the question the user actually has. Trailing timer,
monospaced, red, ticking while recording — and dicta has a use for it that acta does not: D15's cap.
Render it as `2:41 / 10:00` and turn it amber in the last minute, so the cap stops being a surprise
that eats a dictation.

**Banners.** Red for "you cannot dictate right now": microphone denied (with a button that opens
System Settings' Privacy pane), models missing (with `Fetch Models…`, which runs
`Dicta --fetch-models` and is the one long-running action the panel owns), `agtermctl` not on PATH.
Orange, dismissible, for "the last dictation did not land": target gone, injection failed, injection
partial — carrying the same sentence the notification carried, because two different wordings for
one event is how a user learns to distrust both.

**Target line.** Only while an attempt is live: where the text is going to go, as a resolved session
name plus pane. This is D4 made visible — the one moment where seeing it early is worth anything.
The session **name** is not in §9's `Target` (which holds the id), so this is resolved live from the
tree for the active attempt only, and history rows do not show it. Do not change §9 for this.

**Primary action.** Present only while an attempt is live: `Stop and type` (red, prominent), with
`Abort` beside it as a borderless secondary. Absent — not disabled, absent — when idle, because
there is no Start (§3, rule 2).

**Recent Dictations.** The last five entries of `record.jsonl`. Dot colour by outcome: green
`injected`; orange `filter-fell-back`, `dictionary-degraded`, `injection-partial`; red
`target-gone`, `injection-failed`, `recognition-failed`, `capture-fault`, `capped`; grey `empty`,
`aborted`; and green for D29's `returned`, which did land — on its caller's stdout rather than in a
pane, and whose secondary line says `returned to caller` rather than borrowing `injected`'s wording,
because dicta cannot know what the calling script did with the text it handed over. "Delivered" is
true; "arrived somewhere the user can see it" is not established.
Primary line is `final` on one line, truncated at the tail — except for the entries where
`final` is empty and `recognised` is not, which `dicta-record-window` introduces for cancelled
attempts: those show `recognised`, are **labelled `cancelled`**, and their copy button is absent
rather than disabled, because rule 1a leaves it nothing to copy. Secondary line: relative time,
outcome, mode, and — once
`dicta-record-window` lands — `audioSeconds`. Trailing button copies to the clipboard (`doc.on.doc`)
and is the whole of the recovery story (§3, rule 1).

Clicking a row expands it in place to show `recognised` above `final` and the ids of the rules that
fired. That is step 3's misfire diagnosis without a terminal, and it is the one place the panel is
allowed to grow. It is Tier 2 in §8 — everything above it is worth having on its own.

**Settings.** A `DisclosureGroup`, closed by default, holding only what has nowhere else to live:
`Edit Dictionary…` (opens `replacements.conf` in the default editor), and, when step 4 arrives, the
one text field D9b needs for the filter command — which is what `Paths.config` has been reserved for
and what nothing reads today. Read-only facts below it: the socket path, the models directory, the
version. Nothing else. Every knob added here is a knob the CLI has to grow too.

**Footer.** `Open Record` on the left — reveals `record.jsonl` in Finder, matching acta's
`Open Archive` exactly. `Restart` on the right, per §5.1.

---

## 6. What the daemon must gain, and what it must not

Exactly one addition: **a way for a client to observe state without polling.**

The menu app cannot poll `status` at 1 Hz. `Command.isServedConcurrently` is true only for `abort`
and now `dictate`, so every `status` queues behind a running pipeline on the handler lock — the glyph
would freeze for the whole of recognition and injection, which is precisely the interval it exists
to show. It would also wake the daemon 86 400 times a day for nothing.

**Proposal: a `watch` verb, mirroring the one `acta` already has** on `socket-transport` —
long-lived connection, state pushed on every transition, coalescing to the newest state so a slow
reader is never sent a queue of stale ones. Adopting acta's semantics rather than inventing new ones
is most of the consistency argument, and it is the piece that would make a future `actactl` and
`dictactl` feel like one family.

### `watch` is a second connection shape, not a case in an enum

This is the hard part, and it is easy to mistake for a concurrency problem. `ControlServer.serve`
reads exactly one frame, hands it to a `handler` that returns exactly one `Response`, writes it, and
returns; the caller then closes the descriptor. `ControlClient.send` is documented as opening and
closing per command — "a keypress is not a session". There is no streaming path, no framing for a
second message on one connection, and every value in `ControlTimeouts.read(for:)` is sized as *how
long may one answer take*. So `watch` re-opens questions the current shape answers by construction:

- **How many watchers may exist?** Each connection is served on **its own real `Thread`** — required,
  not incidental: Darwin's non-overcommit pool is why `DispatchQueue.global()` was measured starving
  the front door. The comment justifying a thread per connection says outright that "the daemon
  serves a keypress or two a second, so a thread per connection costs nothing worth counting" — a
  premise a watcher that lives for hours breaks. One menu app is nothing; the design still owes an
  explicit bound, because today the answer is "connections are momentary" and that stops being true.
- **How does a stream end without looking like a crash?** The server deliberately never closes a
  connection silently: a client reads a close as `closedByPeer` and reports a dead daemon, which is
  why an oversized answer is refused with a short `Response` rather than a hang-up. A watch stream
  needs its own end-of-stream frame, distinguishable from that.
- **What bounds a watcher's read?** `pipelineRead` and `clientRead` both mean "one answer"; a stream
  that is idle for an hour because nobody dictated is healthy, and no existing timeout says so.

The concurrency half is real but comparatively easy, and the reasoning should be written down rather
than left to look like a loose list: `abort` was alone because every other verb begins or ends an
attempt, and two of those resolving at once is what D7 forbids. D29's `dictate` has since joined it
and is the worked example that shows the list is a **test**, not a habit; `watch` begins and ends
nothing either, so it qualifies as the third member rather than as an exception.

D29 also added an entry to `ControlTimeouts` and a case to `read(for:)`, so the stream's own timeout
lands beside a precedent rather than alone.

Publishing outside `stateLock` turns out to be the easy part: the events the UI wants map onto the
`.announce` effects, which `Daemon.apply` already performs after releasing the lock.

**A dead watcher is not an event.** The daemon drops it and does not retry.

The cheaper fallback, if the second connection shape is judged too much for what it buys: the daemon
writes a small `state.json` on every transition and the menu app watches it with a vnode source. It
needs no protocol change and it survives a dead daemon — but it puts a file write on the attempt
path, it diverges from acta, and `Paths.createPrivateDirectory`'s lesson about `Data.write(.atomic)`
landing at 0644 applies. Worth mentioning; not worth choosing.

**What the daemon must not gain:** an `NSApplication`, any AppKit UI, an `NSEvent` monitor, or any
knowledge that a UI exists. If the menu app is running, the daemon cannot tell.

---

## 7. Consistency with acta — what actually needs changing there

Very little, which is the good news. The vocabulary in §5.1 is already acta's; dicta adopts it. Two
proposals, both optional:

1. **Write the vocabulary down.** Today it is implicit in 379 lines of `ActaApp.swift`, and the two
   projects are separate repositories with no shared package, so nothing prevents drift. A short
   `docs/ui-vocabulary.md`, identical in both repos, stating the table in §5.1 plus the two
   conventions under it, is what makes "consistent" checkable by a human in a review instead of
   aspirational. This is the one edit to acta actually worth making.
2. **Optional, if the family is to be enforced rather than remembered:** acta derives its header from
   three parallel switches (`statusIcon`, `statusColor`, `statusText`). Collapsing them into a single
   pure presentation value — the way both projects already treat decisions (`D19` here, the ActaKit
   rule there) — would make the header assertable in tests in both apps, and would make a divergence
   fail rather than merely look different. Small, contained, and `acta-f3` reports
   `Sources/Acta/` is clear.

Deliberate divergences, so they are not later "fixed" into inconsistency:

| | acta | dicta | why |
|---|---|---|---|
| glyph | `waveform` | `mic` family | two items in one menu bar must be distinguishable |
| primary action | symmetric Start/Stop | **Stop only** | a click has no session to aim at (D4, D6, D22) |
| footer right | `Quit` | `Restart` | launchd `KeepAlive` makes a Quit button a lie |
| degraded screen | `UnsupportedContent` at 240 pt for macOS 14 | none | dicta needs no capture-era availability gate |
| history rows | open in Finder | copy to clipboard | dicta's artefact is text, and the UI never injects |

---

## 8. Tiers, so the scope can be cut without redesigning

- **Tier 0 — the lamp.** Menu-bar glyph per §5.2, panel with header, banners, and the footer. No
  list, no settings. This is the whole of job 1 in §2 and roughly half the value.
- **Tier 1 — the receipt.** Adds `Recent Dictations` with copy-to-clipboard, the live target line,
  and Stop/Abort. Covers jobs 2 and 3.
- **Tier 2 — the workshop.** Adds row expansion (`recognised` vs `final` vs rules fired), the
  Settings disclosure with `Edit Dictionary…`, and — with step 4 — the filter command field.

**Recommendation: Tier 0 + Tier 1 together, Tier 2 with steps 4–5.** Tier 0 alone is not enough to
justify a second bundle; Tier 2 before the filter exists is a settings panel with one row in it.

---

## 9. What the smaller answer would have been

Kept because the reversal was granted but two of these are still worth having: `doctor` is the same
readiness question the panel answers, in the surface a terminal user reaches first, and `dict --edit`
costs a line. Neither needs a UI, a second bundle or a spec change.

- **`dictactl doctor`** — one verb that answers "why is dicta not working": daemon reachable, models
  present, microphone granted, `agtermctl` on PATH, keymap snippet installed. This is job 1 in the
  surface that already exists, and it is the verb acta's future `actactl` would want too, which
  makes it a consistency win at the CLI level rather than the pixel level.
- **`dictactl last --json`** and `dictactl log -n 5` — jobs 2 and 3, in the surface `dictactl last`
  already opened. Add `--copy` to put the text on the clipboard.
- **`dictactl dict --edit`** — job 4, in one line.
- **Wording alignment** between the desktop notifications and `dictactl`'s stderr, so one event has
  one sentence.

This is the smaller, safer answer, and it is not a bad one.

---

## 10. What must be measured before any of this is built

In this project's tradition, the things that would otherwise be assumed:

1. **Does a `MenuBarExtra` status item appear at all when its app is started by a `gui/$UID`
   LaunchAgent?** Expected yes; nobody here has seen it.
2. **Does the panel opening make the menu app frontmost, and for how long does that suppress the
   push-to-talk trigger under D22?** §3 rule 5 assumes it does and accepts it; the exact behaviour
   should be observed before it is written into the spec.
3. **Cost of a `watch` connection on the daemon's transition path**, measured against the numbers
   `dicta-8f` took on `4c2ac7c` today — chord to live microphone ~95 ms, to lit indicator ~122 ms
   median over 120 attempts, p95 145 ms, worst 158 ms. Any regression there is a veto. (Those figures
   are reported here, not re-measured in this worktree; they supersede F4's 155–252 ms.)
4. **`FileHistory.entries()` parses the whole file.** The record is append-only and grows forever,
   and a panel that opens many times a day would parse all of it each time. A bounded tail reader is
   needed before any UI reads history — this is a real finding independent of whether the UI is
   built.
5. **That the daemon's TCC grant is untouched** by installing a second signed bundle beside it —
   expected, since the requirement is identity-based (measured in Task 8), but it costs one
   observation to be sure and one dialog to get wrong.

---

## 11. Spec edits this would require

Listed so the cost is visible rather than discovered:

- §13 — remove "a menu bar" from the not-in-scope list; keep "a settings window" and "a dock icon",
  both of which this proposal genuinely does not want.
- §12 — the note that the bundle has "no dock icon, no menu bar, no windows" describes the **daemon**
  and stays true; it needs one sentence saying the UI is a separate bundle.
- **D27 — the UI is a second client of the control socket, never a second face of the daemon.** The
  daemon links no AppKit UI and cannot tell whether a UI is running.
- **D28 — the UI never injects.** Recovery is the clipboard; a target is only ever captured by a
  trigger. Its structural half: the UI acts on `final` and only displays `recognised`.
- **D30 — no Start in the UI; Stop and Abort are allowed.** A click carries no session to aim at.
- §6 — one row for the menu-bar glyph, written against `dicta-cf`'s rewritten §6 rather than
  `main`'s, so it does not read as contradicting itself after the merge.
- §8 — invariants 8 and 12 extend to the menu binary; `Scripts/linkage.sh` gains its row.
- §11 and `docs/manual-checklist.md` — the glyph tracks the indicator, the panel opens without
  blanking, the fault banners appear on a machine with no models and with the microphone denied.
