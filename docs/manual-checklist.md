# dicta — what is checked, and by what

Two audits and one list.

The audits are the ones Task 12 of `docs/plans/completed/20260814-dicta-steps-1-3.md` asks for: every invariant
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
| 1 | The sanitiser runs immediately before injection, on every path | `test: the result never contains a line break of any kind`, `test: the clean path delivers exactly the sanitised canned transcript`, `test: raw mode skips the filter and nothing else`, `test: a failing filter falls back to replaced rather than costing the user their words`, `test: the dictionary runs before the filter and before the sanitiser`, `test: a replacement containing a line break survives here and is caught by the sanitiser`, and on the focused-field path, where a newline posted into the VS Code terminal submits exactly as it does in agterm, `test: a focused-field delivery posts only the sanitised single line` |
| 2 | final is a single line | `test: every line break is removed`, `test: the result never contains a line break of any kind`, `test: isInjectable rejects exactly what the sanitiser removes`, `test: the canned hostile transcript arrives as one line with single spaces` |
| 3 | No injection into an unvalidated or substituted target | `test: the pane is re-validated before the first keystroke, not after`, `test: a closed split is a delivery failure, never a fallback to the surviving pane`, `test: focus having moved is not a reason to follow it`, `test: a target gone at injection time is reported and never re-aimed`, `test: the target captured at start is the one carried to injection`. For a focused-field target, where D4's guarantee is the narrower one the invariant now states: **H31** (a), a field that changed before delivery is `target-gone` and never re-aimed, and (b), no character ever reaches the application switched to. That delivery is handed the element its own attempt captured, and never another attempt's: `test: a field attempt is typed through the field injector, with the handle it captured`, `test: a field start refused while an attempt is live neither replaces nor drops its handle`, `test: a late teardown of a finished field attempt leaves the next attempt's handle in place` and `test: a field handle is stored inside the critical section that accepts its start`. The injector's own re-validation: `test: planning comes before the final validation, and nothing but posting follows it`, `test: a definite change before delivery is target-gone with zero events`, `test: an accessibility read that succeeds while the frontmost app changes is target-gone` and `test: the frontmost app changing after chunk k stops as may-be-partial with exactly k chunks` |
| 4 | Nothing is announced to the user before capture confirms it is running | `test: nothing is announced before capture confirms it is running`, `test: the start chord announces nothing at all until capture confirms`, `test: a warming attempt that is never confirmed announces nothing, ever`, `test: capture confirming after an abort never announces listening`, and for the sound where there is no indicator, through agterm and through the system feedback a focused field and a machine without agterm use: `test: no Pop is heard before capture confirms it is running, through either notifier` |
| 5 | A duplicated stop never delivers twice. | `test: a duplicated stop is silent and never delivers twice`, `test: draining + stop: quiet no-op, never a second delivery`, `test: processing + stop: quiet no-op`, `test: injecting + stop: quiet no-op`, `test: a stop naming a spent attempt is a silent no-op` |
| 6 | A capture fault never injects | `test: a capture fault discards and never injects, in every state it can reach`, `test: a fault while recording discards, injects nothing, and is worded as hardware`, `test: ten minutes of recording ends the attempt, injects nothing, and says why`, `test: a cap firing while the text is being processed still records the text it produced`, `test: a cap firing while the recogniser is still running does not lose the text it returns` |
| 7 | A capture failure is never reported as silence. | `test: no capture fault can be read as silence`, `test: a fault is never reported as silence`, `test: a fault while stopping is a fault, not silence`, `test: a fault while stopping wins over the samples already in hand`, `test: an engine that stopped by itself is a fault, even with a full buffer`, `test: a capture fault is recorded as a fault and never as empty` |
| 8 | Neither the keypress client nor the menu-bar UI ever opens the microphone | **`Scripts/linkage.sh`**, run first by `Scripts/test.sh`, plus `test: linkage.sh scores the menu, and forbids it the capture stack`, which asserts the script still HAS the menu's row — the script is the only thing that can fail on the invariant, so a row silently dropped from it would take the invariant with it. No swift-testing assertion can reach the invariant itself: it is a property of what the linked `dictactl` and `DictaMenu` binaries are built against, and the test runner deliberately links everything both must not. Three assertions per binary — load commands, undefined symbols, and DictaRuntime's own mangled names — probed by running the script against `DictaTestRunner`, where all three fire. The menu is held to the same three even though it legitimately links SwiftUI, which is the one difference between its row and `dictactl`'s. |
| 9 | Recording state is released only after capture has actually been drained | `test: draining + start: rejected, not queued behind the attempt that is still stopping`, `test: a start chord while the first attempt is still draining is refused, not queued`, `test: a second start chord while recording is refused, and opens no second device` |
| 10 | Recognised text, once produced, always reaches the record | `test: the entry is on disk before the first keystroke is attempted`, `test: a delivery failure supersedes the saved line rather than adding an attempt`, `test: a failing append still delivers the text, then says recovery is unavailable`, `test: every attempt leaves exactly one entry, whatever ended it`, `test: a cap firing while the recogniser is still running does not lose the text it returns`, `test: an abort while the recogniser is running keeps the text but never delivers it`, and on the focused-field path, read from inside the first post, `test: a focused-field delivery has the text in the record before the first event` |
| 11 | The hold trigger reads modifier state, and no bundle dicta ships reads a key stream | **`Scripts/linkage.sh`**, run first by `Scripts/test.sh`, plus `test: linkage.sh scores the menu, and forbids it the capture stack`. The second invariant no assertion can reach, and for the same reason as 8: it is a property of WHICH API the built binary calls, not of what it does. `nm` on `Dicta` **and on `DictaMenu`** must name no `CGEventTapCreate`, no `CGEventTapEnable`, no `IOHIDManager` and no `_OBJC_CLASS_$_NSEvent` — the four shapes of "read a keystroke", every one of which would make macOS demand Input Monitoring or Accessibility (D5, F6). The menu is the binary where this would be lost by accident, since a status item watching for a shortcut is an ordinary thing to write; the check was probed there against a deliberately-monitoring build, which shows `U _OBJC_CLASS_$_NSEvent` and the selector `addGlobalMonitorForEventsMatchingMask:handler:`, and on the daemon by adding a `CGEvent.tapCreate` call to `SystemModifiers.flags()` and watching the check fail on `U _CGEventTapCreate`, then reverting both. |
| 12 | A hold under D21's floor never injects | `test: a hold under the floor discards rather than delivering`, `test: a hold under the floor aborts and never stops`, `test: the floor separates the two populations it was measured against, and only those`, `test: a gesture that never received an attempt id can never end one` |
| 13 | The hold trigger never starts an attempt while another application is frontmost, unless `--focused-fields` routes the hold to that application's focused field | `test: with focused fields off, the hold key does nothing at all in another application`, which is the option-off half, and `test: focus moving to another application mid-hold does not stop the delivery`. End to end with the option off, **H11** (c). With it on, the route is the only exception: **H32** (a) shows a combination released before the floor starting nothing, and (b) shows a hold that switched the application delivering nothing. **H19** is the panel, which routes nowhere of its own because it never becomes frontmost (F11, D30). The routing table is `test: another application frontmost is ignored with focused fields off`, `test: another application frontmost routes to its focused field with focused fields on` and `test: agterm frontmost takes the agterm path with focused fields on`; that the option off reaches no accessibility at all, `test: with focused fields off, the accessibility fake records zero calls in every scenario`; and that nothing starts for a key no longer down, `test: a long hold released while the sender was blocked starts nothing` and `test: a stale threshold is dropped, and only the held generation's threshold starts` |
| 14 | Keystrokes are posted into another application only when `--focused-fields` is on, only into a focused-field target that re-validated immediately before delivery, never by `dictactl` or the menu-bar UI; and the daemon never reads a field's value or selected text | Each clause separately. **Only when on**: **H11** (c), with the option off, a hold in Safari does nothing at all; and a daemon without the option refuses a field start having made no accessibility call, the `optionOff` case of `test: a field start is refused before capture opens, for every reason it can be refused`; and the composition behind both, which with the option off constructs no accessibility, event-posting or frontmost adapter at all, `test: with focused fields off, the wiring is nil and constructs no system adapter`. **Only into a target that re-validated**: **H28** (a) and (d), where a missing or revoked grant posts nothing, **H29** for Secure Input, **H30** for a thing that is not a text field, the daemon's refusals of each before capture in the same test, **H31** for a field that changed, and **H34** for a text over the bound. The re-validation immediately before the first event, with nothing but posting after it: `test: planning comes before the final validation, and nothing but posting follows it`, `test: a revoked grant or Secure Input at re-validation is not-started with zero events`, `test: the same element no longer eligible on fresh metadata is not-started with zero events` and `test: a definite change before delivery is target-gone with zero events`. **Never by the client or the menu bar**: **`Scripts/linkage.sh`**, run first by `Scripts/test.sh`, which fails by name when `nm` on `dictactl` or `DictaMenu` shows `_CGEventPost`, `_CGEventPostToPid`, `_CGEventKeyboardSetUnicodeString`, `_AXUIElementCreateSystemWide`, `_AXUIElementCreateApplication`, `_AXUIElementCopyAttributeValue`, `_AXUIElementCopyAttributeNames`, `_AXUIElementIsAttributeSettable`, `_AXUIElementSetAttributeValue`, `_AXUIElementGetPid`, `_AXUIElementSetMessagingTimeout`, `_AXIsProcessTrusted`, `_AXIsProcessTrustedWithOptions` or `_IsSecureEventInputEnabled`, matched as exact C names so that SwiftUI's own accessibility symbols cannot trip it; probed by adding a `postToPid` call to `dictactl` and watching the gate fail on `U _CGEventPostToPid`, then reverting; plus `test: linkage.sh forbids the client and the menu posting keystrokes or reading accessibility`, which asserts the script still has the row, `test: linkage.sh fails a real binary calling any listed function, and passes one calling none`, which compiles a C binary naming every listed function and requires the gate to name each, and `test: linkage.sh fails a daemon importing an accessibility function the list does not name`, the check that holds the list to what `Dicta` actually imports. **Never reads a value**: no person can see an attribute read, so the adapter copies attributes only through one function typed by a closed list of identity attributes, and `test: the adapter can copy only identity attributes, never a field's value or selected text` holds both the list and that nothing in `Sources/` copies around it |

