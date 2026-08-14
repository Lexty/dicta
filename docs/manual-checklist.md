# dicta — what is checked, and by what

Two audits and one list.

The audits are the ones Task 12 of `docs/plans/20260814-dicta-steps-1-3.md` asks for: every invariant
in SPEC.md §8 against the test that would fail if it stopped holding, and every row of SPEC.md §7
against a test or an entry below. They are here rather than in a commit message because they are
meant to be re-read when the spec moves.

The list is what a person has to observe, because hardware, TCC prompts, real speech and real chords
cannot be asserted by a test.

**These tables are themselves checked.** `Sources/DictaTestRunner/ChecklistTests.swift` parses
SPEC.md and this file and fails when they disagree: a row added to §7 with no line here, an invariant
renamed in the spec, or a test name cited here that no longer exists in the suite. A mapping nobody
verifies is a mapping that rots into fiction — the same reasoning as D18.

Test names below are written as `` `test: <name>` `` so the parser can find them. Every one is the
name of a real `@Test` in `Sources/DictaTestRunner/`.

---

## Audit 1 — SPEC.md §8, the invariants

Each invariant must hold on **every** path. "Checked by" names the assertion that goes red first.

| # | invariant | checked by |
|---|---|---|
| 1 | The sanitiser runs immediately before injection, on every path | `test: the result never contains a line break of any kind`, `test: the clean path delivers exactly the sanitised canned transcript`, `test: raw mode skips the filter and nothing else`, `test: a failing filter falls back to replaced rather than costing the user their words`, `test: the dictionary runs before the filter and before the sanitiser`, `test: a replacement containing a line break survives here and is caught by the sanitiser` |
| 2 | final is a single line | `test: every line break is removed`, `test: the result never contains a line break of any kind`, `test: isInjectable rejects exactly what the sanitiser removes`, `test: the canned hostile transcript arrives as one line with single spaces` |
| 3 | No injection into an unvalidated or substituted target | `test: the pane is re-validated before the first keystroke, not after`, `test: a closed split is a delivery failure, never a fallback to the surviving pane`, `test: focus having moved is not a reason to follow it`, `test: a target gone at injection time is reported and never re-aimed`, `test: the target captured at start is the one carried to injection` |
| 4 | Nothing is announced to the user before capture confirms it is running | `test: nothing is announced before capture confirms it is running`, `test: the start chord announces nothing at all until capture confirms`, `test: a warming attempt that is never confirmed announces nothing, ever`, `test: capture confirming after an abort never announces listening` |
| 5 | A duplicated stop never delivers twice. | `test: a duplicated stop is silent and never delivers twice`, `test: draining + stop: quiet no-op, never a second delivery`, `test: processing + stop: quiet no-op`, `test: injecting + stop: quiet no-op`, `test: a stop naming a spent attempt is a silent no-op` |
| 6 | A capture fault never injects | `test: a capture fault discards and never injects, in every state it can reach`, `test: a fault while recording discards, injects nothing, and is worded as hardware`, `test: ten minutes of recording ends the attempt, injects nothing, and says why`, `test: a cap firing while the text is being processed still records the text it produced` |
| 7 | A capture failure is never reported as silence. | `test: no capture fault can be read as silence`, `test: a fault is never reported as silence`, `test: a fault while stopping is a fault, not silence`, `test: a fault while stopping wins over the samples already in hand`, `test: an engine that stopped by itself is a fault, even with a full buffer`, `test: a capture fault is recorded as a fault and never as empty` |
| 8 | The keypress client never opens the microphone | **`Scripts/linkage.sh`**, run first by `Scripts/test.sh`. No swift-testing assertion can reach this one: it is a property of the linked `dictactl` binary, and the test runner deliberately links everything the client must not. Three assertions — load commands, undefined symbols, and DictaRuntime's own mangled names — probed by running the script against `DictaTestRunner`, where all three fire. |
| 9 | Recording state is released only after capture has actually been drained | `test: draining + start: rejected, not queued behind the attempt that is still stopping`, `test: a start chord while the first attempt is still draining is refused, not queued`, `test: a second start chord while recording is refused, and opens no second device` |
| 10 | Recognised text, once produced, always reaches the record | `test: the entry is on disk before the first keystroke is attempted`, `test: a delivery failure supersedes the saved line rather than adding an attempt`, `test: a failing append still delivers the text, then says recovery is unavailable`, `test: every attempt leaves exactly one entry, whatever ended it` |

