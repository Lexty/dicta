# SPEC — dicta

Voice dictation into **agterm**'s input line: press a chord, speak, press again, the text appears
where you were typing. Its first purpose is dictating prompts to Claude Code and instructions to
agents running inside agterm.

**English only, across the whole project, with no exceptions** — code, comments, documentation,
commit messages, notifications, client output, test names, and `NSMicrophoneUsageDescription`, which
macOS renders verbatim in the permission dialog. The sibling project `acta` holds the same rule for
the same reason: an exception for "user-facing" strings sounds harmless but turns every new string
into a judgement call about which side of the line it falls on, and it disarms the one mechanical
check available — `grep -rP '[\x{0400}-\x{04FF}]'` is only a gate when there is nothing legitimate
for it to find. Conversation about this project is in Russian; the repository is not.

Status: **specification only. No implementation exists.** An earlier step-1 skeleton was built,
measured, verified end to end, then deliberately deleted; it survives in git as commit `3dda6cb` and
is cited below only where it produced a measurement.

---

## 1. What it is, and what it is not

dicta is a reflex, not an application. Press, speak, press, the words are there.

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

**Attempt** — one press-to-press cycle, identified by a monotonic id that is never reused. An
attempt exists from the moment recording starts, whether or not it ever produces text.

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

**D2 — Recording stops only on an explicit chord. No silence detection.**
The user deliberately pauses for several seconds to formulate, and may speak for three minutes
without a break. Any VAD or end-of-utterance heuristic would cut mid-thought. This was the user's
own call and is not open for re-litigation.

**D3 — Raw versus cleaned text is chosen by which chord STOPS the recording.**
The mode does not affect capture, so it need not be decided in advance. It selects exactly one thing
— whether the **filtered** stage runs (§2). This is also the mechanism for comparing the two: same
dictation, two outcomes, one Shift apart.

**D4 — The target is captured at start, re-validated before injection, and never substituted.**
Wandering to another session mid-sentence must not redirect the text. If the target is gone when
text is ready, that is a delivery failure: notify, preserve the text, and do **not** aim at whatever
has focus now, because that is somebody else's agent.

**D5 — The trigger is an agterm keymap custom command, not a system hotkey.**
`keymap.conf` supports `command "<name>" <chord> <shell...>`. This needs **no Accessibility grant
and no global event monitor**. Consequence to accept: it fires on key *press*, so press-and-hold
push-to-talk is impossible — which is what forces D2's toggle.

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

**D16 — A capture fault always discards the audio and never injects.**
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

**F4 — Warm keypress cost, client invocation to "recording": 20–70 ms.** Measured on the deleted
step-1 skeleton: client alone 9 ms, `agtermctl tree --json` 38 ms; cold start ~390 ms.

**F5 — Injection into a terminal input line works and does not submit.** Verified live on the
skeleton against a fish prompt, using a deliberately hostile canned transcript containing a newline
and a double space: a single line with single spaces arrived, unsubmitted.

---

## 5. Target identity

The two halves of a target are **not** equally accurate, and pretending otherwise would hide a real
failure mode.

- **Session id** is keypress-accurate. agterm expands `$AGT_SESSION_ID` when the chord fires, so it
  names the session the user was in at that instant.
- **Pane** is resolved by the daemon from `agtermctl tree --json` when it handles the start command
  — measured at ~40 ms after the keypress (F4). It is therefore *focus shortly after the keypress*,
  not focus at the keypress.

The residual risk is a focus change inside that window landing the text in the sibling pane of the
right session. It is accepted rather than solved: it needs a deliberate pane switch within ~40 ms of
pressing the chord, and the alternative — trusting an environment variable that this agterm build
does not export (F3) — is unavailable. **If a newer agterm exports the pane at keypress, that
becomes the authority and this section is revised.**

Requirements that follow:

- If the tree does not name exactly one recognisable active pane for the session, the attempt does
  not start (D6).
- Both halves are re-validated before injection. A target that no longer resolves is a delivery
  failure (§2), never a re-aim (D4).

---

## 6. Interaction model

| chord | idle | during an attempt |
|---|---|---|
| `⌃⌥D` | start | stop → clean → inject |
| `⌃⌥⇧D` | start | stop → raw → inject |
| `⌃⌥X` | — | abort |