**No invariant is unaccounted for.** Invariant 8 was the only one with no automated check before
Task 12; `Scripts/linkage.sh` is what closed it.

---

## Audit 2 — SPEC.md §7, the failure matrix

One line per row of the table, in the spec's order. `step 4` marks the parts that belong to the
external filter, which this plan deliberately does not build (D9c): the `Filter` seam ships as
`NoFilter` and nothing invokes a subprocess.

| event | checked by |
|---|---|
| filter fails, times out or returns empty | A filter armed to throw: `test: a failing filter falls back to replaced rather than costing the user their words`, `test: a filter fallback supersedes a dictionary degradation, and both reasons survive`, `test: a filter that fell back is recorded as such, with the text that still arrived`. A filter that **returns empty**, which is the same fallback and was for a while the opposite one — an empty answer reached the sanitiser and ended the attempt as `empty`, so the user was told their microphone had heard silence: `test: a filter that answers with nothing falls back too, rather than eating the dictation`, and its other side, `test: a dictation that was already empty is not blamed on the filter that passed it through`. That the seam is a pass-through today: `test: NoFilter is a pass-through, hazards and all`. **Step 4** owns the remaining trigger alone — a *timeout* needs a subprocess to time out. |
| recogniser throws, or the model is unavailable | `test: a recogniser that throws injects nothing and says so`, `test: a recogniser that throws is recorded with its error and no text`, `test: a transcriber nobody prepared refuses rather than loading on the hot path`, `test: a failed load makes every later attempt fail with the load's own reason`, `test: the self-check names exactly the files that are absent`, `test: a missing model reads as a remedy, not as a hardware fault` |
| recogniser returns nothing but whitespace | `test: nothing recognised means no injection and a visible reason`, `test: an attempt that recognised nothing but whitespace is recorded as empty, with no text`, `test: a whitespace-only transcript is recorded as empty, with the transcript kept` |
| recogniser returns text that is not valid UTF-8 or is longer than the frame limit | `test: recognised text over the frame limit is refused, and the record keeps the byte length`, `test: bytes that are not valid UTF-8 are refused with their length`, `test: text at the limit is accepted and one byte more is refused`, `test: the limit is measured in bytes, not in characters`, `test: text at the ceiling still fits a response frame, envelope and all` |
| replacement dictionary unreadable, unparsable, or a rule is malformed | `test: a malformed rule is skipped, the rest apply, and the text still arrives`, `test: a dictionary with several broken rules is still reported exactly once`, `test: a malformed rule is skipped and every other rule still applies`, `test: an absent file is an empty dictionary, and is NOT degraded`, `test: a file that cannot be read is degraded and names itself`, `test: a file that is not valid UTF-8 is degraded rather than mojibake` |
| a replacement produces empty text | `test: a rule that empties the text injects nothing and says the dictionary did it`, `test: a replacement that empties the text is visible as such`, `test: silence is still reported as silence, not blamed on the dictionary` |
| capture fails while stopping | `test: a fault while stopping wins over the samples already in hand`, `test: a fault while stopping is a fault, not silence`, `test: a fault while stopping is recorded as a fault too` |
| sleep, audio interruption, input device or route change | The **decision** is tested through the seam: `test: a fault while recording discards, injects nothing, and is worded as hardware`, `test: every fault kind is one of the three §2 draws`, `test: a fault arriving after an abort does not resurrect the attempt`. The **wiring** to the OS — `AVAudioEngineConfigurationChange` for interruption, device and route changes, `NSWorkspace` for sleep, since macOS has no `AVAudioSession` — is human item **H3** below. |
| duration cap reached | `test: ten minutes of recording ends the attempt, injects nothing, and says why`, `test: a cap firing while the text is being processed still records the text it produced`, `test: a cap firing while the recogniser is still running does not lose the text it returns`, `test: the cap is not disarmed by the stop chord, because a wedged drain is still ten minutes`, `test: the cap counts each attempt separately rather than the daemon's uptime`, `test: a fault that is not the cap is recorded as a capture fault, not as capped`, `test: the cap's words name the limit, so the user can attribute it` |
| target gone at injection time | `test: a target gone at injection time is reported and never re-aimed`, `test: a session that has gone is a delivery failure and nothing is typed`, `test: a closed split is a delivery failure, never a fallback to the surviving pane`, `test: focus having moved is not a reason to follow it` |
| `session type` fails before any keystroke | `test: a failure before the first keystroke says nothing was inserted`, `test: a session type that cannot be launched is not reported as maybe-partial`, `test: a refusal from agterm says the input line is untouched` |
| `session type` fails after keystrokes have begun | `test: a failure after keystrokes have begun says the insertion may be partial`, `test: a session type that dies partway through must say the insertion may be partial`, `test: an armed failure still records what was handed over`. The seams test that only a half-finished injection maps to `partial` is deliberately not cited: its own name contains backticks, and citations are read out of backticks. |
| history append fails | `test: a failing append still delivers the text, then says recovery is unavailable`, `test: the complaint about the record comes after the keystrokes, not instead of them` |
| client cannot reach the daemon | The three failures are told apart and each is fast: `test: no socket file at all is reported as a daemon that is not running`, `test: a socket file with nobody behind it is reported as a crashed daemon`, `test: a daemon that accepts and never answers becomes a fast local failure`. That the client then fires a **desktop notification** rather than only writing to stderr is human item **H1** — `notify` lives in `Sources/dictactl/main.swift`, and SwiftPM cannot import an executable target, so no test can call it. Moving it into a library to make it testable would put a subprocess in `DictaCore` or a notification in `DictaIPC`, which is worse than the gap. |
| daemon wedged during an attempt | `test: a warming attempt that never confirms becomes a capture fault`, `test: a drain that never completes becomes a capture fault`, `test: a completed attempt is never faulted by the timer that was watching it`, `test: recording is watched only by the cap, so a nine-minute dictation is not faulted` |
| daemon crashed leaving a stale indicator | `test: a daemon starting after a crash puts the abandoned indicator out`, `test: a live attempt parks its target, and finishing removes it`, `test: a daemon starting with no parked target touches no indicator`. A parked focused field has no indicator, so its file is removed without asking agterm anything: `test: a parked focused field is removed at start-up without asking agterm to clear anything` |
| second daemon instance attempted | `test: a second daemon on a live socket refuses to start`, `test: a second daemon is refused while the first one's socket is live`, `test: a socket left by a crashed daemon is replaced rather than refused` |
| abort during injection | `test: injecting + abort: refused (D20)`, `test: abort during injection is refused, because keystrokes cannot be recalled`, and on the focused-field path `test: an abort while typing into a focused field is refused` |
| a caller waits for a dictation and nobody speaks | `test: a dictate nobody answers gives up with no text rather than waiting for ever`. That the empty result reaches the caller as an exit code rather than as a line of prose on stdout — which would become the user's prompt — is `ClientCommand.writesDataToStdout` and human item **H13** end to end |
| a second caller asks for the next dictation while one is already waiting | `test: a second caller is refused rather than handed somebody else's sentence`, which asserts both halves: the second is refused, and the first still gets the words |
| hold key pressed while agterm is not frontmost, with `--focused-fields` off | `test: with focused fields off, the hold key does nothing at all in another application`. The assertion is **silence**, not merely "no dictation": the trigger sends nothing and the notifier logs nothing, because a notification here would fire on every right-Control combination typed in a browser. Its opposite number, so that the two are not confused, is `test: a session that cannot be resolved starts nothing and is said out loud` |
| hold shorter than the floor | `test: a hold under the floor aborts and never stops`, `test: a hold under the floor discards rather than delivering`, `test: the floor separates the two populations it was measured against, and only those`. That the ordinary press this defends against does not even reach the gesture, when it is a combination on the other Control key: `test: a left-Control combination never reaches the daemon` |
| hold key pressed while agterm's own picker is open | `test: a picker open in the window refuses the dictation rather than typing behind it`, `test: a dictation refused because the picker is open never opens the microphone`. The second is the one that matters: refusing after capture had begun would leave a lit microphone recording for a pane nobody can see. End to end, in the user's own `claude-ask.sh` picker, is **H11** criterion (e) |
| hold key released after a chord already ended the attempt | `test: the command that ends a hold names the attempt the start returned` is the mechanism (D23); `test: a stop naming a spent attempt is a silent no-op` is the daemon honouring it, and it predates this trigger — which is the point, since the rule was already there and only needed the id carried to it. The mixed gesture end to end is human item **H11** |
| a hold on the focused-field path released before the floor | `test: a short hold queued behind a blocked sender costs nothing on the focused-field path` asserts zero accessibility calls, zero requests and zero notifications, and `test: no threshold between a sampled down and up shorter than the floor` that the floor is measured by the poll loop's clock rather than by when the sender gets round to it. **H32** (a): minutes of right-hand shortcuts in VS Code and Safari, scored by `record.jsonl` keeping its line count, with no sound, no notification and no microphone dot |
| a hold on the focused-field path whose release switched the application | `test: a field attempt whose application switched during the hold is aborted silently` and `test: a field attempt whose application switched within the settle window is aborted silently`, against `test: a field attempt whose application never changed is stopped after the settle window`. The settle window's length is not measured (F11), so **H32** (b) is the half that scores a real `⌘Tab`: a right-hand app switch leaves no text anywhere, no sound and no notification. **H31** (b) meets the same rule from the other side, when a switch lands inside the settle window |
| a hold outlasts the floor with `--focused-fields` on and no Accessibility grant | `test: with the grant missing, a threshold refuses once, audibly, and sends nothing`, and the daemon's own check behind it, which refuses before capture if the grant went between the threshold and the start: the `noGrant` case of `test: a field start is refused before capture opens, for every reason it can be refused`. **H28** (a) for the refusal with the microphone never lit, (b) for the grant picked up without a restart, and (e) for `Basso` being the only signal under a Focus mode; that the refusal is both a sound and a notification, and not one standing in for the other: `test: a failure plays Basso and notifies through osascript` |
| a hold outlasts the floor while Secure Input is enabled by any process | The `secureInput` case of `test: a field start is refused before capture opens, for every reason it can be refused`, with the microphone never opened and no element read. **H29** (a) with a password field focused, and (b) with Secure Input held by another process, which may honestly be scored "not reproduced" |
| the focused element cannot be read when the hold passes the floor | The `noElement`, `unreadable` and `pidMismatch` cases of `test: a field start is refused before capture opens, for every reason it can be refused`: no element, no answer, and an element another process owns each refuse with the microphone never opened. The one `AXManualAccessibility` fallback, scripted call by call: `test: no element, the attribute set, and still no element is unknown, never an absence` and `test: a set that could not complete says nothing about the field, and is not re-read`. **H24** (a), where the first dictation after VS Code launches must land, because it is the one that sets `AXManualAccessibility` and re-reads, and **H26** for Slack. **H30** (d) is the refusal itself, where an application can be found that answers with nothing |
| the focused element is not eligible, or its eligibility is unknown | The `ineligible` and `unknown` cases of `test: a field start is refused before capture opens, for every reason it can be refused`, each refused with the microphone never opened and no handle kept. **H30** (a)–(c): a tree, a page and a file list each refused before the microphone opens, with no type-to-select side effect. **H29** (a) is the password field, which the subrole names |
| final text exceeds the delivery bound | `test: final over the delivery bound types nothing and stays in the record`, for a dictionary rule that grows the text past the bound and for a single grapheme longer than one event, each with nothing posted and **final** in the record; `test: a plan over either hard limit is not-started with zero events and no check made`, that the plan is refused before any accessibility call. **H34** (a) for a text over the bound, and (b) for a single grapheme longer than one event, each with nothing typed and the whole text in `dictactl last` |
| the delivery deadline passes mid-delivery | Not reachable by hand: a delivery lasts tens of milliseconds (F11), and the deadline exists to stop one that runs long. **H31** (b) scores the other road to the same ending, stopped part-way, may be partial, never retried. The deadline itself is driven by `test: the deadline passing after chunk k stops as may-be-partial with exactly k chunks` and `test: the pacing counts against the deadline`; that it sits below the client's ceiling, `test: the daemon's own ceilings fit inside the client's read timeout` |
| the focused field is gone before delivery | `test: a field attempt's delivery failure is said through system feedback, never agterm` records `target-gone` and says so where a field is told things, and `test: a field handle is released however its attempt ends` that the handle does not outlive it; the detection itself is `test: a definite change before delivery is target-gone with zero events` (a different element, no element, an element gone, a different frontmost pid) and `test: an accessibility read that succeeds while the frontmost app changes is target-gone`. **H31** (a): focus moved from the editor to the terminal while the key was held, so nothing is typed in either and the outcome is `target-gone` |
| accessibility cannot answer when the focused field is re-validated | `test: accessibility that cannot answer at re-validation is not-started with zero events`, `test: a revoked grant or Secure Input at re-validation is not-started with zero events`, `test: the same element no longer eligible on fresh metadata is not-started with zero events` and `test: an accessibility read that succeeds past the deadline posts nothing, as not-started`. **H28** (d): the grant revoked mid-dictation is a delivery failure that says nothing was inserted, and not a claim that the field is gone |
| focus moves to another application mid-delivery | `test: the frontmost app changing after chunk k stops as may-be-partial with exactly k chunks`, with exactly k chunks posted, all to the captured pid, and none retried. **H31** (b), scored by its result: in ten runs no character ever reaches the application switched to |
| focus moves inside the same application mid-delivery | **H31** (c). The row is a stated limit rather than a behaviour, so the item records the split when it is seen rather than failing on it |
| the receiving application silently drops or rewrites posted keystrokes | **H24**, **H25**, **H26** and **H27**, each comparing what arrived with `dictactl last` character for character. That comparison is the only instrument, because nothing in the mechanism reports a drop. Slack's rewrites are expected (F11) |
| a chord, or the hold key in front of agterm, while `agtermctl` is absent and `--focused-fields` is on | `test: with no agterm, a chord and a focus start are refused with a reason naming agtermctl` for the refusal, opening nothing, and `test: with no agterm, untargeted refusals notify through system feedback` for where it is said when agterm cannot say it. That the daemon starts at all is `test: a missing agtermctl is fatal with focused fields off, and survived with them on`; that readiness does not block dictation over it, `test: a missing agterm blocks dictation only with focused fields off` and, through the daemon, `test: with no agterm, readiness blocks dictation only for a daemon without focused fields`; and that the menu shows a notice rather than a fault, `test: a missing agterm with focused fields on is drawn as a working daemon, not a fault` and `test: a missing agterm with focused fields on is an amber notice, and without them a fault`. The agent that runs it is `test: the agent rendered for both focused-field settings lints, with no empty argument`. **H33** (a) and (b) score start-up both ways and (c) both refusals on a real machine, while a hold in VS Code still dictates |
| the active session cannot be read from the tree when the hold key goes down | `test: a session that cannot be resolved starts nothing and is said out loud`; that the lookup happens once, in the daemon, and only when asked for: `test: a start asking for focus resolves both halves itself, out of one lookup`, `test: only an explicit focus flag resolves from focus, never a missing session`, `test: the focused target carries the active session's own active pane, from one read`, `test: a focused target whose pane cannot be named is refused, exactly as a chord's would be`. The readings that produce the refusal: `test: a tree with no active workspace refuses rather than picking one`, `test: a workspace whose sessions are all inactive refuses rather than picking one`, `test: two sessions claiming to be active is a refusal, never a choice`, `test: the active session is read from the active workspace and not from every workspace`, `test: a refusal from agterm is a refusal here, not an empty tree` |
| the hold trigger is not armed, or its source reads nothing | Nothing automatic, and the row itself says why: `CGEventSource.flagsState` has no error channel, so "no modifier is down" and "this is not working" are one answer. Human item **H12** scores that the trigger is armed at all on the installed daemon; `test: a daemon that cannot be reached is reported rather than swallowed` covers the half that does have an error channel |
| the user aborts after speaking | `test: an abort while recording is written down and typed nowhere` is the whole of D26 in one place: the words reach the record, `final` stays empty, nothing is injected and the indicator ends blocked. The other end of the same rule, when the cancel lands while the recogniser is already running: `test: an abort while the recogniser is running keeps the text but never delivers it`. That no later reader treats those words as deliverable: `test: dictactl last does not offer a cancelled dictation as text to deliver`. That the buffer is kept rather than thrown away, and that no second drain races the first: `test: abort while recording keeps the audio for the record and injects nothing`, `test: abort while draining does not issue a second drain for the same buffer`, `test: recording + abort: cancels, and the audio is kept for the record`, `test: draining + abort: cancels, and does not race the drain already in flight`. That an attempt which never had audio journals nothing: `test: an attempt abandoned before audio existed carries no speech window, and that is honest` |
| a watcher goes away mid-stream | `test: a watcher that goes away is dropped, and the daemon keeps serving` is the daemon surviving it; `test: a watcher on the far end does not change what an attempt does` is the half the row actually claims — that no OUTCOME moves. The two are separate on purpose: a daemon that kept serving while quietly changing what a dictation did would pass the first and fail the invariant the row exists for |
| the watcher cap is reached | `test: past the cap a watcher is REFUSED with a response, never by a dropped connection`, and `test: the watcher cap exists and is small`. The wording of the first is the finding: `ControlClient` reads a closed connection as `daemonCrashed`, so refusing by hanging up would make a healthy daemon that is answering correctly report itself as dead in the one window the user would look at |
| the daemon stops or restarts under a live watcher | `test: a daemon shutting down ENDS the stream rather than dropping it` is why an orderly `launchctl bootout` reads amber and says stopped instead of red and crashed; `test: the backoff grows and is bounded` is the reconnect that follows. End to end, on the installed pair, is **H18** — and that the strip comes back **without the panel being opened** is **H22**, which is a separate item because that path was broken and passing until it was measured (F9a) |
| the daemon dies while a watcher is showing a recording | `test: a lost connection does not keep drawing a live microphone` is the whole of it, and it is the only assertion in this audit about a mistake the UI could make by itself rather than one it could inherit. Its two halves are asserted separately because they fail separately: the glyph stops claiming a live microphone, and `speakingSeconds` goes nil so the clock stops counting a dictation that ended when the daemon did. That the same rule governs the strip and not only the panel: `test: the menu bar shows a clock only while the microphone is open`, whose last case is exactly this one |

