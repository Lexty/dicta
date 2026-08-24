# SPEC — dicta

Voice dictation into **agterm**'s input line: hold a key, speak, let go, the text appears where you
were typing. Its first purpose is dictating prompts to Claude Code and instructions to agents
running inside agterm.

**English only, across the whole project, with no exceptions** — code, comments, documentation,
commit messages, notifications, client output, test names, and `NSMicrophoneUsageDescription`, which
macOS renders verbatim in the permission dialog. The sibling project `acta` holds the same rule for
the same reason: an exception for "user-facing" strings sounds harmless but turns every new string
into a judgement call about which side of the line it falls on, and it disarms the one mechanical
check available — `grep -rP '[\x{0400}-\x{04FF}]'` is only a gate when there is nothing legitimate
for it to find. Conversation about this project is in Russian; the repository is not.

Status: **steps 1–3 of §10 are implemented; steps 4, 5 and 6 are not.** The delivery path, the
microphone, the signed bundle the TCC grant attaches to, the warm Parakeet recogniser, the
append-only record and the Tier 0 replacement dictionary all exist and are tested; the `Filter` seam
ships as a pass-through and nothing invokes a subprocess (D9c). What steps 1–3 still owe is the part
only a person can score — the chords in a real pane, the TCC prompt, §10's criteria (a)–(d) and the
deliberate misfire — listed with its pass condition in `docs/manual-checklist.md`. Build and
operating instructions are in `README.md`; `CLAUDE.md` is the operating manual.

An earlier step-1 skeleton was built, measured, verified end to end, then deliberately deleted; it
survives in git as commit `3dda6cb` and is cited below only where it produced a measurement.

---

## 1. What it is, and what it is not

dicta is a reflex, not an application. Hold, speak, let go, the words are there.

**Not** a meeting transcriber (that is `acta`). **Not** voice control of the computer — no "open
Safari". **Not** a speech-to-shell-command translator. **Not** a cloud service, an account, or a
window with forty checkboxes.

### The three properties it is answerable for

1. **Immediacy.** Models are loaded and warm before the chord is pressed. A keypress initialises
   nothing.
2. **Nothing is lost silently.** Every failure is visible, and text that was recognised is
   recoverable. The worst imaginable outcome is: dictated a paragraph, pressed stop, nothing
   happened, text gone.
3. **The text is never submitted on your behalf.** Injection does not press Return. You see what was
   recognised and decide.

The third is not a nicety. `agtermctl session type` injects real keystrokes with **no bracketed
paste**, so any newline in the text is a Return that submits the input line. A prompt dictated in
two sentences would fire off half-written.

---

## 2. Terminology

Every term below has exactly one meaning in this document. Most of the contradictions in the first
draft of this spec existed because these words carried several.

**Attempt** — one dictation, identified by a monotonic id that is never reused: hold-to-release
under D5's hold trigger, press-to-press under its toggle one. An attempt exists from the moment
recording starts, whether or not it ever produces text.

**Target** — the destination of an attempt's text: an agterm **session id** plus a **pane**. See §5
for how each half is determined and how they differ in accuracy.

### The text pipeline

An attempt's text passes through named stages, in this order and no other:

| stage | produced by | applied in raw mode? |
|---|---|---|
| **recognised** | the recogniser, verbatim | — |
| **replaced** | the Tier 0 replacement dictionary | yes |
| **filtered** | the external filter command | **no** |
| **final** | the injection sanitiser | yes |

- **raw mode** (`⌃⌥⇧D`) skips the **filtered** stage and nothing else. It is not "unsanitised" and
  it is not "unreplaced" — those readings are wrong.
- **The sanitiser is always last**, immediately before injection. It cannot sit earlier: the
  replacement dictionary and the filter are both capable of introducing a newline, and a stage that
  runs after the sanitiser could reintroduce the one hazard the sanitiser exists to remove.
- **final** is the only string that is ever injected.

### Failure vocabulary

**Capture fault** — the integrity of the audio is in doubt: sleep or audio interruption, an input
device or route change, the capture engine dying, the duration cap firing. A capture fault
**discards the audio and never injects** (D16).

**Processing failure** — capture was sound, but a later stage failed: the recogniser threw, the
filter failed or timed out, the dictionary would not load. Some processing failures are recoverable
by falling back to an earlier stage (a failed filter falls back to **replaced**); others end the
attempt without injection.

**Delivery failure** — **final** existed and injection did not complete: the target was gone, or
`session type` failed. Text is preserved (D17); it is never re-aimed (D4) and never retried
automatically.

"Fault" alone always means capture fault. A failing filter is not a fault.

---

## 3. Decisions, with the reasoning that produced them

Numbered so later work can cite them. A decision here outranks an implementation's convenience.
Where a decision states a mechanism rather than a behaviour, the mechanism is recorded in §9 as a
non-normative note instead.

**D1 — No streaming recognition. Record to a buffer, decode once on stop.**
v1 prefers one deterministic final decode over partial feedback: a single code path, no flickering
text, no rewrite-in-place logic, and no second decode whose output silently disagrees with the
first. Measured throughput (F1) is what makes that preference affordable rather than painful — a
three-minute utterance decodes in ~0.7–1.6 s. This does **not** claim streaming has no benefit; its
benefit is earlier feedback, and D13 declines that trade for v1 explicitly.

**D2 — Recording stops only on an explicit act by the user. No silence detection.**
The user deliberately pauses for several seconds to formulate, and may speak for three minutes
without a break. Any VAD or end-of-utterance heuristic would cut mid-thought. This was the user's
own call and is not open for re-litigation. The explicit act is a key **release** under D5's hold
trigger and a second **press** under its toggle one; what D2 forbids is the machine deciding that
the user has finished, not any particular gesture for saying so.

**D3 — Raw versus cleaned text is chosen by whatever STOPS the recording.**
The mode does not affect capture, so it need not be decided in advance. It selects exactly one thing
— whether the **filtered** stage runs (§2).

The hold key always stops in **clean**, because the gesture that ends the recording is releasing the
key that began it and one key cannot carry two meanings. raw therefore stays on `⌃⌥⇧D`. It stays
*reachable* from a hold, which is what keeps §2's comparison alive: the mode belongs to the command
that stops, not to the one that started, so a dictation begun by holding the key and ended by
pressing that chord comes back unfiltered. The release that follows is silent by D23.

**D4 — The target is captured at start, re-validated before injection, and never substituted.**
Wandering to another session mid-sentence must not redirect the text. If the target is gone when
text is ready, that is a delivery failure: notify, preserve the text, and do **not** aim at whatever
has focus now, because that is somebody else's agent.

**D5 — Two triggers: keymap chords that toggle, and one held key that dictates while it is down.**
The chords are `keymap.conf`'s `command "<name>" <chord> <shell...>`, which needs **no Accessibility
grant and no global event monitor**. What that mechanism cannot express is press-and-hold: it fires
on key *press* only, and it rejects a chord without a modifier. Both halves of "one key, held" are
outside it.

The hold trigger is therefore not a keymap line but a loop inside the daemon, which reads the
**state of the modifier keys** — `CGEventSource.flagsState`, 62 times a second — and treats one
modifier going down and coming back up as start and stop. This is not a keystroke monitor and the
distinction is the whole reason it is allowed: that source carries modifier state and nothing else,
so macOS asks for no permission and no character the user types is observable by dicta even in
principle (F6, F7). An earlier revision of this spec recorded press-and-hold as impossible and made
it D2's reason for a toggle. That was never measured, and when it was, it was wrong.

The keys are **right Control and right Command**, each told from its left-hand twin by the
device-dependent bit the keyboard reports (F6, F6a). Modifiers on purpose: a letter key repeats
while it is held, a modifier does not.

Two of them, because one of this user's keyboards does not have the other's key: **the laptop's
built-in keyboard has no right Control at all** (F6a), so on the machine's own keyboard the whole
gesture was not degraded but unreachable. They are one gesture and not two — whichever armed key
goes down first owns the attempt until it is released, and every other armed key is furniture until
then. The rule is not tidiness: a release that could come from a key the user is not holding would
stop and **deliver** a dictation they are still speaking, into a pane they had not finished aiming.
Right Command is not free of collisions and was chosen with them in view. `⌘V`, `⌘K` and `⌘T` are
ordinary presses that D21's floor discards; `⌘Tab` is the one gesture that holds it past the floor,
and held with the right hand inside agterm it costs an attempt with no text in it — never an
injection somewhere else, because D22 read frontmost at the press.

