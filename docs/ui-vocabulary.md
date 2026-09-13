# The menu-bar vocabulary shared by acta and dicta

**This file is a COPY.** The two projects are separate repositories with no shared package, so
nothing mechanical keeps them in step — that is precisely why the vocabulary is written down instead
of being left implicit in each app's SwiftUI. The check is a human reading both copies; the cost of
not having it is two menus in one menu bar that differ by twenty points and read as a mistake rather
than as a choice.

Its executable form in dicta is `Sources/DictaCore/Presentation.swift` and
`Sources/DictaCore/MenuModel.swift`, which are pure values the test runner drives. **When this file
and those disagree, they are what ships and this is what is wrong** — correct the document. That rule
does not turn a bug in the code into a decision: a decision is what is written down here with its
reason. In acta the same decisions live in `Sources/Acta/ActaApp.swift`, where they are three
parallel switches rather than one value; collapsing them is proposed in `docs/ui-proposal.md` §7 and
belongs to acta.

The two copies no longer read the same. acta's carries amendments recording where its panel went
after the shared reading; they are copied into this one as descriptions of acta, at the end, and
none of them asks dicta to change anything. dicta's own decisions since, including the divergences
it keeps, are in "dicta's decisions, 2026-09-13".

---

## The elements

| element | rule |
|---|---|
| container | `MenuBarExtra`, `.menuBarExtraStyle(.window)`, `LSUIElement`, no dock icon |
| panel | `.frame(width: 300)`, `.padding(12)`, `VStack(spacing: 10)`, `Divider()` between sections |
| header | tinted SF Symbol + app name `.headline` + one-line status `.caption`/`.secondary`, trailing monospaced timer while active |
| banner | icon + `.caption` text on `tint.opacity(0.12)` in a `RoundedRectangle(cornerRadius: 6)`, with an optional trailing `xmark` that dismisses it |
| colours | red = broken now, or the microphone is open; amber = landed but degraded, working, or a step the person has not taken yet; green = it worked; faint = nothing there |
| primary action | `.borderedProminent`, `.controlSize(.large)`, full-width, tinted red when it is a stop |
| list | `.caption`/`.secondary` section title, at most five rows, each a one-line primary + a `.caption2` second line + a trailing borderless icon button. **No status dot**: an ordinary outcome's second line opens with its word at `.secondary`; an exception's with a 9 pt SF Symbol and its word, both tinted; an attempt with nothing in it with its word, faint; the details follow at `.tertiary`. An empty list says so in `.caption`/`.tertiary`, and only when a read succeeded. A failed read is `Label(<failure>, systemImage: "exclamationmark.triangle")` at `.caption` in amber above the rows of the last good read |
| footer | `HStack` at `.caption`: a verb on the left, `Spacer`, an exit verb on the right |
| first frame | the view model seeds its state **synchronously** in `init`, so the panel never opens blank. A `Task` started there has not run when SwiftUI first renders |
| lazy content | **`MenuBarExtra` builds its content view only when the item is clicked.** Anything that must run at launch cannot hang off the panel. Both apps hit this and solved it differently — acta with an `NSApplicationDelegateAdaptor` (`applicationDidFinishLaunching`), dicta by putting the subscription on the menu-bar **label**, which is the one view that always exists |

Two rows are **not adopted by dicta and are not divergences to fix**:

- **The `settings` `DisclosureGroup`** (`Label("Settings", systemImage: "gearshape").font(.caption)`,
  in which acta had archive path, segment length and a checkbox) is Tier 2 and waits for the external
  filter, since a settings panel with one row in it is worse than none. acta has since replaced it
  with a Settings window (its 2026-09-12 amendment); dicta adopts neither yet.
- **The `DEV` tag and the build revision.** At the shared reading acta put the tag beside the glyph
  and the revision under the app name in `.caption2`/`.tertiary`; since its 2026-09-12 amendment the
  revision sits on its utility line. Either way it belongs to an app launched by hand, while dicta's
  menu is a LaunchAgent with exactly one installed copy. And the menu can read only its own bundle's
  revision, while `Restart` restarts the daemon's, which can be a different build: showing one would
  state which build is running and be wrong about the process that matters. A daemon revision needs
  a new snapshot field on the wire, not worth adding until build confusion actually happens.