Two rows are the honest gaps, and both are named above rather than papered over: the OS wiring of the
capture faults (**H3**) and the client's own desktop notification (**H1**).

**The focused-field rows (D31, D32) began citing human items only, and that was a stage rather than a gap.**
They were written before any of their code, from `docs/plans/completed/20260912-dicta-focused-fields.md`,
because this file may cite only tests that exist. Each task of that plan adds its tests' citations
beside the human item that stood in for them. Two rows stay human by nature: a delivery that
something outside dicta rewrites (**H24**–**H27**), and a move of focus inside one application during
delivery (**H31**).

### How the two abort rows are reached from a chord, and why that took a rule of its own

§6 gives `processing × abort → cancel` and `injecting × abort → refused`. Both are implemented in
`StateMachine` and asserted above, and most of those assertions reach them through `Daemon.handle`
**called directly** — the seams re-enter from inside `processing` and `injecting`, which is the only
way to observe a state that lasts exactly one synchronous call.

That is not the path a chord takes, and for a while the difference was a live deviation rather than a
detail. A keypress arrives through `ControlServer`, which serialised **every** handler call under one
lock, and `Daemon.apply` performs recognition and the keystrokes *inline* before it answers. An abort
pressed during `processing` therefore waited for the stop pipeline it meant to interrupt: it was
answered `accepted`, and by the time it was decided the dictation had already been typed into the
pane. The cell of §6's table the user reaches for when they realise they have dictated the wrong
thing was the one cell a chord could not reach.