**D6 — Session identity comes from the keypress; the pane is resolved from live focus.**
The installed agterm build does not export `$AGT_PANE` (F3), so the pane cannot come from the
keypress the way the session id can. See §5 for the exact consequence: the two halves of the target
have different accuracy, and the spec states which. If live focus does not name exactly one
recognisable pane, **fail closed** and refuse to start — defaulting to `left` would be D4's
forbidden guess wearing a different hat.

**D7 — Start-or-stop is decided inside the daemon, atomically.**
The natural keymap line, `status | grep idle && start || stop`, is two round trips with a window
between them in which the duration cap can fire or a second chord can land — so one keypress could
both start and stop. The chords call a single toggle verb instead.

**D8 — **final** is a single line.**
This makes the newline hazard structurally impossible rather than a matter of discipline. Multi-line
output would need `session paste` (bracketed paste, no auto-submit) at the cost of going through
NSPasteboard; not in v1.

**D9 — Post-processing is two tiers.** Three separable claims:
- **D9a — Tier 0 is an ordered, user-editable replacement dictionary, always applied** (both modes).
  It fixes technical jargon — the thing every recogniser mangles in Russian and an LLM guesses at,
  because it does not know this user's vocabulary. Its matching semantics (case-insensitive,
  word-boundary aware) are chosen so that a human editing the file can predict what a rule will do,
  not because a measurement demanded them.
- **D9b — Tier 1 is an external command**: text on stdin, text on stdout, named in one line of
  configuration. External for replaceability — the engine behind it can change without changing
  dicta.
- **D9c — v1 ships no filter configured.** The intended default was `claude -p`, which measured
  8.6–10.5 s of fixed startup overhead (F2) and is unusable on a path a human waits on. The user
  chose to pick a replacement after seeing real recogniser output rather than guess now. F2 supports
  only this claim — it does not by itself decide D9b.

**D10 — Recognition is Parakeet TDT 0.6B v3 on CoreML/ANE, via FluidAudio.**
25 European languages including Russian with automatic language identification, so Russian/English
code-mixing needs no switch. It emits punctuation and capitalisation itself, which narrows what D9a
has to do. The normative requirement is that **no model loads on the hot path**; the mechanism is in
§9. Runner-up rejected: Apple `SpeechAnalyzer` — zero dependencies but 150–400 ms against ~80 ms,
and Whisper-tier accuracy. It remains the natural fallback behind the recognition seam.

**D11 — The daemon owns a stable signed bundle identity; the keypress client never opens the
microphone.**
The microphone TCC grant attaches to a signed bundle identity; a bare executable would have the
grant attributed to its parent terminal, and a second binary opening the device would fracture the
grant. The daemon runs for the user's session, not the system: it needs the user's audio session,
TCC, socket and agterm context.

**D12 — The keypress client's cold start is a budgeted property.**
It runs on every chord and must not link the capture stack. This is normative as a budget (F4, §7);
how the code is arranged to achieve it is in §9.

**D13 — Feedback in v1 is agterm's own status indicator plus sounds. No GUI, no partial text.**
`agtermctl session status` gives colour, shape, blink and sound per session; the system's orange
microphone dot is independent confirmation that capture is real. **The sound and indicator fire only
after capture confirms it is running** — announcing at keypress trains the user to speak before
audio flows and lose the first syllable every time.

**D14 — Audio lives in memory. None of `acta`'s crash-safety machinery is reused.**
Ten minutes at 16 kHz mono float is ~38 MB. Losing an utterance costs one keypress, not a meeting,
so there is no segmentation, no disk journal and no recovery pass for *audio*. Recovery of *text* is
D17's job.

**D15 — The duration cap ends the attempt and never injects.**
Ten minutes of forgotten, unrelated speech landing in an agent's prompt is worse than losing it. The
cap is a capture fault, so §2's rule applies; the recognised text, if any was produced, is still
logged.

**D16 — A capture fault never injects.** *(Amended by D26: the audio is no longer thrown away, but
it never reaches a terminal. The injection half is the half that mattered.)*
The audio boundary is in doubt, so the recording dies rather than being guessed at. Bridging input
devices seamlessly is explicitly not a goal.

**D17 — Every attempt is recorded locally, with whatever text stages it reached.**
This is not logging for its own sake; it is the only route by which text survives the failures that
otherwise eat it. An attempt that never reached recognition logs its outcome and reason with no text
— that is not a gap, it is the honest record. See §6 for the exact contents.

**D18 — Tests run through a dedicated runner, never `swift test`.**
Under Command Line Tools only, `swift test` compiles the test bundle but cannot execute it (no
`xctest` host utility), so a failing test still exits 0. A test target may exist as a compile-only
stub but must contain no assertions — one there would report as passing while never having run.
Inherited from `acta`, where it was learned the hard way.

**D19 — A decision is a pure value; only its performance touches the world.**
The lifecycle state machine, the sanitiser and the replacement engine are pure and are what the
tests drive. Capture, recognition, filtering and injection sit behind seams with fakes, so the whole
lifecycle is drivable with no microphone, no model and no terminal.

**D20 — Cancellation is refused once injection has begun.**
Keystrokes already in the terminal cannot be recalled. Reporting a cancellation the user then
watches being contradicted on screen would break property 2 more thoroughly than the failure it was
trying to describe.

**D21 — A hold shorter than the floor delivers nothing.**
A hold key is a real modifier, so any combination the user types with one — `⌃C`, `⌘V` — is
indistinguishable from a very short dictation to a source that sees modifier state and nothing else
(D5). Duration is the only thing that separates them, and the two populations do not overlap: an
ordinary press measures 90–150 ms on the external keyboard (F6) and 86–195 ms on the built-in one
(F6a), a dictation is a person speaking. The floor is **not** twice the longest press any more —
F6a's 195 ms took that margin away — but 105 ms of clearance over the worst press yet seen, against
a gesture measured in seconds, is separation and not a coincidence. A hold under
the floor therefore ends in `abort` rather than `stop` — the microphone opens for a moment and the
attempt dies with no text, no injection and no sound. The floor is **not** a delay before recording
begins: waiting it out would spend 300 ms of F4's budget on every real dictation in order to defend
against a case that produces no text anyway.

**D22 — The hold key does nothing unless agterm is the frontmost application.**
A chord carries `$AGT_SESSION_ID` because agterm expanded it at the keypress; a global key carries
nothing, so the session has to come from live focus — and live focus only means something while the
user is looking at agterm. Holding the key in a browser would otherwise aim a dictation at whichever
session agterm last had active, which is D4's forbidden substitution arriving through a new door.
The frontmost application is read from `NSWorkspace.frontmostApplication` and matched on its
**bundle identifier**, `com.umputun.agterm` — and the daemon must hold an observer on
`NSWorkspace.didActivateApplicationNotification` for that reading to be live at all (F8a). Without
one the value freezes at start-up, which is not a degraded answer but a confidently wrong one. `CGWindowListCopyWindowInfo` answers the same question
without AppKit and was measured to agree (F8), but it answers it by proxy — the owner of the topmost
layer-0 window — and it can only be matched on a display name. D22 asks which application is
active, and `NSWorkspace` is the API that answers exactly that. Not frontmost is a **silent** no-op
and not a rejection: the key means nothing there, and §6's rule is that a no-op is silent.

**D23 — The hold key names the attempt it started, on the command that ends it.**
The two triggers can be mixed inside one dictation — begin by holding, stop with `⌃⌥⇧D` to get raw
(D3) — and the key is then released into a daemon that is already idle. A bare `stop` there is
"nothing to stop": audible, and false. Carrying the attempt id from the `start` response turns it
into §6's no-op naming a spent attempt instead — silent, which is what actually happened.
**D24 — A dictation does not begin while agterm's own picker is open.**
D22 asks whether agterm is in front. It does not ask whether the thing in front is somewhere text
can go, and the native picker is the case where those differ: it is agterm's own window, so a held
key passes D22 and then delivers into the terminal **behind** the dialog — not where the user is
looking, and with nothing on screen to say it went elsewhere. The tree names the pending picker
(`pickPending`, window-scoped exactly as the tree is), so this costs nothing beyond the read that
was happening anyway.