Both start chords are identical (D3). The keymap passes `$AGT_SESSION_ID` and `$AGT_SOCKET` and
calls a single toggle verb (D7).

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

### Feedback

| state | indicator | sound |
|---|---|---|
| listening | `active --blink`, red | `Pop` |
| working | `active`, amber | — |
| done | `completed --auto-reset` | `Tink` |
| empty, faulted or refused | `blocked` + notification with the reason | `Basso` |

---

## 7. Failure matrix

Every row states: no injection unless said otherwise, a visible reason, and what reaches the record.

| event | class | behaviour |
|---|---|---|
| filter fails, times out or returns empty | processing failure | inject **replaced** instead; notify that the filter did not run |
| recogniser throws, or the model is unavailable | processing failure | no injection; notify; record the attempt with its error and no text |
| recogniser returns nothing but whitespace | — | no injection (an empty insertion is worse than none); notify "empty" |
| recogniser returns text that is not valid UTF-8 or is longer than the frame limit | processing failure | no injection; notify; record the raw bytes' length and the error |
| replacement dictionary missing, unparsable, or a rule is malformed | processing failure | **skip only the offending rules**, apply the rest, and notify once that the dictionary is degraded; never block injection over a config file |
| a replacement produces empty text | processing failure | treat as "empty" above; the dictionary must not silently delete a dictation |
| capture fails while stopping | **capture fault** | discard; notify as a hardware fault, explicitly *not* as silence |
| sleep, audio interruption, input device or route change | **capture fault** | discard; notify |
| duration cap reached | **capture fault** | discard audio, no injection, record whatever text was produced, loud notification (D15) |
| target gone at injection time | delivery failure | do not re-aim (D4); notify; text preserved |
| `session type` fails before any keystroke | delivery failure | notify; text preserved; no automatic retry |
| `session type` fails after keystrokes have begun | delivery failure | notify that the insertion **may be partial**; text preserved; **never retry** — a retry would double part of the text |
| history append fails | — | still inject if injection is otherwise safe, then notify **loudly** that recovery is unavailable, because property 2 is the thing that just broke |
| client cannot reach the daemon | — | loud local failure — desktop notification, not just stderr |
| daemon wedged during an attempt | **capture fault** | watchdog discards; no injection |
| daemon crashed leaving a stale indicator | — | reset the known target's status when the daemon next starts |
| second daemon instance attempted | — | refuse to start; a live socket means a live daemon |
| abort during injection | — | refused (D20) |

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
8. **The keypress client never opens the microphone** (D11).
9. **Recording state is released only after capture has actually been drained** — otherwise the next
   chord can start a second attempt while the first is still stopping, which with a real audio engine
   is two starts racing over one input device.
10. **Recognised text, once produced, always reaches the record** before any injection is attempted,
    so a delivery failure cannot lose it.

---

## 9. The record

One append-only local file, one entry per attempt, written before injection is attempted
(invariant 10):

| field | notes |
|---|---|
| `id`, `at` | monotonic attempt id, timestamp |
| `outcome` | one of: `injected`, `empty`, `capture-fault`, `recognition-failed`, `filter-fell-back`, `dictionary-degraded`, `target-gone`, `injection-failed`, `injection-partial`, `capped`, `aborted` |
| `mode` | `clean` or `raw` |
| `recognised` | verbatim recogniser output; empty if recognition never happened |
| `final` | what was injected, or would have been; empty if none was produced |
| `rules` | ids of replacement rules that fired, and the dictionary's version or mtime |
| `target` | session id and pane |
| `error` | the reason shown to the user, when there was one |

Reading an entry back is not injection, so invariant 1 does not apply to it: the client prints
`final` by default and `recognised` verbatim on request. That is the whole point of storing both —
a replacement misfire is only diagnosable by comparing them.

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
*Done when:* (a) keypress-to-recording measured under 150 ms warm, over 10 consecutive attempts;
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

Steps 1–3 need no decision from the user. Step 4 does.

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
  windows.
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
injection (D8). A settings window, a menu bar, or a dock icon (D11). Any injection target other than
agterm. Cloud recognition. `acta`'s crash-safety machinery for audio (D14). Automatic retry of a
failed injection (§7).