`Command.isServedConcurrently` is the fix, and `abort` is its only member: `serve` runs that one verb
without the handler lock, so it overtakes the attempt it is cancelling. Both orders are safe because
the transition — not the handler — is the atomic point. An abort that wins leaves the machine idle,
so `.recognised` produces no injection effect and `Daemon.recognise` drops the text on the floor; an
abort that arrives after the machine has moved to `injecting` is refused by D20, which is the next
cell of the same table. The transport half is held by
`test: an abort is answered while another command is still inside the handler`, and the daemon is
driven end to end over a real socket by
`test: an abort chord cancels a dictation that is still being recognised` — both were probed by
restoring the unconditional lock, and both go red.

The long client ceiling stays: `ControlTimeouts.read(for:)` gives `abort` the same `pipelineRead` as
`stop`. It is no longer queued behind anything, but a cancel still spends two `agtermctl`
subprocesses of its own, and the short ceiling would expire and tell the user "dicta did not answer"
about a daemon that was at that moment cancelling for them.

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
- **H4 — step 1 of §10: the text arrives, unsubmitted, where the chord was pressed.** Press ⌃⌥D in
  a session, speak a sentence with a pause in the middle of it, then press it again. Pass: the text
  appears in the input line of **that** session and the pane that was focused when the daemon
  handled the start; the buffer shows it and the prompt has **not** been submitted. Fail, in the
  way that matters most: the prompt fires by itself — that is the sanitiser bypassed, and it is
  invariant 1.
  **What this item does not score, deliberately.** An earlier draft asked for the daemon to be run
  "against `FakeTranscriber`", whose canned transcript carries a newline, a double space and a
  trailing space on purpose. No such build exists: `Fakes.swift` lives in `Sources/DictaTestRunner`,
  the `Dicta` executable does not depend on that target, and `Scripts/run.sh` runs the real binary —
  so the procedure could not be carried out, and a scorer either edited source or quietly scored
  something weaker. Real recogniser output will not oblige with a newline either. That the hostile
  transcript survives the sanitiser as one line is a standing regression instead —
  `test: the canned hostile transcript arrives as one line with single spaces`, and end to end,
  `test: the clean path delivers exactly the sanitised canned transcript`. What is left here is the
  half no test can reach — that the keystrokes land in the right pane and the prompt stays
  unsubmitted.