**Every row above was checked against `Sources/Acta/ActaApp.swift` and `ControlViewModel.swift` on
`socket-transport` on 2026-08-24, not copied from `docs/ui-proposal.md`.** That check paid for
itself immediately: dicta had shipped its primary action without `.controlSize(.large)`, which is
precisely the drift this file exists to catch and which a proposal written before either app could
not have caught. The `list` row was re-read against dicta's `RecentDictations.swift` on 2026-09-13,
when both apps had dropped the dot.

---

## The two conventions

Neither is code. Both are rules about what may exist at all, and both were learned from something
already built.

**A control that cannot do what it says must not exist.** This is why the footers differ. acta has
`Quit`, because quitting acta quits it. dicta has no `Quit`: the daemon's LaunchAgent has `KeepAlive`
and launchd would restart it within ten seconds, so the button would be a lie told once per click.
dicta's right-hand footer verb is `Restart` (`launchctl kickstart -k`), which is honest and is also
the thing you want immediately after `--fetch-models`.

The same rule is what makes dicta's Stop and Abort **absent** when idle rather than greyed out. A
disabled `Stop` invites the question "why is the Start next to it disabled too", and the answer is
that there is no Start and cannot be one — a click carries no session to aim at (D30).

**Every app in the family owns one glyph and keeps it.** acta keeps `waveform`; dicta takes the
`mic` family. Two items in one menu bar must be distinguishable **by shape, not by position**,
because position is whatever the user's other menu items make it. Observed together on 2026-08-23
and they are distinguishable at a glance, which is the only test this rule has.

---

## Deliberate divergences

Written down so they are not later "fixed" into inconsistency.

| | acta | dicta | why |
|---|---|---|---|
| glyph | `waveform` | `mic` family | two items in one menu bar must be distinguishable by shape |
| menu-bar item | glyph alone | glyph **plus a running clock** while the microphone is open | measured: a glyph that changes only its fill is not legible without being looked at, and macOS's own microphone indicator says "some app", not "dicta" (SPEC.md F9). The clock changes the item's width, which is the change peripheral vision reads |
| primary action | symmetric Start/Stop | **Stop and Abort only** | a click has no session to aim at (D4, D22, D30) |
| header status line | none since 2026-09-12: one line, the sentence kept only as the tile's accessibility label | **kept**: the status line under the name, at `.caption`/`.secondary` | acta dropped its sentence because "Ready to record" repeated the Start button under it. dicta has no Start (D30), so its line repeats nothing, and "Recognising…", "Typing…" and the daemon-link states are said nowhere else on the panel |
| footer right | `Quit` (a quiet verb on the utility line since 2026-09-12) | `Restart`, and **no Quit** | launchd `KeepAlive` makes a Quit button a lie (the first convention above) |
| footer left | one verb | `Open Record` and `Set Up…` | the setup window opens by itself only at the first snapshot of a launch, so it needs a door that is always there (D27) |
| setup window | none | an AppKit `NSWindow`, 440 pt, a checklist of status glyphs, no default button | the one window dicta opens; a SwiftUI `Window` scene beside a `MenuBarExtra` may open or be restored unasked, and a Return meant for another app must not make the choice (D27, D31) |
| degraded screen | `UnsupportedContent` at 240 pt for macOS 14 | none | dicta needs no capture-era availability gate |
| history rows | open in Finder | copy to clipboard | dicta's artefact is text, and the UI never injects (D28) |
| a row with nothing delivered | — | shows what was HEARD, in italic, and has **no copy button at all** | D28's structural half: the clipboard is loaded from `final` and never from `recognised`, so a row that produced no `final` has nothing for a button to carry |
| row primary line | `.caption` (a folder name) | `.callout` (a sentence of dictated speech) | the row's content is what has to be read, not merely recognised — a dictation you are trying to find again is prose, and a folder name is a label |
| the ordinary row's word | none: a `saved` recording's second line is its stamp alone | **kept**, untinted and unmarked: `typed`, `returned to caller` | acta's rule, "the ordinary is quiet", applied to a domain with two ordinary states. acta has one, so a word would say nothing; dicta's two say different things about where the text went |
| dismissible banners | yes — the recovery notice carries an `xmark`, and two banners can be up at once | none, and only ever one | every banner dicta can raise is a CURRENT condition — no daemon, no models, no microphone — so dismissing one would hide something still true and it would come straight back. acta's recovery notice is about something that already happened, which is dismissible in a way a live fault is not |
| a control that is busy | present and **disabled** — `Starting…`, `Saving…` | absent | not a contradiction of the convention below: acta's disabled button is a *state display* occupying the place its control will return to, while dicta has no idle-state control to grey out in the first place |
| where the state comes from | the app **is** the daemon | a `watch` stream from a separate daemon | dicta's UI is a second client of the control socket and the daemon holds no reference to it (D27); acta's menu has no equivalent of "the daemon is not running" because for acta that state is "the app is not running" |
| where the view model lives | `ActaRuntime`, importing SwiftUI, over the in-process `ControlAPI` | `DictaMenuKit`, a menu-only library importing Foundation and Combine, over `MenuWorld` | forced by a dependency: `DictaRuntime` is the daemon's and links FluidAudio and AVFoundation, which the menu may not link (D27). The principle is acta's — the view model is real and only the lowest seam is fake — and `MenuWorld` is a struct of closures because dicta's menu has no in-process controller for a facade to wrap |