A rejection, not a silent no-op, and the difference is intent: holding the key in front of a dialog
means the user meant to dictate **into** it. §6's silence is for a key that meant nothing (D22).
Refusing **before capture** is the part that matters most — refusing after would leave a lit
microphone recording for a pane nobody can see.

Typing into the picker is not something dicta can do today, and not for want of trying: `agtermctl
pick` sets a query only when it *opens* the picker, and nothing sets the query of one already open.
That is an agterm capability rather than a dicta one. Until it exists this is a refusal; when it
exists, this decision becomes the place the delivery is described instead.

**D25 — The record carries the speech window, not only the moment the line was written.**
`at` is when the entry reached the file: after recognition, before injection (invariant 10). It
therefore locates neither the start of the speaking nor its length, and neither is recoverable from
anything else in the record — so an attempt that produced no text at all leaves an entry that cannot
be placed in time.

That matters outside dicta. The sibling project `acta` records meetings, and dictation spoken while
a meeting is being recorded lands in the meeting's own audio and comes back in the transcript as a
remark made to the room. Correlating the two needs the interval the microphone was collecting, and
the useful case is exactly the one `at` serves worst: `aborted`, `empty` and `capture-fault` carry
no text to match on, so the window is the only evidence there is.

Three fields rather than two, and `audioSeconds` is not redundant with the pair. A buffer's length
cannot be moved by the machine sleeping mid-attempt and two wall-clock stamps can, so the two
disagreeing is itself the signal that the clock moved — a wrong answer that announces itself rather
than one that does not.

**Absent is a state, not a gap.** An attempt cancelled while `warming` never had audio, and writing
a fabricated window would put an invented moment into a file another tool correlates against a
recording. The three fields ride on the daemon's per-attempt draft rather than being passed to the
writer, and that is what makes §9's superseding line carry them too: there is exactly one place a
line reaches the record, and it reads them off the draft.

`speechStartedAt` is capture's own confirmation — the same instant D13 gates its announcement on —
and deliberately not the keypress, which precedes it by however long the audio engine takes to
start.

**What would break the end, and it is not what it looks like.** An attempt that ends while the
microphone is still collecting is told to discard *after* its line has been written, so its end has
to be resolved at write time or it can never be filled in at all. That makes the whole `aborted` /
`capture-fault` / `capped` class depend on capture's teardown staying **synchronous with the
ending**. The obvious optimisation on that path is to defer teardown, or make it asynchronous, to
get an engine rebuild off the ending — and that would move `engine.stop()`, and with it the moment
collecting actually ends, to after the record line was written. The end would then be a timestamp
for something that had not happened yet. Preparing the next engine so that it *overlaps* a teardown
which was going to block anyway is the version of that optimisation which is safe, because it
changes nothing about when the stop happens.

The consequence of resolving it at write time is worth stating rather than discovering: for that
class `speechEndedAt` equals `at` exactly, because both come from the same reading of the clock. It
is therefore slightly late — by the cost of the discard — and never early. A reader must not use the
two differing as a way to tell that class from a drained attempt; the presence of `audioSeconds` is
what distinguishes them.

**D26 — Speech that was captured is written down, even when the attempt delivered nothing.**
An attempt that ends after the microphone opened — an **abort**, or D15's **cap** — used to throw
its buffer away unrecognised, so it left an entry with no words in it at all. It is now recognised,
and the text is stored as §9's `recognised`. It is **never injected**, and `final` stays empty.

The reasoning, because this reverses a decision written in the user's own words ("the user asked for
that dictation to be dropped"). What an abort cancels is the **delivery**. The speaking already
happened, aloud, into an open microphone — and anything else listening to the room has it. The
sibling project `acta` is the concrete case: dictation spoken while a meeting is being recorded
lands in the meeting's own audio and comes back in the transcript as a remark made to the room.
Refusing to write the words down does not unmake them; it only makes them **unattributable**, which
is the harm rather than the protection. With the text, the same speech is matched word-for-word and
marked as what it was.

The price is real and was accepted deliberately: the record now accumulates text the user chose not
to send, and an abort is no longer a gesture that leaves no words anywhere. That is why this is a
decision with reasoning rather than an implementation detail. The record is `0600` inside a `0700`
directory and already holds every other thing said to this machine, so no new class of secret
appears — but a new *kind* of entry does.

**No injection, structurally rather than by routing.** The effect is emitted only by `cancel`, which
has already moved the phase to `.idle`, and the recognition it triggers never calls `apply` at all.
There is therefore no transition that could produce an `.inject` effect and no live attempt for one
to aim at — the text cannot be delivered because no state exists to carry it, not because a branch
declines to. `dictactl last` answers off `final`, so a cancelled dictation reads as "produced no
final text (aborted)" rather than as something to re-send; `--recognised` shows it, which is
diagnosis and not delivery (§9).

**A device-raised `capture-fault` produces no text, and that is D16 still working.** This decision
does not reach it, and an earlier draft of this paragraph said it did — wrongly, and in a way no
test would have contradicted. When a fault has been recorded against a recording, the capture layer
answers a drain with that fault **even with a full buffer in hand**, deliberately: the audio's
boundary is in doubt, so it dies rather than being guessed at. Usually the drain does not get that
far at all, because the fault's own thread has already taken the recording. So the class D26 covers
is the two outcomes whose buffers are clean — an abort, where nothing is wrong with the audio and
the user simply changed their mind, and the cap, which is a daemon-side decision that never marks
the recording at all.

The effect is still emitted on the fault path, and that is not an oversight: it costs nothing, and
if the capture layer ever chose to hand over what it had, this decision says that text belongs in
the record. Nonsense in a journal is a line a reader can dismiss; what D16 forbids is nonsense
reaching a terminal, and that is untouched either way. What must not happen again is a sentence here
promising words that the layer below deliberately drops.

**Nothing is journalled that never existed.** An attempt cancelled while `warming` has no buffer:
the device never confirmed. It writes no text and no speech window, as before (D25).

**D27 — The UI is a second client of the control socket, never a second face of the daemon.**
dicta gets a menu-bar item. It lives in its own signed bundle, speaks the control socket like
`dictactl` does, and the daemon cannot tell whether it is running.

This reverses part of §13, which listed a menu bar as out of scope on D11's authority. D11 is about
the microphone TCC grant — it attaches to a signed bundle identity, a bare executable would have it
attributed to the launching terminal, and a second binary opening the device would fracture it.
None of that is about pixels. The inference to "no menu bar" held while the bundle existed *only* as
a TCC anchor; it never covered a second bundle that opens no microphone, which is the position
`dictactl` has occupied since D12. A settings window and a dock icon stay out of scope.

**Putting the menu inside the daemon was refused, for three measured reasons rather than a
preference.** Invariant 11 is enforced by reading the built `Dicta` binary for `CGEventTapCreate`,
`CGEventTapEnable`, `IOHIDManager` and `_OBJC_CLASS_$_NSEvent`, and a SwiftUI status item drags the
last of those in unavoidably — the gate exists so macOS never starts demanding Input Monitoring for
a tool that asks for no permission at all, and a menu is a bad reason to weaken it. F6 and F8a were
measured in a process with **no `NSApplication`**, and D22's frontmost check rests on both;
introducing one changes the shape those measurements describe. And the smallest daemon is the one
whose grant is easiest to reason about.

**The UI's absence changes no outcome.** Not installed, quit, crashed, never built: every dictation
behaves identically. Nothing the daemon does for an attempt may wait on it, which is what makes the
separation structural rather than a promise — the daemon has no reference to hold.

**D28 — The UI never injects.**
There is no "send this again" anywhere in it. Recovery of text that did not land is the clipboard,
and the user pastes where they meant to. A target is captured by a trigger and by nothing else
(D4, D6): a click carries no `$AGT_SESSION_ID`, so a UI that aimed text somewhere would be
performing exactly the substitution D4 forbids, with a friendlier button on it.