- **H5 — step 2 (a): keypress to recording under 150 ms, warm.** `bash Scripts/measure.sh` — 10
  attempts by default after one discarded warm-up, each ended with `abort`, so it types nothing into
  a pane. Pass: every one of 10 consecutive attempts reports client-invocation → "recording" under
  **150 ms**, with the daemon already running and its models already loaded. Fail: any attempt over
  the budget, or a run whose first attempt is an outlier because the daemon was cold — that is a
  measurement of the wrong thing, so restart it rather than averaging it away. The script's own exit
  status carries the verdict — non-zero when either criterion misses — so the PASS/FAIL line is not
  the only place a missed budget is visible.
  **Scored twice, and still FAILED — but read F4 before re-scoring, because what the script measures
  is not the only reading of the criterion.**
  *2026-08-18, before the prepared capture engine:* min 155.8, median 180.0, p90 229.1, max 252.5 —
  ten attempts out of ten over budget.
  *2026-08-23, on `4c2ac7c`:* 12 runs of 10. Nine runs had every attempt under the budget; 4 attempts
  of 120 were over, at 153.5, 156.3, 156.6 and 157.9 ms; pooled median 122.1, p90 132.1, p95 145.1,
  min 97.8. The failure is now marginal rather than systematic — the worst of 120 attempts exceeds
  the budget by 5%, where before the *best* of ten missed it by more — but the criterion says every
  attempt, and three runs in twelve had one that did not.
  Re-scoring is meaningful again only if the cost moves or the budget does. What is NOT a way to move
  it: taking §6's indicator off the path before the daemon answers. That would cut ~35 ms from what
  this script reports without the indicator appearing one millisecond sooner, which is scoring the
  scorer rather than the tool.
- **H6 — step 2 (b): a real Russian dictation with English terms in it is understood.** Dictate
  roughly 20 seconds of Russian containing **at least two** English technical terms, on this user's
  own microphone and in this user's own voice — the Task 10 probe used synthesised speech and a
  meeting recording, which establishes that the pipeline works and not that it works for them. Pass:
  the user judges the meaning of the text correct, and `dictactl last --recognised` is non-empty.
  Expected and not a failure: the English terms come back transliterated into Cyrillic — that is
  what the dictionary is for (D9a), and H8 is where it gets fixed.
- **H7 — step 2 (c): stop to injection under 2 s for a 60-second utterance.** `bash
  Scripts/measure.sh --stop`, which announces itself because it **delivers text into the session's
  input line** — the interval ends at the last keystroke, so it cannot be measured without typing.
  Speak for about a minute per attempt. Pass: stop → last keystroke under **2 s**. Recognition is
  not what will spend it (66.8 s of speech recognised in 0.42 s), so an attempt over budget is
  pointing at injection or at a model load that should not be happening (D10).
- **H8 — step 2 (d): the TCC prompt appears once, and a rebuild does not bring it back.** On the
  first dictation after `bash Scripts/install.sh` on a machine that has never granted it, pass: the
  system prompt appears **naming dicta**, and its text is the English
  `NSMicrophoneUsageDescription` from `Resources/Info.plist`. Then edit any source file, re-run
  `install.sh`, and dictate again. Pass: **no second prompt**, and the microphone still works. Fail:
  a second prompt — the designated requirement went cdhash-based and every rebuild is revoking the
  grant (D11). `bash Scripts/bundle.sh --print-requirement` is what to read next; it must name the
  identity, not a hash.
- **H9 — step 3: a misfiring rule is nameable from the record alone.** Uncomment the deliberately
  wrong rule at the bottom of `docs/replacements.example.conf` (`misfire`, which rewrites an
  ordinary Russian word), copy the file into place, and dictate **one** sentence containing that
  word. Pass: reading `dictactl last --recognised`, `dictactl last` and the entry's `rules` field —
  and **nothing else, with nothing re-run** — the user can name `misfire` as the rule that did it.
  Fail: needing to re-dictate, to bisect the file, or to guess, which means the record is not
  carrying enough to diagnose with.
