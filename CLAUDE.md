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

**Task 8 of 13 (plan `docs/plans/20260814-dicta-steps-1-3.md`) is done — step 1 of SPEC.md §10 is
complete, the record it is scored through exists, and the signed bundle the microphone grant will
attach to exists before any audio code does.** `DictaCore` holds the wire types, `Paths`,
the sanitiser, the lifecycle state machine and the §9 record schema;
`DictaIPC` holds both halves of the control socket; `dictactl` speaks all six verbs and
`docs/keymap.snippet.conf` is checked by a test against the parser the binary uses. `DictaRuntime`
holds the six seams with their fakes, the `agterm` adapter — target resolution off `agtermctl tree
--json`, injection, §6's indicators, notifications, all behind a `CommandRunner` seam — and now
`Daemon`, which wires the socket, the state machine and the seams into whole attempts.

`Dicta` is a real daemon: it serves the socket, refuses a second instance, resolves the pane from the
live tree, and delivers the canned hostile transcript as one sanitised line. Every attempt now leaves
one entry in `record.jsonl` (`History`, `FileHistory`), written **before** the keystrokes, and
`dictactl last` reads it back — `final` by default, `recognised` verbatim behind `--recognised`.
Capture and recognition are still fakes (`ImmediateCapture`, `FakeTranscriber`) — Tasks 9 and 10
replace exactly those two lines of `Sources/Dicta/main.swift`.

`Scripts/bundle.sh` now produces a signed `Dicta.app` and `Scripts/install.sh` installs it as a user
LaunchAgent. That is deliberately ahead of the microphone: if the bundle identity were wrong, every
measurement taken afterwards would be taken against a grant that evaporates on the next rebuild.

The plan covers steps 1–3 of SPEC.md §10. Steps 4 (the filter) and 5 (the §7 audit) are out of it.

## Commands

- Build: `swift build` / `swift build -c release`
- **Tests: `bash Scripts/test.sh`** — the only gate. See the next section before reaching for
  `swift test`.
- Lint: `bash Scripts/lint.sh` — runs SwiftLint if it happens to be installed, and its own
  mechanical checks (Cyrillic, tabs, line length, trailing whitespace, script permissions) always.
  Each check was probed with a file that should trip it; two of them were silently passing until
  that probe, which is the same lesson as D18 in a different costume.
- Run the daemon in the foreground: `bash Scripts/run.sh` — the development path, with no bundle and
  therefore no stable TCC anchor. Fine until Task 9; not how the installed daemon runs.
- Build and sign the bundle: `bash Scripts/bundle.sh` → `./Dicta.app`; `bash Scripts/bundle.sh
  --print-requirement` prints the designated requirement of an existing one.
- Install everything: `bash Scripts/install.sh` — `dictactl` to `~/.local/bin`, the signed bundle to
  `~/Applications/Dicta.app`, the LaunchAgent to `~/Library/LaunchAgents/dev.personal.dicta.plist`,
  then bootout/bootstrap/kickstart. It never touches `~/.config/agterm/keymap.conf`.
- One-time signing setup: `bash Scripts/setup-signing.sh` — idempotent, non-interactive, and called
  by `bundle.sh` on its own when the identity is missing, so it is rarely run by hand.
- One suite only: `bash Scripts/test.sh --filter "sanitiser"` (arguments pass through to
  swift-testing).

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
- `Sources/DictaRuntime/` — everything that touches the world: `Agterm` (subprocesses), the daemon,
  the record writer, and the seams (`Capture`, `Transcriber`, `Filter`, `Injector`, `Notifier`,
  `Clock`) with their fakes.
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
- **A config file never blocks a dictation** (§7). A missing or malformed dictionary skips the
  offending rules, applies the rest, and notifies once.
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

Collected in `docs/manual-checklist.md` as the plan progresses. In short: that the chords fire and
land in the pane they were pressed in; that injection lands in **Claude Code's** input line
specifically (F5 verified a fish prompt, which is not the same thing); microphone TCC; recognition
quality on this user's speech; sleep/wake and AirPods route changes mid-attempt; daemon lifecycle
across logout/login.