---

## dicta's decisions, 2026-09-13

Taken with acta's `dev` branch open beside dicta's, under one rule for every question the two apps
share: take acta's approach, or take another and file the same change in acta's backlog. Each
difference that remains is in the table above with the dependency or domain fact that forces it —
the ordinary row's word, and where the view model lives. No acta backlog item was needed.

- **Quiet outcome markers, as acta's list.** The dot column is gone. The marker is `DictaCore`'s
  decision, `AttemptOutcome.marker`, worked out from `AttemptOutcome.tint` so the two cannot
  disagree: no marker for `injected` and `returned`; faint for `empty` and `aborted`, because absence
  is not failure; `exclamationmark.triangle` for the amber outcomes and `xmark.circle` for the red,
  names a person judges on the built panel. The symbol and the word come first, tinted, then the
  details, quiet, as acta draws its stamp. The reason line under a row keeps its tint.
- **A failed read of the record, as acta's inventory failure.** The amber `Label` above the list,
  saying "The record could not be read: <reason>", with the last good rows kept below it and no
  banner. "Nothing yet." is said only by a read that succeeded and found nothing; a later successful
  read clears the label. The drawer's state is `DictaCore`'s `RecentState`.
- **The setup window presented through a protocol, as acta's reminder panel.**
  `DictaMenuKit.SetupWindowPresenting` is acta's `ReminderPresenting` shape: the AppKit controller
  in `DictaMenu` adopts it, holds the view model weakly, and is attached before the stream starts,
  in acta's order (`MenuRoot`).
- **Kept divergences, restated rather than re-decided:** the header status line, no Quit, and no
  build revision — the first two in the table above, the third in the rows not adopted.

Not decided here, and so not divergences yet: grouping by distance instead of rules, a tile behind
the header glyph, and type levels. They wait to be judged on the built panel
(`docs/backlog/menu-panel-visual-review.md`).

---

## The one rule that is not about pixels

**The daemon cannot tell whether a UI is running, and nothing about a dictation depends on it**
(D27). The menu app links `DictaCore`, `DictaIPC`, `DictaRecord` and `DictaMenuKit` plus SwiftUI —
the same budget `dictactl` has, one target wider, since `DictaMenuKit` is a library over those same
three linked statically into the one binary — and it opens no microphone and loads no model. With it
absent, quit or crashed, every dictation behaves identically. That is what makes the strip a
*display* of dicta rather than a *part* of it, and it is asserted by `Scripts/linkage.sh` rather than
by any test, because it is a property of what the binary is linked against (SPEC.md §8, invariants 8
and 11).

---

## acta's amendments