- **H11 — step 6: push-to-talk, criteria (a)-(e), in a real pane.** With the daemon installed and
  running, in a session running **Claude Code**: (a) hold right Control, speak a sentence with a
  pause in the middle, let go. Pass: the text arrives in that session's input line, unsubmitted, and
  no chord was pressed. (b) Type `⌃C` and a few other right-Control combinations at ordinary speed.
  Pass: `dictactl last` still shows the dictation from (a) — nothing was recorded, nothing was
  typed, and no sound played. Fail: an entry with text, which means D21's floor is in the wrong
  place; re-measure the press durations rather than raising the floor by feel. (c) Click into Safari
  and hold right Control for two seconds. Pass: nothing whatsoever — no indicator, no sound, no new
  record entry. (d) Hold right Control, speak, and while still holding it press `⌃⌥⇧D`; then let go.
  Pass: raw text arrives, and the release is silent — no "nothing to stop" and no `Basso` (D23).
  (e) Press `⌃⌥C` to open the `claude-ask.sh` picker, and while it is open hold right Control and
  speak. Pass: **nothing** is typed into the session behind the dialog, and a notification says the
  picker is open (D24). Fail, and this is the failure the item exists for: the picker stays empty
  and the words appear in the terminal underneath it, where they were not aimed and where nobody
  was looking.
  **While you are here, if Acta is convenient.** This item is the only place real dictations get
  made deliberately, and the sibling project's correlation stage (D25) has never once seen a true
  positive: across every meeting processed 16-23 August, no dictation and no recording overlapped in
  time, so its text matching is proven on synthetic data only. Starting a short Acta recording and
  dictating one sentence into it during (a) produces the artefact that closes that gap. Not a pass
  condition here and not dicta's problem if skipped — it costs one minute and is worth taking while
  the microphone is already in your hand.
- **H13 — dictation into the picker, which is the whole reason `dictate` exists.** Change
  `~/.config/agterm/claude-ask.sh` to collect its prompt by dictation:
  `PROMPT=$(dictactl dictate) && agtermctl pick --query "$PROMPT" --allow-custom`. Then press ⌃⌥C,
  hold right Control, speak a sentence, let go. Pass: the picker opens with your words already in
  the query field, editable, and **nothing was typed into the terminal** at any point. Then run it
  again and say nothing.
  **The second half is already scored and PASSED**, 2026-08-23, against the built binaries rather
  than a fake: `dictactl dictate --timeout 2` with nobody speaking exits **4**, prints **nothing**
  on stdout, puts "nobody dictated anything within 2 s" on stderr, and the `&&` in the idiom above
  correctly skips opening the picker. So the words "nobody dictated anything" cannot become the
  user's prompt, which is what would happen if the client wrote its reasons to stdout (D29).
  What is left for a person is the half that needs a voice: that real speech reaches the query field
  and that **nothing is typed into the terminal** at any point.
- **H14 — step 6 (f): the gesture on the laptop's own keyboard.** F6a measured which bits the
  built-in keyboard reports and nothing more; that right Command actually dictates through the whole
  pipeline is a different claim, and this is the item that scores it. **Unplug the external keyboard
  first** — with it attached, right Control is still available and a pass proves nothing about the
  laptop. Then, in a session running Claude Code: (a) hold right **Command**, speak a sentence, let
  go. Pass: the text arrives in that session's input line, unsubmitted. (b) Type `⌘V`, `⌘K` and a
  few other right-Command combinations at ordinary speed. Pass: `dictactl last` still shows the
  dictation from (a) — nothing recorded, nothing typed, no sound. Fail: an entry carrying text,
  which means D21's floor no longer clears this keyboard's presses; F6a measured 126 ms for this
  key against a 300 ms floor, so re-measure with a probe rather than raising the floor by feel.
  (c) With agterm frontmost, hold right Control — the key this keyboard does not have — by pressing
  where it would be on an external one. Pass: nothing, obviously, and it is worth doing once so the
  absence is observed rather than assumed.
  **Known and deliberately not a failure:** `⌘Tab` held with the RIGHT hand inside agterm opens the
  microphone for the length of the app switch and produces an attempt with no text. Nothing is typed
  anywhere. If that turns out to be a daily nuisance rather than a curiosity, the answer is
  `--hold-key rightOption` in the LaunchAgent, not a change to the floor.
