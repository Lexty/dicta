# CLAUDE.md — dicta

Voice dictation into **agterm**'s input line: press a chord, speak, press again, the text appears
where you were typing. Primarily for dictating prompts to Claude Code and instructions to agents
running inside agterm. Everything local; the microphone never leaves the machine.

The design lives in `docs/DESIGN.md`. This file is the operating manual.

## Language convention

**English only** in the repository — code, comments, docs, scripts, commit messages
(Conventional Commits). The **one deliberate exception**: user-facing strings are Russian, because
the only user is Russian-speaking and reads them on a desktop notification while mid-sentence. That
covers `Response.message`, `dictactl`'s stderr and the test names. Conversation with the user is
Russian; nothing else is.

## Where it stands

**Step 1 of 5 is done**: the chord → `dictactl` → daemon → agterm path works end to end, with FAKE
capture and FAKE transcription. There is no microphone in this build, and therefore no TCC prompt
and no model load.

Remaining: (2) microphone + FluidAudio + `.app` bundle + signing; (3) replacement dictionary +
`dictactl last` polish; (4) the filter; (5) the failure matrix.

## Commands

- Build: `swift build -c release`
- Tests: `bash Scripts/test.sh` — ⚠️ **`swift test` is NOT a gate here.** Under Command Line Tools
  only it COMPILES the bundle but cannot execute it (no `xctest` host utility), so a failing test
  still exits 0. Real tests live in `Sources/DictaTestRunner` and run through swift-testing's own
  entry point. `Tests/DictaTests` is a stub — never put a real assertion there.
- Run the daemon: `bash Scripts/run.sh` (foreground, logs to stderr)
- Talk to it by hand: `dictactl status | toggle | start | stop | abort | last`, or straight over the
  socket: `echo '{"cmd":"status"}' | nc -U ~/Library/Application\ Support/dev.personal.dicta/control.sock`

## Environment facts (verified, not assumed)

- Swift 6.3.2, `arm64-apple-macosx26.0`, **Command Line Tools only — no full Xcode**.
- **The installed agterm does NOT export `$AGT_PANE`** to custom keymap commands. Its own
  `keymap.conf` header lists what is available: `AGT_SESSION_ID`, `AGT_SESSION_NAME`,
  `AGT_SESSION_PWD`, `AGT_WORKSPACE_ID`, `AGT_WORKSPACE_NAME`, `AGT_WINDOW_ID`, `AGT_WINDOW_NAME`,
  `AGT_SELECTION`, `AGT_SOCKET`. The skill documentation describes a newer build. The daemon
  therefore resolves the focused pane from `agtermctl tree --json` (`surfaces[].active` → `kind`),
  which is the better source anyway: live focus, not what the runner captured.
- **`agtermctl session type` injects real keystrokes with no bracketed paste** — every `\n` is a
  Return that SUBMITS the input line. This is the single most dangerous fact in the project and the
  reason `Sanitizer` exists.
- **`claude -p` costs 8.6–10.5 s of fixed startup overhead**, measured 2026-08-13 (naive, and with
  `--tools "" --strict-mcp-config`). It cannot be the clean-up filter. This is why v1 ships
  `NoFilter` and the seam empty.
- Measured warm keypress cost, `dictactl` invocation → "recording": **20–70 ms** (`dictactl status`
  alone 9 ms; `agtermctl tree --json` 38 ms). The threshold at which the trigger transport would
  need rethinking is 150 ms — we are well under it. Cold start is ~390 ms.

## Structure

- `Sources/DictaCore/` — **pure, no I/O**: `StateMachine`, `Sanitizer`, the wire types, `Paths`.
  Anything worth asserting lives here.
- `Sources/DictaIPC/` — the Unix-socket transport, both halves in one file so the two ends' framing
  cannot drift. Split from `DictaRuntime` for one concrete reason: `dictactl` needs the client, and
  `DictaRuntime` is where AVFoundation and CoreML land in step 2 — without the split, every keypress
  would drag the capture stack through dyld.
- `Sources/DictaRuntime/` — everything else that touches the world: `Agterm` (subprocesses),
  `Daemon`, `History`, and the seams (`Capture`, `Transcriber`, `Filter`, `Injector`) with their
  fakes.
- `Sources/Dicta/` — the daemon executable. Wiring only.
- `Sources/dictactl/` — the client the keymap invokes. **Depends on DictaCore + DictaIPC and nothing
  else, and must never touch the microphone**: the TCC grant belongs to the daemon's signed bundle,
  and a second binary opening the device would fracture it.
- `Sources/DictaTestRunner/` — where the tests actually are.

The rule: a decision goes into `DictaCore` as a pure value, its I/O into `DictaRuntime`, its test
into `DictaTestRunner`.

## Rules worth not relearning

- **One sanitiser, on every path.** Cleaned text, raw text, raw-as-fallback-when-the-filter-failed,
  and `dictactl last` all pass through `Sanitizer.sanitize` immediately before injection. A path
  that walks around it submits a half-written prompt. The fallback path is exactly where the first
  draft leaked.
- **`FakeTranscriber` returns deliberately hostile text** — a newline, a double space, a trailing
  space. If the sanitiser is ever bypassed, step 1's own canned text submits the prompt, loudly, now.
  Do not "tidy it up".
- **The toggle is resolved inside the daemon, never in the shell.** `status | grep idle && start ||
  stop` is two round trips with a race between them, in which one keypress can both start and stop.
- **Nothing is announced before capture confirms.** The start sound and indicator fire after the
  engine is actually running. Announcing at keypress trains the user to lose their first syllable.
- **A dead target is never replaced by the focused one.** If the captured session is gone, the text
  goes to the history log and a notification. Injecting into whatever has focus now means somebody
  else's agent gets your prompt.
- **The duration cap stops but does not inject.** Ten minutes of forgotten speech landing in an
  agent's prompt is worse than losing it; the transcript still reaches the history log.
- **A fault always discards.** Sleep, an input-device change, a dead capture: the audio boundary is
  in doubt, so the recording dies rather than being guessed at.
- **Do not copy acta's crash-safety machinery.** Losing an utterance costs one keypress, not a
  meeting. No segmentation, no disk journal, no recovery pass — audio stays in RAM.

## Not verified automatically (needs a human)

- That the chords in `docs/keymap.snippet.conf` actually fire, and land in the pane you were in.
- Microphone TCC, once step 2 exists. Real speech quality. Everything above the seams.
- That injected text lands in **Claude Code's** input line specifically (verified so far against a
  fish prompt, where it correctly sat unsubmitted).
- Sleep/wake and AirPods route changes during a recording.