Copied from acta's copy of this file on its `dev` branch on 2026-09-13, where there were three.
They describe acta. **None of them asks dicta to change anything**, and copying them here adopts
none of their design; paths are acta's unless they say otherwise.

### acta, 2026-09-11: what the microphone merge changed under the shared rows

`socket-transport` and the microphone-priority line were merged on this date, and the shared rows
were read off acta's menu **before** the microphone work existed. By the file's own rule — the code
ships and the document is what is wrong — these are corrections to the description of acta, not
proposals.

- **`ControlViewModel` moved** from `Sources/Acta/` to `Sources/ActaRuntime/`. It is not a view; it
  is the `ControlAPI` adapter, and while it lived in the executable target no test could reach it.
  Four defects were found in it the day it became importable. The `first frame` row still describes
  what it does — only its path changed.
- **A second `DisclosureGroup`.** The panel carries a collapsed **Microphone** section beside the
  `settings` one. Its label is a two-line `VStack`: `Text("Microphone").font(.headline)` over a
  `.caption`/`.secondary` line stating which microphone a recording would use. ⚠️ The label is a
  **projection**, not a ternary in the view: the sentence is resolved in `ControlAPI.MicrophoneStatus`
  and tested, because a user-facing string that states a fact is the one layer nothing checks.
- **The `list` row's "at most five rows" does not hold for this section.** The microphone chooser is
  a self-sizing `ScrollView` bounded at 320 pt (`MenuContent.chooserMaxHeight`), because the device
  count is the machine's to decide and a menu that runs off the bottom of the screen cannot be
  clicked. ⚠️ A `ScrollView` is greedy along its scroll axis, so the section is measured with a
  `PreferenceKey` and the measurement is turned into a frame by `ActaKit.BoundedSectionLayout` — a
  **collapsed** disclosure reports zero, and a zero stored as a height is a latch that makes the
  section open empty and stay empty. That shipped once in acta. If dicta ever grows a bounded
  self-sizing section, this is the trap.
- **The shared rows were not otherwise re-derived** for acta at that point: everything else about
  acta dated from the 2026-08-24 reading.

### acta, 2026-09-12: acta's panel diverges on five rows, deliberately

acta's panel was redesigned after a measured reading of what it looked like on screen. Three
mock-ups were put to acta's user and variant A — "quiet", the idiom of Apple's own menu extras — was
chosen. Every row below is a divergence acta owns, not a correction to the shared vocabulary.

What the reading measured: on macOS `.caption` and `.caption2` are **the same 10 pt**, differing
only in colour, so a hierarchy the code expressed in four styles had three levels on screen;
`.headline` is 13 pt bold, which made the app's own name and a subsection heading the same rank; and
the panel carried **five `Divider()`s at an identical 10 pt step**, which is the same as having no
grouping at all.

- **`panel`: no `VStack(spacing: 10)`, and one `Divider()` rather than five.** Grouping is by
  distance — 6 pt inside a group, 16 pt between — as Apple's own menu extras (Wi-Fi, Sound, Now
  Playing) do; they carry no rules at all. The one surviving rule sits above the utility line, where
  what follows is not another group but a different kind of thing. ⚠️ **The cost is real**: a wrong
  `spacing:` destroys the grouping silently and no test can see it. Rules are cheaper to keep right,
  which acta's copy gives as the argument for dicta keeping them.
- **`header`: one line, and no status text.** "Ready to record" sat directly above a button reading
  "Start Recording" — the same sentence twice, where the eye lands first. The glyph became a 22 pt
  tinted tile, the name lost the flavour suffix in favour of a `DEV` capsule beside it, and the timer
  still sits at the trailing edge while recording. The status sentence survives as the tile's
  **accessibility label**, because a reader that cannot see a red tile and a running timer needs it.
- **`list`: no status `Circle`.** The dot marked the *ordinary* — every saved recording had one — so
  the eye learned to ignore it, and a recovered or unfinished recording sat in the same field of dots
  with only a hue to distinguish it. Now the ordinary is silent and the exceptions carry **a symbol
  and a word**, which also survives a user who cannot tell the hues apart. The `colours` row still
  holds for what remains: red for unfinished, amber for recovered.
