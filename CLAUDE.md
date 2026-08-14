# CLAUDE.md — dicta

Voice dictation into **agterm**'s input line: press a chord, speak, press again, the text appears
where you were typing. Primarily for dictating prompts to Claude Code and instructions to agents
running inside agterm. Everything is local; the audio never leaves the machine.

`SPEC.md` is normative — decisions are cited as D*, measurements as F*, invariants as §8. This file
is the operating manual: what to run, what the environment actually is, and the rules that are
expensive to relearn.

## Language convention

**English only, across the whole project, with no exceptions** — code, comments, docs, scripts,
commit messages (Conventional Commits), notifications, client output, test names, and
`NSMicrophoneUsageDescription`.

This is SPEC.md's rule and it replaces the earlier "user-facing strings are Russian" carve-out that
the deleted skeleton (`3dda6cb`) followed. The reasoning is mechanical, not aesthetic: an exception
for "user-facing" strings turns every new string into a judgement call about which side of the line
it falls on, and it disarms the one automatic check available. `Scripts/lint.sh` greps for Cyrillic
and fails on a hit — that is only a gate when there is nothing legitimate for it to find.

Conversation about this project is in Russian. The repository is not.

## Where it stands

**The plan `docs/plans/20260814-dicta-steps-1-3.md` is finished — all thirteen tasks. Steps 1–3 of
SPEC.md §10 are built and their automatable half is green; steps 4 (the external filter) and 5 (the
§7 sweep) are not started. What remains of steps 1–3 is what only a person can score: the chords in
a real pane, the TCC prompt, criteria (a)–(d) of step 2, and step 3's deliberate misfire — each
written with its pass condition in `docs/manual-checklist.md`.** `DictaCore` holds
the wire types, `Paths`, the sanitiser, the lifecycle state machine, the §9 record schema,
`RecognisedText` and the replacement engine; `DictaIPC` holds both halves of the control socket;
`dictactl` speaks all six verbs
and `docs/keymap.snippet.conf` is checked by a test against the parser the binary uses.
`DictaRuntime` holds the six seams with their fakes, the `agterm` adapter — target resolution off
`agtermctl tree --json`, injection, §6's indicators, notifications, all behind a `CommandRunner`
seam — `AudioCapture`, `ParakeetTranscriber`, and `Daemon`, which wires the socket, the state machine
and the seams into whole attempts.

`Dicta` is a real daemon with **no fakes left on its path**: it serves the socket, refuses a second
instance, resolves the pane from the live tree, records at 16 kHz mono through `AudioCapture`,
recognises through `ParakeetTranscriber` (Parakeet TDT 0.6B v3 on the ANE, via FluidAudio pinned at
`exact: "0.15.5"`), and delivers the result as one sanitised line. Every attempt leaves one entry in
`record.jsonl` (`History`, `FileHistory`), written **before** the keystrokes, and `dictactl last`
reads it back — `final` by default, `recognised` verbatim behind `--recognised`.

The models are loaded and given one dummy inference at daemon start, on a thread of their own, and a
missing bundle is reported at startup with the command that fixes it. The remaining fake behind a
seam is `NoFilter`, which is what D9c says v1 ships.

`Scripts/bundle.sh` produces a signed `Dicta.app` and `Scripts/install.sh` installs it as a user
LaunchAgent. That is deliberately ahead of the microphone: if the bundle identity were wrong, every
measurement taken afterwards would be taken against a grant that evaporates on the next rebuild.

The Tier 0 replacement dictionary is in, and the probe below turned D9a from a guess into a
measurement: Parakeet **transliterates English technical terms spoken inside Russian into Cyrillic**,
so "FluidAudio" and "Package Swift" come back spelled phonetically in the Cyrillic alphabet. That is
exactly the class of mistake the dictionary exists to undo, and it is now observed rather than
assumed. `Replacements` parses and applies the rules in `DictaCore`, `FileDictionary` re-reads the
file per attempt so an edit fires on the next chord, and the ids that fired land in the record's
`rules` — which is what makes a misfire nameable without re-running anything.