- **H12 — the frontmost reading TRACKS, rather than merely answering.** Scored 2026-08-23 and it
  **FAILED**, which is the whole reason this item was written the way it was; F8a records the
  measurement and the fix is the activation observer in `SystemFrontmost`. It stays as a regression
  check, because nothing automatic can reach it.
  After `bash Scripts/install.sh`, read the daemon's log for `push-to-talk is armed on the right
  Control key and the right Command key`. Then switch applications — agterm, a browser, Finder, agterm — and, at each stop,
  hold right Control for two seconds. Pass: it dictates in agterm and does nothing at all in the
  other two, **every time round**, including after the daemon has been running for hours.
  **The method is the item.** Do not score this by holding the key only in agterm, and do not score
  it from a log written on each chord: a chord is only ever pressed inside agterm, so that
  instrument returns "agterm" whatever is true and reads as a pass. What failed here was never `nil`
  and never obviously wrong — it was a plausible identifier frozen at whatever was frontmost when
  the daemon started, so the only thing that can catch it is sampling while a **different**
  application is in front.
- **H10 — the daemon's own lifecycle.** Log out and back in. Pass: the daemon is running without
  anyone starting it, and a chord works immediately. Then kill it mid-recording (`kill -9` while
  the indicator is red) and restart it. Pass: the indicator that was claiming a recording is put
  out at startup, so nothing is left saying dicta is listening when it is not (§7).
- **H15 — the glyph tracks the indicator and never leads it.** With the menu app installed, watch
  the menu-bar microphone while dictating: press the chord, speak, press again. Pass: the glyph is
  grey and **carries no clock** until the **agterm indicator turns red**; then it is red with a
  running `0:07` beside it, for exactly as long as the indicator is; amber glyph while the text is
  recognised and typed, and the clock is gone by then; then grey. Fail, and this is the one that
  matters: the glyph goes red, or the clock appears, at the KEYPRESS. That is D13 and invariant 4
  broken in the UI — a user who believes the microphone is open before it is loses the first
  syllable of every dictation, and a running clock is a more convincing liar than a fill, which is
  exactly why the clock is held to the same instant.
  **The method is the item.** Score it by watching the two together in one glance. A glyph checked
  on its own cannot be told from a correct one, because both end up red.
- **H16 — the panel opens without a blank frame.** Click the menu-bar icon repeatedly, on a cold
  daemon and on a warm one. Pass: the header is populated in the first drawn frame every time.
  Fail: a flash of an empty or "Connecting…" panel that then fills in — that is the synchronous
  seeding lost, and it reads as a broken app rather than a loading one.
- **H17 — the fault banners appear, and their buttons fix what they name.** Two runs. (a) Deny the
  microphone in System Settings and restart the daemon. Pass: a red banner naming the microphone,
  with a button that opens the Privacy & Security pane at Microphone — not the top of Settings.
  (b) Move the model cache aside (`~/Library/Application Support/FluidAudio/Models`) and restart.
  Pass: a red banner naming the models, with a button that starts the fetch. Fail in either: the
  panel says "Ready" over a daemon that would refuse the next chord.
- **H18 — a daemon that is not running is not drawn as an idle one, and comes back on its own.**
  **The second half of this item was FALSE when it was written, and that is why it is worded as an
  observation rather than an expectation** (F9b, 2026-08-24): a watcher that attached was told
  nothing until the daemon's next transition, so the strip went on reporting an unreachable daemon
  over a live connection until somebody dictated. It stays as a regression check for exactly that.
  `launchctl bootout gui/$UID/dev.personal.dicta`. Pass: within a second the glyph changes to the
  struck-through microphone and the panel offers to start dicta; the wording says stopped, never
  crashed. Restart from that button, **and then do not touch anything** — in particular do not open
  the panel and do not dictate, since either would hide the failure by causing the event that was
  missing. Pass: the glyph returns to grey by itself within about a second (measured 534–608 ms
  over four cycles). Fail: it returns only after you dictate, or only after you open the panel.
- **H19 — the panel is silent ground, and a hold with it open goes where it would have gone
  without it.** **This item used to expect the opposite**: that an open panel had focus, so agterm
  stopped being frontmost and D22 silenced the key. F11 measured the premise on 2026-09-13 and it is
  false, because opening the panel does not make DictaMenu frontmost. It is reworded as an
  observation for that reason (D30). (a) Over an agterm pane, open the panel and hold right
  Control. Pass: it dictates into that pane exactly as with the panel closed, and **nothing is typed
  into the panel**. (b) Close the panel and hold again. Pass: the same. (c) With `--focused-fields`
  on, open the panel over the VS Code editor and hold. Pass: the text lands in the editor, and never
  in the panel. Fail in any of them: text in the panel, or a hold that does nothing while the panel
  is open over a place it would otherwise dictate into, which would mean something has started
  treating dicta's own bundle as frontmost.
- **H20 — a dictation that went nowhere is recoverable from the panel, with no terminal.** This is
  the whole of job 2 and the only reason the drawer exists. Make one fail on purpose: start a
  dictation in a session, speak a sentence, close that session's pane while still speaking, then
  press stop. Pass: a notification says the target is gone, and the panel's top row is red, labelled
  `target gone`, showing the sentence you said, with a copy button beside it that puts exactly that
  text on the clipboard — paste it somewhere and compare it word for word. Then run
  `dictactl last` and check the two agree. Fail, and it is the failure worth looking for: the row
  is there but the copy button is missing, which means `final` was empty and the text you can see
  is `recognised` — recoverable by eye and not by clipboard, which is not recovery.
  **Score the pair below in the same run, because they are the confusion this row is built around.**
  (a) Abort a dictation mid-sentence (`dictactl abort`, or the panel's `Abort`). Pass: the row shows
  what you said, in italic, labelled `cancelled · recognised only`, and has **no copy button** —
  D26 wrote the speech down and D28 refuses to hand back words that were deliberately not
  delivered. (b) Let a `dictate` call complete (`dictactl dictate` from a shell, speak, let it
  print). Pass: that row is **green**, labelled `returned to caller`, and **does** have a copy
  button. Fail: the two drawn alike. They look alike from the outcome's name and are opposites in
  the one field that decides — `final` — which is exactly the mistake this item is here to catch.
- **H21 — `Stop and type` from the panel lands where the chord was pressed, not where focus is
  now.** D4, through the one door a click could open. Start a dictation with the chord in session A,
  speak, then click into a **different** session B, and only then open the panel and press
  `Stop and type`. Pass: the text arrives in **A**'s input line, unsubmitted; the target line above
  the button read A's name and pane the whole time. Fail: it arrives in B, which is the forbidden
  substitution reached through a button rather than through a re-resolution.
  Second half, and it needs the timing to be deliberate: start a dictation, let it end on its own
  (the release of a held key, or a second chord) **while the panel is open**, then press
  `Stop and type` on the controls before they disappear. Pass: nothing at all happens — no sound, no
  keystroke, no new entry in `dictactl last`. The click names a spent attempt and §6 makes that a
  silent no-op. Fail: a second dictation starts, or a newer attempt in another session is stopped —
  either would mean the button is not naming the attempt it is looking at.
- **H22 — the strip is honest without anyone opening the panel, which is the normal case.** Written
  after the finding that produced the menu-bar clock: during a dictation the user's eyes are in the
  pane being dictated into, so the panel's copy of the timer is seen by nobody, and the item itself
  is the whole instrument.
  (a) Log out and back in, or `launchctl kickstart -k gui/$UID/dev.personal.dicta.menu`. Then, **without
  ever clicking the menu-bar item**, dictate with the chord. Pass: the clock appears beside a red
  microphone and counts, and both go when the text lands. Fail: the item never changes — which was
  the state of the build on 2026-08-24, when the watch stream was opened by the panel's own `.task`
  and therefore by the first person to open the panel and by nobody else. `lsof -p <menu pid> | grep
  -c unix` returning **0** on a freshly launched menu is the same failure, checkable without a
  dictation.
  (b) **Scored 2026-08-24 and PASSED**, by the user who raised the finding that produced the clock:
  the strip is noticed while working, without deciding to look at it. That closes F9 — the width
  change carries where the fill change did not — and the item stays as a regression check, because
  the failure it guards against is silent and only a person can see it.
  Watch the strip out of the corner of your eye while working normally, for a few dictations.
  Pass: you notice the item change without having decided to look at it — the icons to its left
  shift as the clock appears and goes, which is the change peripheral vision actually reads. Fail:
  you only ever notice it when you deliberately look, which is the finding this item exists to close
  and means the width change is not carrying.
  (c) With **another** application holding the microphone (a call, a recorder), dictate. Pass: the
  system's own microphone indicator is lit throughout and tells you nothing, while dicta's clock
  appears and goes with the attempt. That disambiguation is the one job the system indicator cannot
  do, and it is the reason this item is not redundant with it.
- **H23 — the icon is drawn where the icon is actually met, which is not the dock.** Both bundles
  carry `AppIcon.icns` and neither has a dock tile, so every place it can be seen is a list macOS
  builds for its own reasons. `NSWorkspace.icon(forFile:)` was asked directly on 2026-09-09 and
  returned the artwork for both bundles, byte-identical — but LaunchServices answering a program is
  not the same as a person seeing it, and the icon cache is exactly the layer that lies.
  (a) Open **System Settings → Privacy & Security → Microphone**. Pass: `Dicta` is listed with the
  waveform icon beside its toggle. Fail: a blank sheet of paper — which means the cache is stale
  (`killall Dock`, or log out and in) or that the installed bundle predates the icon.
  (b) Open `~/Applications` in Finder. Pass: `Dicta.app` and `DictaMenu.app` both show the icon, at
  the same size as their neighbours rather than visibly larger — the artwork is inset to Apple's
  824-on-1024 grid precisely so it does not tower over the applications around it.
  (c) The negative half, and the one worth being deliberate about: dictate, and while it runs check
  the dock. Pass: nothing appeared there. §13 rules out a dock TILE, not artwork, and `LSUIElement`
  is what enforces it — an icon in the dock would mean the flag was lost, and a stray click on that
  tile takes focus from the terminal dicta is about to type into.
- **H24 — the VS Code editor receives exactly what the record says was sent (D31, D32).** Install
  with `bash Scripts/install.sh --focused-fields`, grant Accessibility, and quit and relaunch VS
  Code so the first dictation is the one that sets `AXManualAccessibility`. (a) Open a plain-text
  file, click into the editor, hold right Command, wait for `Pop`, speak a sentence of Russian with
  English terms and some punctuation in it, and let go. Pass: `Tink`, and the text appears at the
  cursor. Copy it back out and compare it with `dictactl last` character for character. Fail: a
  character missing, doubled or reordered, a closing bracket or quote VS Code added, a suggestion
  accepted in the middle of the text, or `Basso` on this very first dictation — which means the
  element was still absent after `AXManualAccessibility` was set and the re-read came too early.
  (b) Repeat in a JavaScript file with a long dictation. Expected, and not a failure: VS Code stops
  responding for several seconds while it catches up, and the text is still identical (F11). Time
  the stall; F11 did not. (c) The side effect D31 states: over a working day after (a), watch for VS
  Code announcing a screen-reader mode, or being visibly slower in a large file. F11 checked this
  briefly and saw nothing, so write down what you saw either way. (d) End a dictation on a
  half-typed word and look before pressing anything. Expected: an autocomplete popup may be open,
  and Return would accept it (F11). Not a failure of dicta, but it is the one to know about before
  pressing Return by reflex.
- **H25 — the VS Code integrated terminal, with Claude Code running in it.** Click into the terminal
  pane, hold right Command, speak two sentences, and let go. Pass: both sentences arrive on Claude
  Code's input line as **one unsubmitted line**, identical to `dictactl last`. Fail, in the way that
  matters most: the prompt submits by itself, which is invariant 1 broken on the new path. (b) The
  per-event limit: F11 measured events of 200 UTF-16 units accepted whole in the VS Code editor only.
  Add a dictionary rule whose replacement is one grapheme longer than 20 UTF-16 units, such as a
  family emoji with skin tones, which `KeystrokeChunks` sends as a single event, and dictate its
  pattern. Pass: the emoji arrives whole. This exercises an event over the soft target and not the
  full 200. Repeat (b) in H26 and H27 before the hard limit is relied on anywhere but the editor.
- **H26 — Slack.** The first dictation after Slack launches, into a message field. Pass: the text
  arrives, and **nothing is sent**, because Return was never pressed. Expected, and not a failure:
  Slack's own rewrites, which are straight quotes turned curly, emoji shown as shortcodes when
  copied out, and a combining accent normalised (F11). Fail: a missing word, or a message posted.
- **H27 — Safari.** Dictate into a text area on any page. Pass: identical to `dictactl last`. If
  Telegram is installed, repeat in its message field, where F11 saw the same.
- **H28 — the grant is asked for once, is picked up live, and its loss stops delivery.** Score it
  with no Focus mode on, then (e) with one. (a) `tccutil reset Accessibility dev.personal.dicta`,
  then restart the daemon with `--focused-fields` (`launchctl kickstart -k
  gui/$UID/dev.personal.dicta`). Pass: the system's Accessibility dialog appears once, at start-up,
  and `Dicta` is now listed under System Settings → Privacy & Security → Accessibility, switched off.
  Leave it off and hold right Command in VS Code past the floor. Pass: `Basso` and a notification
  naming the Accessibility grant; the orange microphone dot never lights; nothing is typed. (b) Turn the grant on **without restarting anything** and hold again.
  Pass: it dictates. (c) Edit any source file, run `bash Scripts/install.sh --focused-fields` again,
  and dictate. Pass: no new prompt, and it still dictates. (d) Start a dictation in VS Code, turn the
  grant off while still speaking, then let go. Pass: nothing is typed, a notification says nothing
  was inserted, and `dictactl last` has the text. Fail: part of the text typed, or a notification
  saying the target is gone, which would be claiming something nobody established. (e) With a Focus
  mode on, repeat (a). Pass: `Basso` is heard. The notification is expected to be missing (F11), and
  that is the limit D31 states.
- **H29 — Secure Input refuses before the microphone opens.** (a) Click into a Safari password
  field, hold right Command past the floor, and speak. Pass: no orange microphone dot, `Basso`, a
  notification with the reason, and not one character in the field. (b) Secure Input held by
  **another** process while an ordinary field is focused. `ioreg -l -w 0 | grep
  kCGSSessionSecureInputPID` names the holder. Find something that leaves it on after losing focus,
  confirm with that command, then hold in a VS Code editor. Pass: refused with the same reason. F11
  could not reproduce a stuck holder, so if none can be found, write "not reproduced" rather than
  scoring (b) as passed.
- **H30 — a focused thing that is not a text field receives nothing.** Hold past the floor and speak
  with focus on each of: (a) the VS Code Explorer tree, after clicking a file in the sidebar; (b) a
  Safari page after clicking a button on it, so that focus stays on the page; (c) a Finder file list.
  Pass in every one: no orange microphone dot, `Basso` and a notification, and **no side effect of
  typing**. That means no file selected by type-to-select, nothing renamed and no page shortcut
  fired. Fail: any of those, which would be dicta acting as voice control (§1). (d) If an application
  can be found whose focused element cannot be read at all, even after the first dictation set
  `AXManualAccessibility`, repeat there. Pass: refused the same way. F11 found none, so "none found"
  is an honest result.
- **H31 — focus moving around a delivery never takes the text to another application.** (a) Before
  delivery, inside one application. With an external keyboard, hold right **Control** in the VS Code
  editor, speak, then press the backtick key while still holding it, which is VS Code's toggle-
  terminal shortcut and moves focus to the terminal. Then let go. Pass: nothing is typed in the
  editor or the terminal, a notification says the target is gone, and `dictactl last` shows the text
  with outcome `target-gone`. (b) Another application, around delivery. A delivery takes tens of
  milliseconds (F11), so a hand cannot aim at the inside of one, and this item is scored by its
  result instead. Ten times over: dictate a long sentence into the VS Code editor, let go, and switch
  to TextEdit with the **left** hand as the text is about to land. Pass: **no character ever appears
  in TextEdit**. Each run ends in one of three ways, so record which: arrived whole in VS Code before
  the switch; aborted silently, because the switch landed inside the settle window (D31); or stopped
  part-way, with a notification that the insertion may be partial and nothing retried. (c) Inside
  one application during delivery. Repeat (b) with the toggle-terminal shortcut instead of switching
  applications. If a run ever splits the text between the editor and the terminal, that is §7's
  stated limit observed, not a failure. Record it, because nobody has seen it yet.
- **H32 — right-hand combinations released before the floor cost nothing, and a switch costs no
  text.** With `--focused-fields` on, note `wc -l` of `record.jsonl`. (a) For a few minutes in VS
  Code and in Safari, use right-hand `⌘C`, `⌘V`, `⌘Z` and `⌘S` at ordinary speed. Pass: no sound, no
  notification, no orange microphone dot at any moment, and `record.jsonl` has exactly as many lines
  as before. Fail: a single new line, which means something was sent before the floor. (b) Hold
  right Command, press Tab, choose another application at ordinary speed, and let go. Pass: no text
  anywhere, no sound, no notification. The microphone opening for the length of the switch, and an
  `aborted` line in the record, are expected, because the hold passed the floor (D31). Fail: a
  `Tink`, or text in either application. (c) Over an ordinary day, count the held-past-the-floor
  combinations that did start an attempt, which are the `aborted` lines with no speech in them. That
  number is what decides whether the floor-deferred start was the right price.
- **H33 — a machine without agterm.** (a) On a user account where `agtermctl` is not on `PATH`,
  install with `bash Scripts/install.sh --focused-fields` and run `Dicta --fetch-models`. Pass: the
  daemon runs, its log says agterm is absent, the menu-bar panel shows that as a notice and not as a
  fault, and a hold in the VS Code editor dictates. (b) Reinstall without the flag. Pass: the daemon
  refuses to start and says `agtermctl` is missing, because nothing could be delivered. (c) With
  agterm itself installed, the option on, and `agtermctl` moved off `PATH` before restarting the
  daemon: press a chord, then hold the key with agterm frontmost. Pass: both are refused, with a
  reason naming `agtermctl`, and a hold in VS Code still dictates. Put `agtermctl` back afterwards.
- **H34 — the delivery bound refuses before the first keystroke.** (a) Add a dictionary rule whose
  replacement is longer than the bound, meaning more UTF-16 units than the chunk limit times the
  per-event limit, both constants in `KeystrokeChunks`. Dictate its pattern into a VS Code editor.
  Pass: not one character is typed, a notification says nothing was inserted, and `dictactl last`
  prints the whole expanded text. Fail: a prefix of the text typed, which means the bound was
  checked after posting began. (b) The same with a replacement that is a single grapheme longer than
  one event may carry: one letter followed by a few hundred combining accents. Pass: the same.