**No invariant is unaccounted for.** Invariant 8 was the only one with no automated check before
Task 12; `Scripts/linkage.sh` is what closed it.

---

## Audit 2 — SPEC.md §7, the failure matrix

One line per row of the table, in the spec's order. `step 4` marks the parts that belong to the
external filter, which this plan deliberately does not build (D9c): the `Filter` seam ships as
`NoFilter` and nothing invokes a subprocess.

| event | checked by |
|---|---|
| filter fails, times out or returns empty | The **fallback** is tested through a filter armed to throw: `test: a failing filter falls back to replaced rather than costing the user their words`, `test: a filter fallback supersedes a dictionary degradation, and both reasons survive`, `test: a filter that fell back is recorded as such, with the text that still arrived`. That the seam is a pass-through today: `test: NoFilter is a pass-through, hazards and all`. **Step 4** owns the other two triggers — a *timeout* needs a subprocess to time out, and *returns empty* needs an engine that can return empty; the daemon today falls back only on a throw. |
| recogniser throws, or the model is unavailable | `test: a recogniser that throws injects nothing and says so`, `test: a recogniser that throws is recorded with its error and no text`, `test: a transcriber nobody prepared refuses rather than loading on the hot path`, `test: a failed load makes every later attempt fail with the load's own reason`, `test: the self-check names exactly the files that are absent`, `test: a missing model reads as a remedy, not as a hardware fault` |
| recogniser returns nothing but whitespace | `test: nothing recognised means no injection and a visible reason`, `test: an attempt that recognised nothing but whitespace is recorded as empty, with no text`, `test: a whitespace-only transcript is recorded as empty, with the transcript kept` |
| recogniser returns text that is not valid UTF-8 or is longer than the frame limit | `test: recognised text over the frame limit is refused, and the record keeps the byte length`, `test: bytes that are not valid UTF-8 are refused with their length`, `test: text at the limit is accepted and one byte more is refused`, `test: the limit is measured in bytes, not in characters`, `test: the ceiling is the wire's own frame limit` |
| replacement dictionary missing, unparsable, or a rule is malformed | `test: a malformed rule is skipped, the rest apply, and the text still arrives`, `test: a dictionary with several broken rules is still reported exactly once`, `test: a malformed rule is skipped and every other rule still applies`, `test: an absent file is an empty dictionary, and is NOT degraded`, `test: a file that cannot be read is degraded and names itself`, `test: a file that is not valid UTF-8 is degraded rather than mojibake` |
| a replacement produces empty text | `test: a rule that empties the text injects nothing and says the dictionary did it`, `test: a replacement that empties the text is visible as such`, `test: silence is still reported as silence, not blamed on the dictionary` |
| capture fails while stopping | `test: a fault while stopping wins over the samples already in hand`, `test: a fault while stopping is a fault, not silence`, `test: a fault while stopping is recorded as a fault too` |
| sleep, audio interruption, input device or route change | The **decision** is tested through the seam: `test: a fault while recording discards, injects nothing, and is worded as hardware`, `test: every fault kind is one of the three §2 draws`, `test: a fault arriving after an abort does not resurrect the attempt`. The **wiring** to the OS — `AVAudioEngineConfigurationChange` for interruption, device and route changes, `NSWorkspace` for sleep, since macOS has no `AVAudioSession` — is human item **H3** below. |
| duration cap reached | `test: ten minutes of recording ends the attempt, injects nothing, and says why`, `test: a cap firing while the text is being processed still records the text it produced`, `test: the cap is not disarmed by the stop chord, because a wedged drain is still ten minutes`, `test: the cap counts each attempt separately rather than the daemon's uptime`, `test: a fault that is not the cap is recorded as a capture fault, not as capped`, `test: the cap's words name the limit, so the user can attribute it` |
| target gone at injection time | `test: a target gone at injection time is reported and never re-aimed`, `test: a session that has gone is a delivery failure and nothing is typed`, `test: a closed split is a delivery failure, never a fallback to the surviving pane`, `test: focus having moved is not a reason to follow it` |
| `session type` fails before any keystroke | `test: a failure before the first keystroke says nothing was inserted`, `test: a session type that cannot be launched is not reported as maybe-partial`, `test: a refusal from agterm says the input line is untouched` |
| `session type` fails after keystrokes have begun | `test: a failure after keystrokes have begun says the insertion may be partial`, `test: a session type that dies partway through must say the insertion may be partial`, `test: an armed failure still records what was handed over`. The seams test that only a half-finished injection maps to `partial` is not cited here, because its own name contains backticks and the parser below reads citations out of backticks. |
| history append fails | `test: a failing append still delivers the text, then says recovery is unavailable`, `test: the complaint about the record comes after the keystrokes, not instead of them` |
| client cannot reach the daemon | The three failures are told apart and each is fast: `test: no socket file at all is reported as a daemon that is not running`, `test: a socket file with nobody behind it is reported as a crashed daemon`, `test: a daemon that accepts and never answers becomes a fast local failure`. That the client then fires a **desktop notification** rather than only writing to stderr is human item **H1** — `notify` lives in `Sources/dictactl/main.swift`, and SwiftPM cannot import an executable target, so no test can call it. Moving it into a library to make it testable would put a subprocess in `DictaCore` or a notification in `DictaIPC`, which is worse than the gap. |
| daemon wedged during an attempt | `test: a warming attempt that never confirms becomes a capture fault`, `test: a drain that never completes becomes a capture fault`, `test: a completed attempt is never faulted by the timer that was watching it`, `test: recording is watched only by the cap, so a nine-minute dictation is not faulted` |
| daemon crashed leaving a stale indicator | `test: a daemon starting after a crash puts the abandoned indicator out`, `test: a live attempt parks its target, and finishing removes it`, `test: a daemon starting with no parked target touches no indicator` |
| second daemon instance attempted | `test: a second daemon on a live socket refuses to start`, `test: a second daemon is refused while the first one's socket is live`, `test: a socket left by a crashed daemon is replaced rather than refused` |
| abort during injection | `test: injecting + abort: refused (D20)`, `test: abort during injection is refused, because keystrokes cannot be recalled` |