Two audits close the plan and are themselves checked by a test (`ChecklistTests` parses SPEC.md and
`docs/manual-checklist.md` against each other and against the suite's own `@Test` names): every §8
invariant against the assertion that goes red first, and every §7 row against a test or a named
human item. Invariant 8 — the keypress client never opens the microphone — is the one no assertion
can reach, so `Scripts/linkage.sh` reads it off the linked binary and `Scripts/test.sh` runs that
first. `Scripts/coverage.sh` holds `DictaCore` to a floor of 80% (measured 99.33% of lines).

The plan covered steps 1–3 of SPEC.md §10. Steps 4 (the filter) and 5 (the §7 audit) are the next
work, and neither is begun: the `Filter` seam is `NoFilter`, and nothing invokes a subprocess.

## Commands

- Build: `swift build` / `swift build -c release`
- **Tests: `bash Scripts/test.sh`** — the only gate. See the next section before reaching for
  `swift test`.
- Lint: `bash Scripts/lint.sh` — runs SwiftLint if it happens to be installed, and its own
  mechanical checks (Cyrillic, tabs, line length, trailing whitespace, script permissions) always.
  Each check was probed with a file that should trip it; two of them were silently passing until
  that probe, which is the same lesson as D18 in a different costume.
- Run the daemon in the foreground: `bash Scripts/run.sh` — the development path, with no bundle and
  therefore no stable TCC anchor. Useful for everything except the microphone; not how the installed
  daemon runs.
- Fetch the recognition models, once: `Dicta --fetch-models` (or
  `./Dicta.app/Contents/MacOS/Dicta --fetch-models`). It downloads into FluidAudio's own cache,
  re-runs the self-check over the result, and exits. The daemon deliberately never does this at
  start-up — see the rule about it below.
- Score the criteria: `bash Scripts/measure.sh` for step 2 (a) — types nothing into a pane — and
  `bash Scripts/measure.sh --stop` for step 2 (c), which **delivers** text into the session's input
  line, once per attempt, because the interval being measured ends at the last keystroke.
- Build and sign the bundle: `bash Scripts/bundle.sh` → `./Dicta.app`; `bash Scripts/bundle.sh
  --print-requirement` prints the designated requirement of an existing one.
- Install everything: `bash Scripts/install.sh` — `dictactl` to `~/.local/bin`, the signed bundle to
  `~/Applications/Dicta.app`, the LaunchAgent to `~/Library/LaunchAgents/dev.personal.dicta.plist`,
  then bootout/bootstrap/kickstart. It never touches `~/.config/agterm/keymap.conf`.
- One-time signing setup: `bash Scripts/setup-signing.sh` — idempotent, non-interactive, and called
  by `bundle.sh` on its own when the identity is missing, so it is rarely run by hand.
- One suite only: `bash Scripts/test.sh --filter "sanitiser"` (arguments pass through to
  swift-testing).
- Coverage of `DictaCore`: `bash Scripts/coverage.sh` — drives the profile through the runner's own
  entry point, because `swift test --enable-code-coverage` builds an instrumented bundle it never
  runs (D18 again). Exits non-zero under an 80% floor; `--floor <n>` moves it.
- The linkage budget: `bash Scripts/linkage.sh` — asserts `dictactl` binds no AVFoundation, CoreML
  or AppKit, by load command, undefined symbol and DictaRuntime's own mangled names. `test.sh` runs
  it first, since no swift-testing assertion can reach a linked binary (invariant 8, D12).

## Why the test runner exists (D18) — measured, not assumed

Under Command Line Tools only, `swift test` **builds** the test bundle and never **runs** it: there
is no `xctest` host utility. Observed in Task 1 (2026-08-14) with one deliberately failing test:

| command | failing test present | exit code | what it printed |
|---|---|---|---|
| `bash Scripts/test.sh` | yes | **1** | `Test run with 4 tests in 1 suite failed ... with 1 issue` |
| `swift test` | yes | **0** | `Build complete!` — and no test run at all |

So `swift test` cannot gate anything here, and a test written under `Tests/DictaTests` would report
as passing while never having run. Two guards keep that from happening by accident:

- `Tests/DictaTests` is deliberately **denied** the swift-testing flags in `Package.swift`, so
  `import Testing` there does not compile;
- `import XCTest` does not compile either — XCTest ships with Xcode, not with the Command Line
  Tools (also observed in the same experiment).

To reproduce the table, temporarily add `swiftSettings: testing.swift, linkerSettings:
testing.linker` to the `DictaTests` target — otherwise the failing test cannot even be compiled.

## Environment facts (verified 2026-08-14, not assumed)

- Swift 6.3.2 (`swiftlang-6.3.2.1.108`), target `arm64-apple-macosx26.0`. macOS 26.6 (25G72).
- **Command Line Tools only, no full Xcode**: `xcode-select -p` →
  `/Library/Developer/CommandLineTools` (CLTools_Executables 26.5.0.0); `xcodebuild` exists on PATH
  but refuses to run, saying it requires Xcode. This is the root of D18 and of
  `swiftTestingSettings()` in `Package.swift`.
- `agtermctl` is on PATH at `/opt/homebrew/bin/agtermctl`; `agtermctl tree --json` answers with
  `{"ok":true,"result":{"tree":{"workspaces":[...{"surfaces":[{"kind":"left","id":"surface:…"}]}]}}}`
  — surfaces carry `kind` and `id`, which is what pane resolution reads (§5).
- **SwiftLint is not installed** and nothing here installs it; `Scripts/lint.sh` degrades to its own
  checks. Do not add a global install to make a linter run.
- **F3 — the installed agterm does not export `$AGT_PANE`** to custom keymap commands. Available:
  `AGT_SESSION_ID`, `AGT_SESSION_NAME`, `AGT_SESSION_PWD`, `AGT_WORKSPACE_ID`, `AGT_WORKSPACE_NAME`,
  `AGT_WINDOW_ID`, `AGT_WINDOW_NAME`, `AGT_SELECTION`, `AGT_SOCKET`. The pane therefore comes from
  the live tree, not from the keypress (D6, §5).
- **F4 — warm keypress cost, client invocation → "recording": 20–70 ms** (client alone 9 ms,
  `agtermctl tree --json` 38 ms; cold start ~390 ms). Measured on the deleted skeleton `3dda6cb`;
  re-measured properly by `Scripts/measure.sh` in Task 9. The budget is 150 ms.
- **F2 — `claude -p` costs 8.6–10.5 s of fixed startup** per invocation. It cannot be the filter,
  which is why v1 ships the seam empty (D9c).
- **Recognition, measured on this machine (M3 Pro) with a throwaway probe in Task 10, since no unit
  test can establish any of it.** The probe fed real audio through `AudioCapture.convert` into
  `ParakeetTranscriber`, i.e. dicta's own path with only the daemon left out.
  - **Model load: ~17 s the first time a given binary runs, ~0.2 s every time after.** The 17 s is
    CoreML compiling the int8 encoder for the ANE, and its cache is keyed per binary — so *every
    rebuild pays it once*, including a rebuilt `Dicta.app`. Observed twice: the signed bundle's first
    start reported 17.1 s and its second 0.2 s. This is why the warm-up runs on its own thread after
    the socket is bound rather than before it.
  - **Dummy inference: 0.07–0.13 s.** One second of silence, which is what buys the first real
    dictation out of paying ANE compilation (§12).
  - **Recognition: 5.6 s of speech in 0.11 s; 66.8 s in 0.42 s.** Step 2's criterion (c) allows 2 s
    for stop-to-injection, so recognition is not what will spend it.
  - **Quality: Russian is recognised correctly with punctuation, and English technical terms spoken
    inside it come back transliterated into Cyrillic** — the measurement that makes D9a's Tier 0
    dictionary a fix for something observed rather than something imagined.
- **The models are FluidAudio's own cache, and the folder is not named after the repository.** The
  HuggingFace repo is `parakeet-tdt-0.6b-v3-coreml`; the cache folder strips the suffix, giving
  `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3`. `ParakeetModels.directory`
  asks the library rather than spelling it out, and the required file names come from
  `ModelNames.ASR.requiredModelsV3` for the same reason: a hand-typed list one directory off reports
  "the models are missing" against a directory that is complete.
- **FluidAudio's README is ahead of the released API.** v0.15.5's `AsrManager.transcribe` takes an
  `inout TdtDecoderState` the docs do not mention, and there is no `configure(models:)` — it is
  `loadModels(_:)`. Hence `exact: "0.15.5"` in `Package.swift`.
- **`agtermctl session type` injects real keystrokes with no bracketed paste** — every `\n` is a
  Return that SUBMITS the input line. This is the single most dangerous fact in the project and the
  entire reason `Sanitizer` exists (D8, invariants 1–2).
- **The signature is identity-based, and that was verified by rebuilding (Task 8, 2026-08-14).**
  `Dicta.app` signed by `Scripts/bundle.sh` reports
  `designated => identifier "dev.personal.dicta" and certificate leaf = H"3dcb99…"`. Changing a
  string literal in `Sources/Dicta/main.swift` and rebuilding moved the cdhash
  (`6764650c…` → `acc55018…`) and left the requirement **byte-identical** — which is the property a
  surviving TCC grant rests on (D11). The contrast was measured too: the same bundle re-signed with
  `codesign -s -` reports `designated => cdhash H"…"`, so every rebuild would revoke the grant.
  `bundle.sh` fails on that string rather than trusting the intent. Note codesign comments the line
  out (`# designated => …`) precisely when the requirement is implicit, i.e. ad-hoc — a parser that
  does not strip the `#` reports "not signed" instead of "ad-hoc" and sends you looking in the wrong
  place.

## Structure

- `Sources/DictaCore/` — **pure, no I/O**: the lifecycle state machine, the sanitiser, the
  replacement engine, the record schema, the wire types, `Paths`. Anything worth asserting is here.
- `Sources/DictaIPC/` — the Unix-socket transport, **both halves in one module** so the two ends'
  framing cannot drift. Split from `DictaRuntime` for one concrete reason: `dictactl` needs the
  client half, and `DictaRuntime` is where AVFoundation and CoreML land — without the split every
  keypress would drag the capture stack through dyld.
- `Sources/DictaRuntime/` — everything that touches the world: `Agterm` (subprocesses),
  `AudioCapture` (AVAudioEngine), `ParakeetTranscriber` (FluidAudio/CoreML), the daemon, the record
  writer, and the seams (`Capture`, `Transcriber`, `Filter`, `Injector`, `Notifier`, `Clock`). The
  **fakes** behind those seams live in `Sources/DictaTestRunner/Fakes.swift`, not here: the reason
  they were in the library — that the `Dicta` executable could bring the daemon up on fakes — died
  when `main.swift` started wiring the real capture, transcriber and terminal, and `FakeTranscriber`
  emits deliberately hostile text that has no business being reachable from the binary that types
  into a terminal. **The only module that links FluidAudio**, which is the whole of D12's budget:
  `dictactl` cannot reach it even by accident, because it does not depend on this target.
  `ParakeetTranscriber.swift` is in turn the only file that knows FluidAudio exists — everything else
  sees `RecognitionEngine`, which is what makes "the models load exactly once" a countable assertion.
- `Sources/Dicta/` — the daemon executable. Wiring only.
- `Sources/dictactl/` — the client the keymap invokes. **DictaCore + DictaIPC and nothing else**,
  and it never opens the microphone: the TCC grant belongs to the daemon's signed bundle, and a
  second binary opening the device would fracture it (D11, D12, invariant 8).
- `Sources/DictaTestRunner/` — where the tests actually are.
- `Tests/DictaTests/` — a compile-only stub. Never put an assertion here (see D18 above).

**The structure rule: a decision goes into `DictaCore` as a pure value, its I/O into
`DictaRuntime`, its test into `DictaTestRunner`** (D19).

## Rules worth not relearning

Distilled from SPEC.md §3. Each one is a mistake already made, or one the spec exists to prevent.

- **One sanitiser, on every path** (invariant 1). Clean, raw, and the fallback to **replaced** after
  a filter failure all pass through it immediately before injection. It is *last* because the
  dictionary and the filter can both introduce a newline. A path that walks around it submits a
  half-written prompt — the first draft of the skeleton leaked exactly there. Reading text back out
  of the record is not injection and is exempt (§9).
- **raw mode skips the filter and nothing else** (§2, D3). It is not "unsanitised" and not
  "unreplaced"; both of those readings are wrong.
- **`FakeTranscriber` returns deliberately hostile text** — a newline, a double space, a trailing
  space. If the sanitiser is ever bypassed, the canned transcript submits the prompt loudly and
  immediately. Do not tidy it up.
- **The toggle resolves inside the daemon, atomically** (D7). `status | grep idle && start || stop`
  is two round trips with a race between them, in which one keypress can both start and stop.
- **Nothing is announced before capture confirms it is running** (D13, invariant 4). Announcing at
  keypress trains the user to speak before audio flows and lose the first syllable every time.
- **A dead target is never replaced by the focused one** (D4, invariant 3). If the captured target
  is gone, the text goes to the record plus a notification. Injecting into whatever has focus now
  means somebody else's agent gets your prompt.
- **A capture fault always discards, and is never reported as silence** (D16, invariants 6–7). The
  audio boundary is in doubt, so the recording dies rather than being guessed at. A fault while
  *stopping* is the row most likely to be mistaken for an empty dictation.
- **The duration cap stops and does not inject** (D15). Ten minutes of forgotten speech landing in
  an agent's prompt is worse than losing it; whatever text was produced still reaches the record.
- **Recognised text reaches the record before injection is attempted** (invariant 10). That is the
  only route by which text survives a delivery failure. The consequence is easy to get wrong: the
  outcome of an attempt is not known until the keystrokes have been tried, and the file cannot be
  rewritten, so a delivery that fails appends a **superseding line with the same attempt id** and
  `Record.entries` takes the last line per id. "One entry per attempt" is a property of the reader;
  the file itself is append-only. Do not "fix" this by writing the entry after the injection — the
  test `the entry is on disk before the first keystroke is attempted` exists to catch exactly that,
  and it was probed by making it fail.
- **A failing record append never blocks a delivery** (§7). It injects, then says loudly that
  recovery is unavailable — in that order, because a complaint arriving first reads as a refusal.
- **A rejection is audible; a no-op is silent** (§6). Pressing stop again because nothing visibly
  happened is normal behaviour, and an alarming noise would punish it.
- **Cancellation is refused once injection has begun** (D20). Keystrokes already in the terminal
  cannot be recalled.
- **Injection is never retried** (§7). A retry after keystrokes have begun would double part of the
  text; the notification says the insertion *may be partial* and stops there.
- **Every `agtermctl` flag goes BEFORE `--`, and the text after it.** `session type` declares
  exactly one positional, so an argument appended past the separator — `--socket "$AGT_SOCKET"`,
  which the keymap snippet passes on every chord — becomes `Error: 2 unexpected arguments` and
  nothing is typed. Worse than the failure is how it reads: that exit carries no `{"ok":false}`, so
  `Agterm.refusal(in:)` finds nothing and the attempt is classified `mayBePartial` — the user is
  warned the insertion may be partial and told not to re-paste, when in truth not one keystroke was
  sent. `Agterm.withSocket` splices the socket in front of the separator for that reason, and
  `notify` puts its message after one so a reason beginning with a dash is a message and not a flag.
- **`.announce(.working)` is emitted before `.drainCapture`, and the order is load-bearing.** The
  real `AudioCapture` hands the audio over from *inside* `drain`, so `.drainCapture` re-enters and
  runs recognition, injection and the terminal `.announce(.done)`/`.announce(.blocked)` before the
  effect list gets its next turn. With `.working` second, that terminal announcement is immediately
  overwritten by amber — and `active` carries no `--auto-reset`, so a finished dictation left the
  session looking busy for ever and a failed one lost its red. `FakeCapture` deliberately does not
  deliver by itself and therefore cannot see this; `ImmediateCapture` has the real semantics, which
  is what the test `a capture that drains from inside drain still ends on the done indicator` uses.
- **A toggle that means "stop" is sent as `.stop`, carrying no target.** `currentAttempt` and
  `machine.apply` are two separate acquisitions of the daemon's lock, and an attempt can end
  between them with no socket involved — the duration cap, the drain watchdog, a route-change fault
  on capture's own thread. A `.toggle` carrying the live attempt's target and landing on a machine
  that has just gone idle takes the **start** branch and opens the microphone aimed at the finished
  attempt's pane, in another session, never re-resolved: D4's substitution through the one door
  that resolves nothing.
- **A config file never blocks a dictation** (§7). A missing or malformed dictionary skips the
  offending rules, applies the rest, and notifies once.
- **No model load on the attempt path, ever** (D10, normative). The models are loaded once at daemon
  start and the transcriber refuses rather than loading if nobody prepared it — loading on demand
  "to be helpful" would satisfy the chord and break D10 in the same motion, invisibly. The one
  exception is not an exception: a chord arriving while the *single* start-up load is still running
  **waits** for it, because the audio is already recorded and losing it to a race with the daemon's
  own start-up is the worst outcome available.
- **The daemon never downloads models at start-up.** It is a LaunchAgent: it starts at login, on
  whatever network the laptop woke up on, and six hundred megabytes of unannounced traffic is not
  something to do quietly. A missing bundle is a loud startup message naming `Dicta --fetch-models`,
  which is the asking.
- **Anything that blocks on `Blocking.run` must be on a real `Thread`.** FluidAudio is actor-based
  and the `Transcriber` seam is synchronous, so a semaphore bridges them; blocking a Swift-concurrency
  cooperative thread while waiting on a `Task` that needs the same non-overcommit pool is the
  deadlock recorded at the bottom of this list about the control socket. dicta's callers — the
  per-connection socket thread, the audio thread, the warm-up thread in `main.swift` — are all real
  threads, and that is a property to preserve, not a coincidence.
- **Recognised text is judged before it becomes `recognised`** (§7). Output over the frame limit, or
  bytes that are not valid UTF-8, is a processing failure recorded with the **byte length** and no
  text. The limit is the wire's own (`Wire.maxFrameBytes`) on purpose: text accepted into the record
  but too large to travel back through the socket would be text `dictactl last` promises and cannot
  deliver.
- **`Sanitizer.isInjectable` is defined as agreement with `sanitize`, never as its own copy of the
  rules.** It used to test `Set<Character>` membership, and **CRLF is ONE grapheme cluster in Swift**
  — equal to neither `"\r"` nor `"\n"` — so `"a\r\nb"` was reported injectable by the assertion whose
  entire job is to stop a Return reaching `agtermctl session type`. It also passed whitespace-only
  text and a bare BEL. `sanitize` was never fooled (the cluster is whitespace), so this was a hole in
  the backstop rather than a live leak — which is exactly the kind that survives a long time. Any
  future check over "characters a terminal acts on" has the same trap waiting for it.
- **The daemon does NOT answer before doing the work.** `Daemon.apply` performs every effect inline,
  so a `stop` returns only after drain → recognition → dictionary → sanitiser → keystrokes, all
  inside `ControlServer`'s handler lock. The client's read timeout is therefore a ceiling on the
  whole pipeline, which is why `ControlTimeouts.read(for:)` gives `stop` and `toggle` 30 s and
  everything else 3 s. Two consequences worth keeping in view: a chord arriving during the one
  start-up model load waits up to 17 s and must not be reported as an unreachable daemon; and
  `processing × abort` / `injecting × abort` are not reachable through the socket while an attempt
  is in flight (see the caveat in `docs/manual-checklist.md`).
- **The record's text ceiling is the frame limit MINUS an envelope allowance**, not the frame limit.
  Text travels back out inside a whole `Response`, so equal numbers meant text accepted into the
  record could not be encoded on the way out — and `ControlServer` answered that by closing the
  connection, which `dictactl` reports as "the daemon died". The server now answers with a short
  refusal instead of dropping the connection, and `serve` never closes silently.
- **`Scripts/*.sh` must run under macOS's stock `/bin/bash` 3.2.** No `mapfile`, and no bare
  `"${ARR[@]}"` on a possibly-empty array under `set -u` — use `${ARR[@]+"${ARR[@]}"}` and a
  `while read` loop. `lint.sh` and `measure.sh` both worked only because Homebrew's bash 5 happened
  to come first on PATH, which is the same trap as depending on a SwiftLint the project refuses to
  install.
- **`return` inside a `withLock` closure leaves the CLOSURE, not the function.** `prepare()`'s
  re-entrancy guard was written that way and loaded the models anyway — silently, and twice. Take
  the decision inside the lock, return it as a value, and `guard` on it outside.
- **Do not copy acta's crash-safety machinery** (D14). Losing an utterance costs one keypress, not a
  meeting: no segmentation, no disk journal, no recovery pass. Audio stays in RAM.
- **The installed daemon runs from the signed bundle, never from a bare executable** (D11). That is
  why `Scripts/install.sh` no longer copies `Dicta` into `~/.local/bin`: a bare copy runs perfectly
  well and takes its microphone grant under whatever terminal launched it, so the bundle would exist
  and be bypassed — worse than not having built one. `Scripts/run.sh` is the honest development path.
- **Never install anything globally to make a check pass.** SwiftLint is absent by design; the lint
  script works without it.
- **The control socket serves each connection on a real `Thread`, never on `DispatchQueue.global()`
  or a queue targeting it** (Task 4, measured). On Darwin, Swift concurrency's executor runs on the
  same *non-overcommit* global worker pool `DispatchQueue.global()` draws from, and that pool does
  not grow when its threads block. Anything that blocks a cooperative thread — the parallel test
  suite calling `ControlClient.send`, or the daemon awaiting a lock — can therefore leave no worker
  to run the front door. Observed exactly once: with connections on the global pool, round trips
  that take 0.03 s serially starved into their full 3 s timeout under a parallel run, and *which*
  tests failed changed from run to run. Test writers that fill a socket buffer need the same
  treatment, for the same reason.

## Not verified automatically (needs a human)

**`docs/manual-checklist.md` is the list, and it is complete** — every item states the observation
that counts as a pass, so two people scoring it agree. In short: that the chords fire and
land in the pane they were pressed in; that injection lands in **Claude Code's** input line
specifically (F5 verified a fish prompt, which is not the same thing); microphone TCC; recognition
quality on this user's own speech through their own microphone — the Task 10 probe used synthesised
speech and a meeting recording, which establishes that the pipeline works and not that it works for
them; sleep/wake and AirPods route changes mid-attempt; daemon lifecycle across logout/login.