- **`list`: the row shows the meeting's real title.** It showed `directory.lastPathComponent` — a
  slug that repeats the date already in the folder name, truncated through the middle. The title had
  been in `info.md` since the first version and the listing never read it back (`MeetingInfo.parse`).
  The second line is `Today 20:07 · 41:12`, and **the duration appears only for a finished recording
  that measured one**: `info.md` is written at start with `duration: "00:00:00"`, and rendering that
  placeholder beside real durations would state that a recording lasted no time.
- **`footer`: replaced by a utility line.** "Open Archive" and "Quit" were two bordered buttons of
  equal weight — a frequent, harmless action and a rare, destructive one. "Open Archive" moved to the
  header of the list it is about; "Quit" is a quiet verb paired with the build revision, which also
  moved there out of the header.
- **The `settings` `DisclosureGroup` is gone from acta.** Configuration lives in a real Settings
  window (⌘,) reached by one row.

### acta, 2026-09-12: the reminder panel, and the one prompt in it that acts

acta raises prompts in a floating panel of its own (`Sources/Acta/ReminderPanel.swift`), outside the
menu. dicta has no equivalent; it is written down because the panel reuses this vocabulary and the
rows it bends are easy to "fix" back.

**What the panel shares with the menu.** `.frame(width: 300)`, `.padding(12)`, on `.regularMaterial`
in a 12 pt `RoundedRectangle`. Each prompt is a 24 pt tinted tile beside a `.headline` over a
`.caption`/`.secondary` line; a detail block indented 32 pt to align under the text; the
`primary action` row as written (`.borderedProminent`, `.controlSize(.large)`, full-width, red when
it is a stop); and a `.caption` `HStack` of plain-button verbs underneath, in the `footer`'s shape.
It is **not** a notification — measured: a `UNUserNotificationCenter` banner hides its buttons until
hover — and no copy may claim it respects Focus.

**The prompts.** Offer to record ("Microphone activity in Slack" — Start Recording / Not now / Never
for Slack); offer to stop when quiet ("Little audio activity" — Stop & Save / Keep Recording / Remind
me in 30 min); and, new in that amendment, **the owner-release stop offer**:

| part | what it is |
|---|---|
| tile | `mic.slash`, secondary tint |
| headline | "Slack released the microphone"; with no name, "The microphone was released" |
| second line | "Acta saw Slack stop using the microphone input. The recording will stop and save unless you keep it." — not line-limited |
| detail block | the recording's title, then "Stopping and saving in 17 s" in `.caption`/`.tertiary`, `monospacedDigit()`; the line reads the full 20 s from the first frame and starts counting only once the panel has acknowledged the prompt as on screen |
| primary action | **Stop Now**, `stop.fill`, tinted red |
| footer | **Keep Recording** alone, on the left |

Four decisions in that row set, each deliberate:

- ⚠️ **It is the only prompt that acts without a click.** When the countdown completes, the recording
  stops and saves. acta's `AGENTS.md` ("The reminders") carries that exception and its conditions;
  the other prompts' expiry still acts on nothing.
- ⚠️ **"Keep Recording", never "Cancel".** On a prompt about stopping, "Cancel" reads as cancelling
  the recording, which is a different and unbuilt action (stop and delete). The button says what it
  keeps.
- ⚠️ **No click-outside dismissal on this prompt.** On the other prompts a click elsewhere dismisses
  an offer that acts on nothing. Here a dismissal is a decline, and the person this is for clicks in
  another app within twenty seconds as a matter of course — so the two buttons are the only answers.
  The panel's 30 s lifetime is not an answer either: it never cuts a running countdown short, and an
  offer never acknowledged as on screen (a locked display) expires as not seen, to be offered afresh.
- **The copy names an observation, not an ending.** Acta saw an application let the input go; it
  never says the call, meeting or huddle ended, and a test forbids those words. Every sentence is a
  projection in `ActaKit.OwnerReleaseOfferText`, not text in the view.

⚠️ **Not verified on screen in acta**: the countdown's layout, the unbounded second line, and the
panel staying in place while the number updates once a second are human acceptance, not tests.