Two rows are the honest gaps, and both are named above rather than papered over: the OS wiring of the
capture faults (**H3**) and the client's own desktop notification (**H1**).

---

## The list — verified only by a human

SPEC.md §11 and the Post-Completion section of the plan. Each entry states the observation that
counts as a pass, so two people scoring it agree.

- **H1 — the client's loud local failure.** Stop the daemon (`launchctl bootout` or kill it), then
  press the start chord. Pass: a desktop notification titled "dicta" appears saying the daemon is
  not running. Fail: only a line on stderr, which the user's hands are nowhere near.
- **H2 — the chords fire, in the session they were pressed in.** With `docs/keymap.snippet.conf`
  installed, press ⌃⌥D in a session running **Claude Code**, speak, press again. Pass: the text
  appears in Claude Code's input line, unsubmitted, in that session. F5 verified a fish prompt,
  which is not the same thing — Claude Code's input line is the one that matters.
- **H3 — sleep/wake and a route change end the attempt.** Start a dictation, then (a) close the lid
  and reopen it, and separately (b) pull AirPods out of their case so the input route changes. Pass
  in both: a visible fault worded as hardware, nothing typed, and an entry in the record with
  outcome `capture-fault`. Fail: silence reported as an empty dictation.

The remaining human items — §10's step 1, step 2 (a)–(d) and step 3 — belong to Task 13, which
writes them here with the same "what counts as a pass" wording.