**The structural half, which is what makes this hold without vigilance:** the UI acts on `final` and
only ever displays `recognised`. A row whose `final` is empty has nothing to give, so a cancelled
attempt — which carries `recognised` with an empty `final` (D26) — offers nothing, with no rule for
anyone to remember. `dictactl last` already answers off `final` for the same reason.

**The limit of that, stated because it is easy to over-claim.** `final` separates attempts that
produced text from attempts that did not. It says nothing about **where** the text went, so it does
not distinguish `returned` (D29) from `injected` — both are full. That is safe here only because
the previous paragraph leaves exactly one affordance, and copying text the user dictated is harmless
wherever it went. Reason from the field, not from the outcome's name; an outcome needing different
treatment needs a check on the outcome.

**D29 — A caller can claim the next dictation's text instead of a pane getting it.**
`dictactl dictate` blocks, the user dictates exactly as always, and the text is printed on **stdout**
rather than typed anywhere. `PROMPT=$(dictactl dictate)` is the whole interface.

It exists because of a gap that is not dicta's to close from the inside. agterm's native picker —
the dialog the user's own custom commands open to collect a line — is a text field and not a
terminal surface, so `session type` cannot reach it, and `pick --query` sets the query only at the
moment the picker opens. There is no verb for "put this text into the picker that is already open".
Asking agterm for one was considered and declined; the gap is closed here instead. A dictation aimed
at a dialog therefore has to arrive **before** the dialog does, which means coming back to the
script rather than going into a pane.

**`returned`, never `injected`** (§9). No keystroke is sent and no input line is touched, and a
record saying otherwise would be lying about the one thing it exists to be trusted on. Everything
else about the attempt is unchanged: the dictionary runs, the filter runs in `clean`, and the
sanitiser still runs last — the text is about to become another program's argument, and a newline
there is a hazard in a different shape rather than no hazard.

**stdout is data.** A timeout or a refusal goes to stderr and shows up as an exit code, never as a
line of prose on stdout. Not tidiness: the output is spliced straight into a shell variable and from
there into another program's argument, where a friendly "nobody dictated anything" does not read as
an error — it reads as the thing the user said.

**One claim at a time.** Two scripts each expecting "the next thing the user says" cannot both be
right, and the second is refused rather than silently handed the other's sentence.

**Bounded.** A script that asked and was then ignored must not wait for ever, or the user's chord
appears to have wedged and the only way out is to find the process.

**Served concurrently, and it must be** (§6). It waits for a person to speak, and the `start` and
`stop` that produce what it is waiting for run through the same handler. Held under that lock it
would be waiting for an event it was itself preventing — a deadlock, not a slowdown. It qualifies on
the same grounds `abort` does, and on one more: it neither begins an attempt nor ends one.

**It is what lifts D24's refusal.** That rule refuses to start in front of an open picker because
the words would land in the pane behind it. With a caller waiting they have somewhere else to go, so
the refusal has nothing left to protect — the exception is D24 answered rather than overridden.

**D30 — The UI has no Start. Stop and Abort are allowed, and the asymmetry is the point.**
A live attempt already owns a target, captured by the trigger that began it and never substituted
(D4), so ending it from a window decides nothing about where the words go. Starting one from a
window would decide exactly that, and has nothing to decide it with.

D22 makes the same point from the other side: the hold key does nothing unless agterm is frontmost,
and a focused dicta panel is not agterm. So the panel is silent ground by construction — **the UI is
where you go between dictations, not during one.** That is accepted rather than worked around; the
menu-bar glyph, which needs no focus, is what carries the during.

The glyph obeys D13 in full: it lights when capture confirms it is running, never at the keypress.
It is driven by the same transitions as the agterm indicator, so the two cannot disagree.

---

## 4. Measured facts

Dates matter; re-measure rather than trusting these indefinitely.

**F1 — Recognition throughput: RTF ~110× (M4 Pro, FluidAudio docs) to ~250× (M3 Pro, measured in
`acta`'s lab-002).** A 15-second utterance decodes in ~60–140 ms; three minutes in ~0.7–1.6 s.
Russian WER measured at 0.210 in `acta`, against whisper-turbo's 0.316.

**F2 — `claude -p` costs 8.6–10.5 s of fixed startup per invocation.** Measured 2026-08-13 on this
machine, Haiku, one short sentence: 10.56 s naive, 8.63 s with `--tools "" --strict-mcp-config`. The
cost is CLI startup (node runtime, settings/plugin/MCP loading, auth), not inference — output
quality was fine.

**F3 — The installed agterm does not export `$AGT_PANE` to custom keymap commands.** Its own
`keymap.conf` header lists what is available: `AGT_SESSION_ID`, `AGT_SESSION_NAME`,
`AGT_SESSION_PWD`, `AGT_WORKSPACE_ID`, `AGT_WORKSPACE_NAME`, `AGT_WINDOW_ID`, `AGT_WINDOW_NAME`,
`AGT_SELECTION`, `AGT_SOCKET`. The skill documentation describes a newer build.

**F4 — Warm keypress cost. The interval has TWO endpoints and they differ by ~35 ms, so a figure
without its endpoint is not a measurement.** Chord to a live microphone: ~95 ms. Chord to the lit
indicator, which is also what `Scripts/measure.sh` scores because it times the whole `dictactl`
invocation: median **122 ms**, p90 132, p95 145, worst of 120 attempts 158 (measured 2026-08-23 on
`4c2ac7c`, 12 runs of 10 warm attempts each).

Where the time goes, measured 2026-08-23 with per-phase instrumentation inside the installed
LaunchAgent build over 26 warm attempts (the instrumentation was reverted; the numbers are medians):

| phase | ms |
|---|---|
| `dictactl` process start + socket round trip | ~20 |
| resolving the target (`agtermctl`) | ~30 |
| `capture.begin` — `engine.start()` | ~40 |
| the "listening" indicator (`agtermctl`) | ~35 |

Two of those four are agterm subprocesses, and the indicator runs **after** the microphone is
already live — which is what splits the interval in two. D13 requires that order: nothing is
announced until capture confirms.

**Withdrawn: that the great majority of the interval is inside `capture.begin`.** This entry said so
on 2026-08-18, and it is false. `capture.begin` measured 66–80 ms of ~165 — `engine.inputNode` ~29,
`installTap` ~5, `engine.start()` ~39. Only the last has to happen while the user waits, and
`4c2ac7c` moved the other two off the chord path by building the engine in advance. That is allowed
because it was measured rather than assumed: reading
`kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input device shows `false` through
`inputNode`, `installTap` and `prepare()`, and only `engine.start()` sets it — a prepared engine
lights no microphone indicator. Holding a *started* engine warm between attempts stays refused.

The figures this entry carried before: 155–252 ms (2026-08-18, min 155.8, median 180.0, p90 229.1,
max 252.5, ten attempts out of ten over budget) for the build without a prepared engine; and, before
that, 20–70 ms measured on the deleted step-1 skeleton **whose capture was a fake**. That build never
opened the microphone, so the number described a path with its expensive part missing — and §10's
150 ms budget was calibrated against it, which is the origin of the whole discrepancy.

**Against the later endpoint the budget is still not met, but the failure is now marginal**: 9 of 12
runs had all ten attempts under 150 ms, 4 of 120 attempts were over, and those four were 153.5,
156.3, 156.6 and 157.9 — the worst case in 120 attempts exceeds the budget by 5%. Before `4c2ac7c`
the *best* attempt of ten was 152.3. Whether to move the budget, to name the earlier endpoint in
§10, or to spend one of the two remaining `agtermctl` subprocesses, is open and is the user's
decision.

**F5 — Injection into a terminal input line works and does not submit.** Verified live on the
skeleton against a fish prompt, using a deliberately hostile canned transcript containing a newline
and a double space: a single line with single spaces arrived, unsubmitted.

**F6 — Modifier-key state is readable globally by an unprivileged process, and left is told from
right.** Measured 2026-08-23 on this machine with a throwaway probe, against the user's external
keyboard. `CGEventSource.flagsState(.combinedSessionState)` reported every press and every release
with **no TCC prompt of any kind**, from a process with no window and no keyboard focus — the
keystrokes went to agterm throughout. The device-dependent bits separate the sides: right Control
`0x2000` against left Control `0x1`, right Command `0x10` against left Command `0x8`. That is what
makes D5's key usable in a terminal where `⌃C` and `⌃R` are pressed all day with the other hand.
`NSEvent.modifierFlags` reported **nothing** on the same events in the same process: AppKit's event
state is empty without an `NSApplication`, which is why D5's loop is CoreGraphics and why the daemon
needs no AppKit for it.

The same run measured the other half of D21's floor by accident, which makes it better evidence than
a designed test would have been — the user was pressing keys normally rather than performing a hold.
Every press lasted **90–150 ms** (140, 110, 90, 150, 120, …). A 300 ms floor is twice the longest of
them.

Not established by that run: the reading was never exercised with a *different* application
frontmost, and neither Caps Lock nor Fn appeared at all, so neither is a candidate key yet. F6a
answers the second half for the other keyboard, in the opposite direction.

**F6a — the laptop's built-in keyboard has no right Control key, and reports right Command `0x10`
and right Option `0x40` like the external one.** Measured 2026-08-24 with the same kind of throwaway
probe, on the built-in keyboard this time, because F6 was taken against the external one and D5's
key is the one key the built-in keyboard does not have. What the probe saw, pressed in order:

| key | flags word | device bit |
|---|---|---|
| right Command | `0x00100110` | `0x10` |
| right Option | `0x00080140` | `0x40` |
| right Shift | `0x00020104` | `0x04` |
| Fn / Globe | `0x00800100` | `0x800000` |
| left Control | `0x00040101` | `0x01` |

Three things came out of it, and only the first was the question asked. **Fn does appear on this
keyboard**, which F6 recorded as not appearing at all — so that finding was about the external
keyboard and not about macOS, and this spec had been carrying it as though it were general. It is
still not a candidate: `Fn`+arrows is Home/End and `Fn`+F-keys is every function row, so the key is
held during ordinary editing, and macOS gives it a system action of its own. Right Shift is a
candidate by bit and refused by use — a run of capitals holds it past D21's floor. And every sample
after the first press carried `0x100` (`NX_NONCOALSESCEDMASK`) whether or not any key was down,
which is the shape of noise that a watch matching a whole word rather than a bit would read as a
key.

Press durations on this keyboard, from the same run: 86, 88, 98, 118, 126, 148, 192, 195 ms — the
armed keys themselves at 126 (right Command) and 118 (right Option). D21's 300 ms floor clears all
of them, and the longest is what took away the "twice the longest press" margin F6 recorded.

The absence of right Control is the user's own report of their hardware, corroborated only
negatively here: `0x2000` never appeared in the run, and nothing was pressed that could have set
it.

**F7 — The hold loop costs about 0.03% of one core.** Measured 2026-08-23 as CPU time consumed over
a fixed wall-clock window: 1.3 ms per 5 s at a 16 ms poll interval, 2.7 ms per 5 s at 8 ms — roughly
0.9 CPU-seconds per hour at the interval D5 uses. This is process time and **not** energy: the timer
wakeup count that Apple's "Energy Impact" is computed from was not measured.

**F8 — The frontmost application is readable with no permission.** Measured 2026-08-23:
`NSWorkspace.frontmostApplication` named the app, its bundle identifier and its pid, and
`CGWindowListCopyWindowInfo` independently named the same owner and pid as the topmost layer-0
window — from the same unprivileged process, while a *third* application was frontmost, which is
what makes it a global read rather than a self-report. Only `kCGWindowName`, the window's title, is
withheld without a Screen Recording grant, and D22 does not read titles.

Unlike `NSEvent.modifierFlags` (F6), `NSWorkspace` **does** work in a process with no
`NSApplication`. What that run did **not** establish, and what its wording implied, is corrected by
F8a: a single read is always right, and it was tracking over time that had to be measured.

**F8a — `NSWorkspace.frontmostApplication`, read from a background thread, is FROZEN unless the
process has registered an observer on the workspace notification centre.** Measured 2026-08-23,
twice: first inside the installed daemon, then in a purpose-built process shaped exactly like it —
a background thread polling every 0.5 s while the main thread runs `RunLoop.main.run()` — with focus
driven through three applications by `osascript` so the sequence is repeatable rather than clicked.

| the process (every variant polls from a BACKGROUND thread) | result |
|---|---|
| no observer registered | **frozen**: one identifier for all 17 samples, across three switches |
| one read on the main thread before the run loop starts, then no observer | **frozen**, identically |
| an observer on `didActivateApplicationNotification` | **tracks every switch** |

So a main-thread run loop is **necessary and not sufficient**, and priming it with a single
main-thread read changes nothing. Without an observer the process never subscribes to the window
server's activation notifications, and the value it hands back is whatever was frontmost when it
first looked.

**Not established, and the boundary of the claim above.** Every variant measured reads from a
background thread, which is the shape dicta has and will keep — the poll loop is a real `Thread` by
construction (62 wakeups a second do not belong on the main thread, and the sender blocks for the
length of a whole dictation). A second session reports that a process whose **main** thread reads
`frontmostApplication` repeatedly *while* pumping its own run loop tracks with no observer at all.
That was not isolated and is not folded into the table. It would change the mechanism's name; it
would not change the fix, because the observer is what makes the reading correct regardless of which
thread performs it, and a fix that depended on somebody continuing to read from the right thread
would be one keystroke from silently reverting.

The failure has the worst available shape for D22: never `nil`, never obviously wrong, a plausible
bundle identifier frozen at start-up. Had that been agterm — which it is, whenever the daemon is
started from an agterm session — the hold key would have armed in **every** application, for ever,
dictating into a terminal nobody was looking at. It was found by H12 and only because H12 insisted
on sampling while a *different* application was frontmost; the obvious instrument, logging on each
chord, cannot see it, because a chord is only ever pressed inside agterm.

`CGWindowListCopyWindowInfo` tracks with no observer and is still not the answer. The same run
measured the two disagreeing: with Finder frontmost and no Finder window open, it named a different
application as the owner of the topmost layer-0 window. It answers a question next to D22's, not
D22's.

**F9 — A menu-bar glyph that changes only its FILL is not legible without being looked at, and the
system's own microphone indicator cannot stand in for it.** Observed 2026-08-24 by the user against
the installed build, which is the only instrument that could have produced it: nothing automatic can
score whether a person notices something.

Three findings, and the order matters because each one narrows what the item has to do.

1. **The panel's live half is seen by nobody.** The timer, the target line and Stop/Abort are
   drawn only while the panel is open, and during a dictation the panel is closed — the user's
   focus is in the pane they are dictating into, which is what makes the dictation possible at all.
   So the state a UI exists to show was reachable only by interrupting the activity it describes.
2. **`mic` → `mic.fill` is below the threshold of peripheral vision.** Both are the same silhouette
   at the same width, and peripheral vision reads shape and movement rather than fill. The user's
   own words: the state is distinguishable, but only on purpose, and nothing about it takes
   attention by itself. This is a measurement of the same kind as F8a — the thing looked plausible
   and was not doing its job — and it invalidates the premise `docs/ui-proposal.md` §5.2 rested on,
   that a passive always-visible glyph is 90% of this UI.
3. **macOS's own microphone indicator is ambiguous by design, and that is what makes this dicta's
   job.** It reports that *some* process holds the device, not which. With anything else on the
   machine recording — a call, a meeting, `acta` — it is lit for a reason unrelated to the attempt,
   and dictating under it is indistinguishable from not. Disambiguating that is the one thing only
   dicta's own item can do, and the failure in (2) is worst exactly there.

The answer taken is a **running clock beside the glyph while the microphone is open**, chosen over a
pulsing glyph and over a mere change of silhouette. Its legibility comes from a property the other
two lack: the item's WIDTH changes, which moves every icon to its left, and a menu bar reflowing is
a change peripheral vision reads without being asked to. It costs no animation, which matters in a
strip the user looks at all day, and it puts the timer — including D15's cap warning — where it can
be seen without opening anything.

**Whether the width change carries in practice was H22 (b), and it was scored on 2026-08-24 by the
same user, and PASSED**: the strip is noticed while working, without deciding to look at it. The
finding is therefore closed rather than merely answered, and the item stays as a regression check —
what it guards against fails silently, and no assertion can reach it.

**F9b — a watcher that attached was told nothing until the daemon's next transition.** Measured
2026-08-24 with the smallest instrument available: `dictactl watch` against a healthy idle daemon
printed not one byte for as long as it was left running. The daemon publishes on transitions, so
after a restart the menu-bar strip went on reporting the daemon as unreachable over a connection
that had been live for minutes — a lie that sustains itself, because nobody dictates at a strip
saying dicta is dead and only a dictation would have corrected it. It also pinned the reconnect
backoff at its ceiling, since the client resets that counter on a received event: 5 351 ms to
recover from a crash, against ~550 ms after the fix.

Nothing was added to the wire. The handshake `Response` already carries the snapshot, filled by the
function `status` uses so that a UI's first frame and its second cannot disagree; the client was
reading it and discarding it, and now delivers it as the stream's first `update` with no `sequence`
— which is already this protocol's word for "not a transition". This is what the last row but one of
§7 rests on, and it was false when that row was written.

**F9a — the menu app opened no connection to the daemon until its panel was first opened.**
Measured the same day, with `lsof`, and it is a defect this observation flushed out rather than a
property: `MenuBarExtra` builds its content view lazily, so a `.task` on the panel runs when
somebody clicks the item and never otherwise. A freshly launched `DictaMenu` held **0** unix
sockets; after moving the subscription to the label — the one view that always exists — it holds
**1**, and the daemon shows two descriptors on `control.sock`. Every test of the glyph had passed,
because anyone testing a panel opens the panel.

---

## 5. Target identity

The two halves of a target are **not** equally accurate, and pretending otherwise would hide a real
failure mode.

- **Session id** is keypress-accurate. agterm expands `$AGT_SESSION_ID` when the chord fires, so it
  names the session the user was in at that instant.
- **Pane** is resolved by the daemon from `agtermctl tree --json` when it handles the start command
  — the `tree` call itself measures ~10 ms (F4), and the whole start command 155–252 ms, of which
  the tree read happens near the beginning. It is therefore *focus shortly after the keypress*, not
  focus at the keypress.

The residual risk is a focus change inside that window landing the text in the sibling pane of the
right session. It is accepted rather than solved: it needs a deliberate pane switch within ~40 ms of
pressing the chord, and the alternative — trusting an environment variable that this agterm build
does not export (F3) — is unavailable. **If a newer agterm exports the pane at keypress, that
becomes the authority and this section is revised.**

Requirements that follow:

- **Under the hold trigger (D5), the session id is not keypress-accurate either.** Nothing expands
  it for the daemon, so it comes from the tree: the session marked `active` inside the workspace
  marked `active`, in the frontmost window. Both halves are then live focus shortly after the key
  went down, and D22's frontmost check is what makes that reading mean anything at all.
- **Both halves come from one READ of the tree, not two lookups.** The trigger sends a start asking
  for focus and resolves nothing itself. Asking for the session and then letting the daemon resolve
  the pane would spend a second `agtermctl` subprocess on the hot path — and, worse than the cost,
  would assemble the target out of two moments that can disagree. One read is the only way the two
  halves describe the same instant. The flag is explicit and a missing session never implies it:
  `$AGT_SESSION_ID` expands to an empty string when unset, so "no session means use focus" would
  turn a keymap line that has stopped matching the build into a chord that silently dictates
  wherever focus happens to be.
- If the tree does not name exactly one recognisable active pane for the session, the attempt does
  not start (D6).
- Both halves are re-validated before injection. A target that no longer resolves is a delivery
  failure (§2), never a re-aim (D4).

---

## 6. Interaction model

| trigger | idle | during an attempt |
|---|---|---|
| **right Control or right Command, held** | start, and record while it is down | release → clean → inject |
| `⌃⌥D` | start | stop → clean → inject |
| `⌃⌥⇧D` | start | stop → raw → inject |
| `⌃⌥X` | — | abort |

The three chords are keymap lines passing `$AGT_SESSION_ID` and `$AGT_SOCKET` to a single toggle
verb (D7). The held key is a loop inside the daemon (D5): it resolves its own target from live focus
(§5), refuses to start unless agterm is frontmost (D22), and names its own attempt on the way out
(D23). Every start path is otherwise identical, and the mode belongs to whatever stops (D3).

### States and what each command does in each

```
idle → warming → recording → processing → injecting → idle
```

`warming` is a distinct state, not an implementation detail: it is what lets D13 hold, and what lets
a client distinguish "coming up" from "ready" from "microphone denied".

| | start chord | stop chord (either) | abort |
|---|---|---|---|
| **idle** | begin attempt | rejected, "nothing to stop" | quiet no-op |
| **warming** | rejected, "already recording" | **cancel** — no audio exists yet, so nothing is delivered | cancel |
| **recording** | rejected, "already recording" | stop and deliver in the chord's mode | cancel |
| **processing** | rejected, "still working" | quiet no-op | cancel — nothing is injected |
| **injecting** | rejected, "still working" | quiet no-op | **refused** (D20) |

Rules that fall out of the table and must hold regardless of how it is read:

- A duplicated stop is a **quiet** no-op, not an error and not a second delivery: pressing stop again
  because nothing visibly happened is normal behaviour, and an alarming noise would punish it.
- A command naming a spent attempt id is a no-op. Late callbacks from an abandoned attempt — capture
  confirming readiness after an abort, recognition returning after a cancel — never resurrect it.
- A rejection is audible (`Basso`); a no-op is silent.
- A release under D21's floor ends the attempt with **abort**, not stop. Nothing is delivered and
  nothing is heard: a right-Control combination the user typed is not a dictation they are owed
  feedback about.

### Feedback

| state | indicator | sound | menu bar (D27) |
|---|---|---|---|
| listening | `active --blink`, red | `Pop` | red glyph **and a running clock**, amber inside D15's last minute |
| working | `active`, amber | — | amber glyph, no clock |
| done | `completed --auto-reset` | `Tink` | back to the quiet glyph |
| empty, faulted or refused | `blocked` + notification with the reason | `Basso` | back to the quiet glyph; the reason is in the panel and in the record, not in the strip |

**The menu-bar item cannot disagree with the indicator, and that is structural rather than
careful.** Both are driven by the same transition in the same daemon: the indicator by the effects
`Daemon.apply` performs, the item by the snapshot that same transition publishes on the `watch`
stream (D27). There is no second source for it to drift from — the UI computes no state of its own,
it draws one.

**One way to lie is left, and it belongs to the UI alone: a snapshot outliving the connection it
arrived on.** The dangerous case is the daemon dying mid-recording, where keeping the last known
state on screen leaves a red glyph and a running clock over a microphone that is not open — the UI
confidently wrong about the one thing it exists to report. It is refused rather than avoided: the
strip and the clock are both derived from the LINK first and the snapshot second, so a link that is
down draws nothing about the daemon's state. §7 carries the row and the checklist names the
assertion; the convention there is deliberate — test names are cited in one file, so a rename has
one place to rot rather than two.

Three consequences worth stating rather than leaving to be inferred:

- **D13 reaches the strip in full.** The glyph lights on `recording` and the clock starts there,
  never on the keypress — and the clock is absent through `warming` for the same reason the sound
  is, because a clock is an announcement and a user who speaks to one that started early loses the
  first syllable every time (invariant 4).
- **The clock exists because the glyph alone was not legible (F9)**, and the strip is where it
  belongs rather than the panel: during a dictation the panel is closed, because the user is looking
  at the pane they are dictating into.
- **None of this column is required for a dictation.** The menu app is a second client of the
  socket; with it absent, quit or crashed, every row of this table's first three columns behaves
  identically (D27). The indicator, not the strip, is the feedback dicta is answerable for.

---

## 7. Failure matrix

Every row states: no injection unless said otherwise, a visible reason, and what reaches the record.

| event | class | behaviour |
|---|---|---|
| filter fails, times out or returns empty | processing failure | inject **replaced** instead; notify that the filter did not run |
| recogniser throws, or the model is unavailable | processing failure | no injection; notify; record the attempt with its error and no text |
| recogniser returns nothing but whitespace | — | no injection (an empty insertion is worse than none); notify "empty" |
| recogniser returns text that is not valid UTF-8 or is longer than the frame limit | processing failure | no injection; notify; record the raw bytes' length and the error |
| replacement dictionary unreadable, unparsable, or a rule is malformed | processing failure | **skip only the offending rules**, apply the rest, and notify once that the dictionary is degraded; never block injection over a config file. An **absent** file is not a degraded one: nothing switches the dictionary on, so absence is how a user who does not want one says so, and notifying on every dictation would train them to dismiss dicta's notifications — which is the property this row exists to protect |
| a replacement produces empty text | processing failure | treat as "empty" above; the dictionary must not silently delete a dictation |
| capture fails while stopping | **capture fault** | no injection; notify as a hardware fault, explicitly *not* as silence. **No text**: the samples in hand are dropped because the audio's boundary is in doubt (D16), which D26 does not override |
| sleep, audio interruption, input device or route change | **capture fault** | no injection; notify; **no text**, for the same reason as the row above (D16) |
| duration cap reached | **capture fault** | no injection, loud notification (D15); the ten minutes are recognised into the record only, which is where forgotten speech is worth having (D26) |
| target gone at injection time | delivery failure | do not re-aim (D4); notify; text preserved |
| `session type` fails before any keystroke | delivery failure | notify; text preserved; no automatic retry |
| `session type` fails after keystrokes have begun | delivery failure | notify that the insertion **may be partial**; text preserved; **never retry** — a retry would double part of the text |
| history append fails | — | still inject if injection is otherwise safe, then notify **loudly** that recovery is unavailable, because property 2 is the thing that just broke |
| client cannot reach the daemon | — | loud local failure — desktop notification, not just stderr |
| daemon wedged during an attempt | **capture fault** | watchdog discards; no injection |
| daemon crashed leaving a stale indicator | — | reset the known target's status when the daemon next starts |
| second daemon instance attempted | — | refuse to start; a live socket means a live daemon |
| abort during injection | — | refused (D20) |
| hold key pressed while agterm is not frontmost | — | silent no-op; no attempt starts, no indicator, no sound (D22) |
| hold shorter than the floor | — | the attempt is aborted rather than stopped: no text, no injection, no sound (D21) |
| a caller waits for a dictation and nobody speaks | — | no text on stdout, the reason on stderr, and an exit code of its own; nothing is typed and no attempt is invented (D29) |
| a second caller asks for the next dictation while one is already waiting | — | refused; the first keeps its claim and the second is told why, rather than being handed somebody else's sentence (D29) |
| hold key pressed while agterm's own picker is open | — | refused **before** capture, so the microphone never opens; the reason names the picker (D24) |
| hold key released after a chord already ended the attempt | — | no-op naming a spent attempt (D23); silent |
| the active session cannot be read from the tree when the hold key goes down | — | nothing starts; notify, because the key did mean something and produced nothing |
| the hold trigger is not armed, or its source reads nothing | — | the chords are unaffected and remain the whole interface. **This failure is silent by construction and that is stated rather than hidden**: `CGEventSource.flagsState` returns a word of flags and has no error channel, so "no modifier is down" and "this is not working" are the same answer. What exists instead is a startup line naming the armed key, and `--no-hold` to turn it off deliberately |
| the user aborts after speaking | — | nothing is injected and nothing is announced as delivered; the words reach the record and only the record (D26) |
| a watcher goes away mid-stream | — | the daemon drops it and keeps serving; **no dictation outcome changes**. A UI is an observer, and an observer that vanishes is not an event the thing it was observing has to notice (D27) |
| the watcher cap is reached | — | the new watcher is refused by an ordinary short response, **never by a dropped connection** — a client reads a close as a dead daemon, which would make a healthy refusal read as a crash. The watchers already attached are untouched and **no dictation outcome changes** |
| the daemon stops or restarts under a live watcher | — | the stream is ENDED with a reason rather than dropped, so a clean shutdown is not reported as a crash; the watcher reconnects on a bounded backoff and the strip returns to truth without anybody opening the panel. **No dictation outcome changes**, because there was no attempt in flight that the UI's connection had any part in |
| the daemon dies while a watcher is showing a recording | — | the stream breaks rather than ending, which is the honest difference from the row above. The UI **drops the last snapshot** rather than keeping it on screen: a red glyph and a running clock over a microphone that is not open is the UI confidently wrong about the one thing it exists to report, and it is the only way this UI can lie on its own. The dictation was lost with the daemon; nothing about that outcome is the watcher's doing |

A failing filter must never cost the user their words; that is why **replaced** is its fallback
rather than an error.

---

## 8. Invariants

Each must hold on **every** path, and each is worth a test that fails if it stops holding.

1. **The sanitiser runs immediately before injection, on every path** — clean, raw, and the fallback
   to **replaced** after a filter failure. It is the last stage, so no later stage can reintroduce a
   newline. *(It does not apply to reading text back out of the record, which is not injection.)*
2. **final is a single line**, containing no `\n`, `\r`, `U+0085`, `U+2028` or `U+2029`.
3. **No injection into an unvalidated or substituted target** (D4, §5).
4. **Nothing is announced to the user before capture confirms it is running** (D13).
5. **A duplicated stop never delivers twice.**
6. **A capture fault never injects** (D16) — including the duration cap (D15).
7. **A capture failure is never reported as silence.**
8. **Neither the keypress client nor the menu-bar UI ever opens the microphone** (D11, D27). The
   TCC grant belongs to the daemon's signed bundle alone, and a second binary opening the device
   would fracture it. **No behavioural assertion can reach this** — it is a property of what a
   binary is LINKED against, so `Scripts/linkage.sh` is the only thing that can fail on it, and
   `Scripts/test.sh` runs it first for that reason.
9. **Recording state is released only after capture has actually been drained** — otherwise the next
   chord can start a second attempt while the first is still stopping, which with a real audio engine
   is two starts racing over one input device.
10. **Recognised text, once produced, always reaches the record** before any injection is attempted,
    so a delivery failure cannot lose it.
11. **The hold trigger reads modifier state, and no bundle dicta ships reads a key stream**
    — no key codes, no characters, no event tap, in the daemon or in the menu-bar UI. This is what
    lets D5 hold without a permission, and adding a UI is exactly when it would be lost by accident:
    a status item that watched for a shortcut would put an Input Monitoring prompt in front of a
    user this project promised would never see one. Like invariant
    8 it is a property of which API is called, so no behavioural assertion can reach it and
    `Scripts/linkage.sh` is the only thing that can fail on it — by name, on `CGEventTapCreate`,
    `CGEventTapEnable`, `IOHIDManager` and `_OBJC_CLASS_$_NSEvent`.
12. **A hold under D21's floor never injects.**
13. **The hold trigger never starts an attempt while another application is frontmost** (D22).

---

## 9. The record

One append-only local file, one entry per attempt, written before injection is attempted
(invariant 10):

| field | notes |
|---|---|
| `id`, `at` | monotonic attempt id, timestamp |
| `outcome` | one of: `injected`, `empty`, `capture-fault`, `recognition-failed`, `filter-fell-back`, `dictionary-degraded`, `target-gone`, `injection-failed`, `injection-partial`, `capped`, `aborted`, `returned` |
| `mode` | `clean` or `raw` |
| `recognised` | verbatim recogniser output; empty if recognition never happened |
| `final` | what was injected, or would have been; empty if none was produced |
| `rules` | ids of replacement rules that fired, and the dictionary's version or mtime |
| `target` | session id and pane |
| `error` | the reason shown to the user, when there was one |
| `recognised` on a cancelled attempt | present, and `final` empty: the words were spoken but never delivered (D26) |
| `speechStartedAt`, `speechEndedAt` | when the microphone actually began and stopped collecting — absent for an attempt that never had audio (D25) |
| `audioSeconds` | the collected buffer's own length, `samples / sampleRate` (D25) |

Reading an entry back is not injection, so invariant 1 does not apply to it: the client prints
`final` by default and `recognised` verbatim on request.

**`recognised` is the recogniser's output byte for byte — before the dictionary, before the filter,
before any tidying — and TWO separate things depend on that.** Both are written down because a rule
with one reason gets repealed the day that reason lapses, by somebody who reads the single
justification, judges it obsolete and simplifies accordingly.

1. A replacement misfire is only diagnosable by comparing `recognised` with `final`. Normalise the
   first and the comparison stops showing what the dictionary did.
2. The sibling project `acta` correlates dictations against meetings it recorded at the same time,
   and the correlation is textual: both projects run the same recogniser (Parakeet TDT 0.6B v3 at
   16 kHz), so the same speech decoded twice agrees almost token for token. Anything applied to
   `recognised` here degrades that match **silently** — in another repository, with no test in this
   one to notice.

**The file is append-only and nothing rotates or truncates it, deliberately.** §9's "one entry per
attempt" is a property of the READER: an attempt whose delivery went differently than the saved line
claimed gets a second line with the same id, and `Record.entries` takes the last. A rotation that
cut between those two lines would leave the reader taking the **superseded** one — silently
reporting the wrong outcome for an attempt, which is the one failure this file cannot afford. Any
future bound on the record's size must therefore bound what is READ, never what is kept.

---

## 10. Acceptance criteria by step

Each criterion is written to be observable, so that two people scoring it agree.

**Step 1 — the path, with fakes.** Chord → client → daemon → agterm, fake capture, canned
transcript.
*Done when:* text appears in the input line of the **session** the chord was pressed in and the pane
that was focused when the daemon handled the start (§5), the terminal buffer shows it unsubmitted,
and the canned transcript deliberately contains a newline and a double space so that a bypassed
sanitiser fails loudly and immediately. *(Built and verified once — commit `3dda6cb`, see F4/F5 —
then deleted.)*

**Step 2 — microphone and models.** Signed bundle, TCC grant, capture converted to 16 kHz mono,
recogniser warm at daemon start.
*Done when:* (a) keypress-to-recording measured under 150 ms warm, over 10 consecutive attempts —
and **the criterion as written does not say which end of that interval it means**, which F4 shows is
a ~35 ms difference: the microphone is live before §6's indicator is lit, and D13 requires that
order. `Scripts/measure.sh` scores the later endpoint, because it times the whole `dictactl`
invocation and the daemon answers only after announcing. Against that endpoint the state on
2026-08-23 is 9 runs of 12 clean, 4 attempts of 120 over, worst 158 ms; against the earlier one
every attempt is inside the budget. Naming the endpoint is a decision this spec has not taken, and
until it does, "(a) is met" is not a statement with one meaning;
(b) a 20-second dictation in Russian containing at least two English technical terms produces text
whose meaning the user judges correct, and the record shows `recognised` non-empty; (c) stop-to-
injection for a 60-second utterance measured under 2 s; (d) the TCC grant survives a rebuild and
relaunch without a new prompt.

**Step 3 — the text pipeline.** Replacement dictionary, the record, reading it back.
*Done when:* a deliberately wrong rule is added, one dictation is run, and the user can name the
offending rule from the record alone — `recognised`, `final` and `rules` are enough to identify it
without re-running anything.

**Step 4 — the filter.** Only after step 2 has shown what real recogniser output actually lacks.
*Done when:* with a filter configured that always fails, a dictation still injects **replaced**, the
notification says the filter did not run, and the record's outcome is `filter-fell-back`.

**Step 5 — the failure matrix.** *Done when:* every row of §7 has either an automated test or an
entry in the manual checklist of §11 with its expected visible result recorded.

**Step 6 — push-to-talk.** The held key of D5, with its floor (D21), its frontmost guard (D22) and
its own target resolution (§5).
*Done when:* (a) holding right Control inside an agterm pane records while it is down and injects on
release, with no chord pressed at any point; (b) a right-Control combination typed at ordinary speed
leaves no record entry carrying text and injects nothing; (c) holding the key while another
application is frontmost does nothing observable at all — no sound, no indicator, no record entry;
(d) a dictation begun by holding the key and ended with `⌃⌥⇧D` injects raw text, and the key release
that follows it is silent; (e) holding the key while one of the user's own commands has agterm's
native picker open types **nothing** into the session behind it and says why (D24); (f) the same as
(a) and (b) on the **laptop's built-in keyboard** with right Command, which is the only armed key it
has (F6a), and with the external keyboard unplugged so the pass cannot come from the other one.

Steps 1–3 need no decision from the user. Step 4 does. Step 6 chose right Control and push-to-talk
only, with the chords kept as they are — that was the user's call on 2026-08-23.

---

## 11. Verified only by a human

Each with the observation that counts as a pass:

- **The chords fire, and land in the right place.** Text appears in the session the chord was pressed
  in; the input line is not submitted.
- **Claude Code specifically.** The skeleton was verified against a fish prompt (F5), which is not
  the same thing: Claude Code's input line handles keystrokes its own way.
- **Microphone TCC.** The prompt appears once, naming dicta; a rebuild and relaunch do not prompt
  again.
- **Recognition quality on this user's speech**, Russian/English mixing, technical vocabulary.
- **Sleep/wake and AirPods route changes during an attempt.** The attempt ends with a visible
  fault, and no text is injected.
- **Daemon lifecycle.** It survives logout/login; a crash never leaves an indicator claiming a
  recording that is not happening.
- **The menu-bar item is legible without being looked at** (D27, F9). Not "the glyph is correct" —
  a glyph checked on purpose cannot be told from one that is failing, since both end up red. The
  pass is noticing it change while working on something else, including while another application
  holds the microphone and the system's own indicator is lit for a reason of its own.
- **The panel is a recovery path and not only a display** (D28). After a dictation that went
  nowhere, the words are on the clipboard without a terminal; after one that was cancelled, they are
  legible and there is nothing to copy, which is the same rule seen from its other side.

---

## 12. Implementation notes (non-normative)

Current choices that satisfy the decisions above. Changing one of these is not a spec change,
provided the behaviour and budgets still hold.

- FluidAudio is linked as a SwiftPM dependency rather than invoked as a CLI, because the CLI pays
  model load per invocation and D10's "no model load on the hot path" would fail. The models are
  warmed at daemon start, including one dummy inference so the first real dictation does not pay ANE
  compilation.
- The daemon is a `LSUIElement` `.app` bundle signed with a stable local identity, started by a user
  LaunchAgent. The bundle exists only as the TCC anchor of D11 — no dock icon, no menu bar, no
  windows. **That sentence describes the daemon and stays exactly true after D27**: the menu-bar item
  is a *second* bundle, with its own identity, which opens no microphone and asks for no permission.
  The daemon links no AppKit UI and holds no reference to it.
- The socket transport is a separate module from the runtime so that the keypress client (D12) does
  not link the capture stack. Note this is a *different* argument from `acta`'s isolated protocol
  target, which exists because a foreign binary decodes its schema — that reasoning does not apply
  here, since client and daemon ship together and are always in lockstep.
- The keymap invokes the client by absolute path and not through a login shell, which would add tens
  of milliseconds of profile loading to every keypress.
- The injection seam is one method. A second injection backend may arrive; generalising before it
  exists buys configuration surface and nothing else.

---

## 13. Deliberately not in scope

Streaming recognition and live partial text (D1, D13). Silence-based auto-stop (D2). Multi-line
injection (D8). A settings window or a dock icon — the daemon has neither, and neither does the
menu-bar bundle (D11, D27). Any injection target other than agterm, and any injection at all from
the UI (D28). Cloud recognition. `acta`'s crash-safety machinery for audio (D14). Automatic retry of
a failed injection (§7).

**A menu bar was on this list and is not any more (D27).** It was here on D11's authority, which is
about the microphone grant rather than about windows; the reasoning and what survives of it are in
D27, and what survives is that the *daemon* still has no menu bar, no dock icon and no windows.
