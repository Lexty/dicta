# Working on dicta

Canonical for every contributor, human or agent. `CLAUDE.md` points here and adds only Claude Code
specifics; Codex, and anything else, reads this file.

Voice dictation into **agterm**'s input line: hold the right Control key, speak, let go, the text
appears where you were typing. Primarily for dictating prompts to Claude Code and instructions to agents
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

**The menu-bar UI is built — `docs/plans/20260823-dicta-menu-ui.md`, Tier 0 and Tier 1 of
`docs/ui-proposal.md`, all ten tasks.** A second signed bundle, `DictaMenu.app`, under a LaunchAgent
of its own: the glyph with a running clock, the panel with its header, banners and footer, the live
target line, Stop/Abort, and `Recent Dictations` with copy-to-clipboard. The daemon gained exactly
one thing for it, `watch`, and cannot tell whether a UI is running. Tier 2 — expanding a row to show
`recognised` against `final` and the rules that fired, and D9b's filter field — waits for step 4,
because a settings panel with one row in it is worse than none.

What is left of it is what only a person can score, and it is in `docs/manual-checklist.md` as
**H15–H22**: that the glyph tracks the agterm indicator rather than leading it, that the strip is
noticed without being looked at, that the banners appear on a machine with no models and with the
microphone denied, that a dictation which went nowhere reaches the clipboard from the panel, and
that `Stop and type` lands in the pane the chord was pressed in.

## Commands

- Build: `swift build` / `swift build -c release`
- **Tests: `bash Scripts/test.sh`** — the only gate. See the next section before reaching for
  `swift test`.
- Lint: `bash Scripts/lint.sh` — runs SwiftLint if it happens to be installed, and its own
  mechanical checks (Cyrillic, tabs, line length, trailing whitespace, script permissions) always.
  Each check was probed with a file that should trip it; two of them were silently passing until
  that probe, which is the same lesson as D18 in a different costume.
- Watch the daemon's state as a stream: `dictactl watch` — one JSON object per transition, plus one
  the instant it attaches. The menu app is the other client of it; this is how to see what the menu
  is being told, and it costs the keypress path nothing measurable.
- The menu bar: installed by `Scripts/install.sh` alongside the daemon, and restarted on its own
  with `launchctl kickstart -k gui/$UID/dev.personal.dicta.menu`. It is **optional** — the daemon
  neither starts it nor notices it, and `launchctl bootout gui/$UID/dev.personal.dicta.menu` leaves
  every dictation working exactly as before.
- Disable push-to-talk for a run: `Dicta --no-hold` (or `bash Scripts/run.sh --no-hold`). The
  keymap chords are unaffected. Useful when two daemons would otherwise both watch the same key.
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
- Rebuild the icon: `bash Scripts/make-icon.sh` — cuts the squircle out of `Resources/icon-source.png`
  and writes `Resources/AppIcon.icns`. Run it only when the artwork changes; the icns is committed
  and `bundle.sh` never regenerates it.
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
  it first, since no swift-testing assertion can reach a linked binary (invariant 8, D12). It also
  reads `Dicta` for the four shapes of "read a keystroke" — `CGEventTapCreate`, `CGEventTapEnable`,
  `IOHIDManager`, `_OBJC_CLASS_$_NSEvent` — which is invariant 11, the one thing standing between
  push-to-talk and a permission prompt. `--daemon <path>` scores that check alone; it was probed by
  adding a `CGEvent.tapCreate` call and watching it fail on `U _CGEventTapCreate`.

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

## Environment facts (verified 2026-08-14, toolchain re-verified 2026-08-25)

- macOS 26.6 (25G72), target `arm64-apple-macosx26.0`.
- **Both toolchains are present, and which one is live is whatever `xcode-select` points at.** As
  of 2026-08-25 that is a full **Xcode 26.6** (17F113) at `/Applications/Xcode.app/Contents/
  Developer`, Swift 6.3.3 (`swiftlang-6.3.3.1.3`); the Command Line Tools are still installed
  beside it at `/Library/Developer/CommandLineTools`, Swift 6.3.2 (`swiftlang-6.3.2.1.108`), and
  `DEVELOPER_DIR=/Library/Developer/CommandLineTools` selects them for one command. Until
  2026-08-25 the Tools were the only thing here and `xcodebuild` refused to run — the sentence this
  replaces said so, and Xcode arriving underneath it is what made the next bullet cost an
  afternoon.
- **Neither toolchain is assumed by the build.** `swiftTestingSettings()` in `Package.swift` probes
  for `Testing.framework` and carries BOTH layouts, because the framework, its interop dylib and
  the macro plugin sit under three different roots in each:

  | | Command Line Tools | full Xcode |
  |---|---|---|
  | `Testing.framework` | `$DEV/Library/Developer/Frameworks` | `$DEV/Platforms/MacOSX.platform/Developer/Library/Frameworks` |
  | `lib_TestingInterop.dylib` | `$DEV/Library/Developer/usr/lib` | `$DEV/Platforms/MacOSX.platform/Developer/usr/lib` |
  | `libTestingMacros.dylib` | `$DEV/usr/lib/swift/host/plugins/testing` | `$DEV/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing` |

  When the guard knew only the left column and Xcode became active, the runner still **compiled and
  linked** — SwiftPM finds the module on its own — and then died in dyld on
  `@rpath/Testing.framework` before reaching a single assertion. Silent at build time, fatal at run
  time: D18's shape exactly, a gate that looks like it ran and did not. `bash Scripts/test.sh` is
  scored under both by setting `DEVELOPER_DIR`, and both give the same run — 583 tests in 34
  suites, re-scored 2026-09-12.
- **`xctest` now exists** at `/Applications/Xcode.app/Contents/Developer/usr/bin/xctest`, so D18's
  cause is absent while Xcode is selected. This changes nothing: `Tests/DictaTests` is still denied
  the swift-testing flags and still holds no assertion, `swift test` still gates nothing, and the
  runner stays the gate — it is the one command that works under either toolchain, which is the
  whole point of the paragraph above.
- `agtermctl` is on PATH at `/opt/homebrew/bin/agtermctl`; `agtermctl tree --json` answers with
  `{"ok":true,"result":{"tree":{"workspaces":[...{"surfaces":[{"kind":"left","id":"surface:…"}]}]}}}`
  — surfaces carry `kind` and `id`, which is what pane resolution reads (§5).
- **SwiftLint is not installed** and nothing here installs it; `Scripts/lint.sh` degrades to its own
  checks. Do not add a global install to make a linter run.
- **F3 — the installed agterm does not export `$AGT_PANE`** to custom keymap commands. Available:
  `AGT_SESSION_ID`, `AGT_SESSION_NAME`, `AGT_SESSION_PWD`, `AGT_WORKSPACE_ID`, `AGT_WORKSPACE_NAME`,
  `AGT_WINDOW_ID`, `AGT_WINDOW_NAME`, `AGT_SELECTION`, `AGT_SOCKET`. The pane therefore comes from
  the live tree, not from the keypress (D6, §5).
- **F4 — the warm keypress interval has TWO endpoints, ~35 ms apart, and a figure without its
  endpoint is not a measurement.** Chord → live microphone ~95 ms; chord → lit indicator, which is
  what `Scripts/measure.sh` scores because it times the whole `dictactl` invocation, median **122
  ms** (p90 132, p95 145, worst of 120 attempts 158; 12 runs of 10 warm attempts on `4c2ac7c`,
  2026-08-23). SPEC §10's budget is 150 ms and §10 (a) does not say which endpoint it means — see
  F4 in SPEC.md, which now states that as an open decision rather than an answered one.
  Medians of the phases, measured the same day with per-phase instrumentation inside the installed
  LaunchAgent build over 26 attempts (instrumentation reverted): `dictactl` process + socket ~20,
  resolving the target ~30, `engine.start()` ~40, the "listening" indicator ~35. **Two of the four
  are `agtermctl` subprocesses, and the indicator runs after the microphone is already live** —
  D13 requires that order, which is what splits the interval in two.
  **Withdrawn: "the rest is `capture.begin`".** This file said so on 2026-08-18 and it was false —
  `capture.begin` was 66–80 ms of ~165 (`inputNode` ~29, `installTap` ~5, `start()` ~39). `4c2ac7c`
  moved the first two off the chord path by building the engine in advance, which is allowed because
  a **prepared** engine is not a running one: measured on
  `kAudioDevicePropertyDeviceIsRunningSomewhere`, `inputNode`, `installTap` and `prepare()` all
  leave the device `false` and only `start()` sets it. Holding a **started** engine warm between
  attempts is still refused — a permanently lit microphone indicator is not a trade this project
  makes, and that refusal was never what cost the 34 ms.
  The number this file carried before all of it — 20–70 ms — was measured on the deleted skeleton
  `3dda6cb`, **whose capture was a fake**: that build never opened the microphone, so the figure
  described the path with its expensive part removed, and the 150 ms budget was calibrated against
  it. The lesson is D18's in another costume — a measurement is only about the path it actually ran
  through, which is also why the 2026-08-18 entry was wrong: it attributed the whole interval to the
  one component nobody had timed separately.
- **The menu-bar bundle runs under its own LaunchAgent, and the daemon's designated requirement did
  not move when it was added (2026-08-23, D27).** Both facts were checked rather than assumed,
  because both fail silently:
  - `DictaMenu.app` bootstrapped into `gui/$UID` reaches `state = running` and LaunchServices reports
    it as `LSDisplayName = "Dicta Menu"`, `CFBundleIdentifier = dev.personal.dicta.menu`. **The
    status item appears and its panel opens** — confirmed by the user against a running agent on
    2026-08-23, which is the half no command here could establish. So a `MenuBarExtra` under a user
    LaunchAgent works, and D27's shape is viable rather than merely plausible.
  - Seen in the same screenshot and worth recording, because it is the rule from
    `docs/ui-vocabulary.md` meeting reality: dicta's `mic` and acta's `waveform` sit adjacent in the
    menu bar and are distinguishable at a glance. Two tools from one family in one strip is the
    situation the "one glyph each, by shape not position" rule was written for.
  - The daemon's requirement after `bundle.sh` learned to build two bundles is
    `identifier "dev.personal.dicta" and certificate leaf = H"3dcb99…"` — **byte-identical to the
    installed `~/Applications/Dicta.app`**, which is what the microphone grant is recorded against.
    The menu's is the same leaf under `dev.personal.dicta.menu`: one certificate, two identities.
  - Measured while writing the menu's linkage row, and it decided how strict that row could be: a
    trivial SwiftUI `MenuBarExtra` binary references **neither** `_OBJC_CLASS_$_NSEvent` nor AppKit
    in its load commands — SwiftUI reaches AppKit internally — while a binary calling
    `NSEvent.addGlobalMonitorForEvents` shows `U _OBJC_CLASS_$_NSEvent` in `nm -u` **and** the
    selector `addGlobalMonitorForEventsMatchingMask:handler:` in `strings`. So the UI is held to the
    daemon's full four-symbol rule rather than a weakened one. Both checks were watched failing
    against a deliberately-monitoring probe, and the three capture-stack checks against
    `DictaTestRunner`.
- **A `watch` client costs the keypress path nothing measurable (2026-08-23, D27).** 120 warm
  attempts through `Scripts/measure.sh` against the installed LaunchAgent build, in two blocks of
  six runs of ten, with and without `dictactl watch` attached:

  | | median | mean | p90 | worst |
  |---|---|---|---|---|
  | no watcher | 119.1 | 120.1 | 130.8 | **193.8** |
  | one watcher | 116.7 | 115.8 | 125.2 | 141.2 |

  **Read this as "below the noise floor", not as "watching makes it faster".** Publishing a snapshot
  cannot speed a chord up; the block with a watcher came out slightly better on every aggregate, and
  the single worst attempt of the whole session (193.8 ms) was in the block with NO watcher. What
  the numbers establish is that the cost of a lock, a copy and a signal per transition does not rise
  above the jitter of a real machine — which is what makes publishing on the transition path
  allowed. 198 events reached the watcher across the second block, so the stream was carrying the
  whole run rather than being idle through it.
  Consistent with F4's own finding that §10 (a) is not met: both blocks contain attempts over the
  150 ms budget, with and without a watcher, so the criterion's failure is not the UI's doing.
- **The whole menu-bar UI, measured against the installed pair (2026-08-24, Task 9).** The rule
  these were taken under is the one F4 was rewritten to state: a figure without its endpoint and
  its instrument is not a measurement. Two of them found defects, and both are recorded with what
  the number was **before** the fix, because a measurement that only ever saw the fixed build cannot
  be re-run as a regression check.
  - **The keypress path does not notice the menu.** `Scripts/measure.sh`, 120 warm attempts, two
    blocks of six runs of ten, alternating in one sitting — the menu running with its watcher
    attached, then `launchctl bootout` on the menu and no watcher at all.

    | | median | mean | p90 | p95 | worst | over 150 ms |
    |---|---|---|---|---|---|---|
    | menu running | 116.0 | 115.4 | 128.1 | 131.1 | 168.3 | 2 of 60 |
    | menu stopped | 108.6 | 122.2 | 190.3 | 193.8 | 256.3 | 12 of 60 |

    **Read this as "below the noise floor", and read the tails as the machine rather than as the
    UI.** The block WITHOUT the menu came out worse on every aggregate except the median, which is
    the opposite of what a cost would look like, and the per-run medians span **16 ms in both
    blocks** (107–123 and 99–115) — so the 7 ms between the two block medians is inside the spread
    of either one taken alone. Both medians are under F4's 122 ms on `4c2ac7c`, so nothing
    regressed; the worst attempts are worse than F4's 158 ms, and the honest reason is that this
    machine was running several agent sessions at the time and F4's was not. §10 (a) still fails, in
    both blocks, exactly as F4 says — the criterion's failure is not the UI's doing.
  - **The bounded reader is bounded, shown at two sizes rather than asserted at one.** The record
    grew 44% during the measurement above (120 aborted attempts, each one an entry — D26 writes the
    speech down), which made the comparison free:

    | record | `tail(5)` | bytes it touched | `all()` | ratio |
    |---|---|---|---|---|
    | 197 409 bytes, 629 lines | 0.142 ms | 16 384 | 5.84 ms | 41× |
    | 284 267 bytes | 0.163 ms | 16 384 | 8.41 ms | 52× |

    `all()` tracks the file and `tail(5)` does not, which is the property Task 5 bought and the
    ratio will go on widening for as long as dicta is useful. Release build, 200 iterations,
    medians. `SessionNames.names` — the target line's own lookup — is 0.127 ms over a 58 KB tree of
    33 sessions, and it is off the keypress path entirely: it runs only while the panel is open with
    a live attempt.
    Note what this makes unreachable rather than fixed: `recent == []` renders "Nothing yet."
    whether the record is empty or merely unread, and at 0.16 ms behind a read that starts at app
    launch there is no frame in which the wrong one can be seen. A flag to tell them apart would be
    a branch nothing can reach, so there is not one.
  - **A daemon restart is noticed and recovered from without the panel ever being opened.**
    `launchctl bootout` then `bootstrap`, four cycles, polled with `lsof` on the menu's own
    descriptors — an instrument that costs 36 ms per sample and therefore bounds the resolution of
    everything in this bullet. The menu drops its socket within ~60 ms and comes back in
    **534, 557, 577, 608 ms**, which is `Backoff.first` plus the daemon's start. The menu's pid
    never changes, so none of this is a crash and a relaunch.
    **A `kill -9` is a different number and the difference is launchd's, not dicta's**: launchd
    respawns the daemon within milliseconds, but repeated respawns are throttled to about ten
    seconds, so a crash during a burst of restarts leaves ~12 s with no daemon to connect to. The
    menu is truthful throughout it; there is simply nothing there.
  - **F9b — a watcher that attached was told NOTHING until the daemon's next transition, and the
    menu-bar strip lied for as long as that took.** Found by the bullet above and confirmed with the
    smallest possible instrument: `timeout 4 dictactl watch` against a healthy idle daemon printed
    **not one byte**. The daemon publishes on transitions, so after a restart the strip went on
    saying "dicta is not answering" over a connection that had been live for minutes — and that lie
    sustains itself, because nobody dictates at a strip that says dicta is dead, and only a
    dictation would have corrected it. It also pinned the reconnect backoff at its 5 s ceiling for
    ever, since `failures` is reset by a received event: measured **5 351 ms** to reconnect after a
    crash, against ~550 ms once the fix landed.
    **Nothing had to be added to the wire.** The handshake `Response` already carries the snapshot,
    filled by the same function `status` uses so the UI's first frame and its second cannot disagree
    — `ControlClient.watch` was reading it and throwing it away. It now delivers it as the stream's
    first `.update`, with no `sequence`, which is already this protocol's word for "not a
    transition". `test: a watcher is told the state it attached to, before anything has
    transitioned` is the assertion; every other test in that suite makes something happen and then
    looks, which is exactly why none of them could see this.
    The checklist's **H18** claimed the glyph "returns to grey on its own" — it did not, and the
    item was written before anything had been scored. That is the general hazard of a checklist
    written alongside the code it audits, and the reason these items say what to *observe* rather
    than what to expect.
  - **The menu costs nothing while nothing is happening.** 0.00 s of CPU accumulated over 60 s idle
    with the panel closed, because the second hand runs only when something is counting — a
    recording, or an open panel. 67 MB RSS against the daemon's 58.6 MB, which is what a SwiftUI
    process costs and is not worth optimising.
  - **Not measured, and needing a person rather than a script.** Said out loud because Task 9's
    instruction was to record the boring ones too, and an unmeasured item silently omitted reads as
    a measured one. The panel's open-to-drawn latency **as perceived** — everything under it is
    timed above, but whether a frame is ever seen unpopulated is **H16**. How long the hold trigger
    stays silent after the panel closes (D22) — it needs somebody to close a panel and hold a key,
    and it is **H19**. Logout and login with both LaunchAgents — **H10** and **H22 (a)**, and the
    race worth watching for there is the menu winning the start and painting "not running" before
    the daemon has bound its socket; the reconnect measured above is what should clear it within a
    second, but that is a prediction and not an observation.
- **F10 — a Bluetooth headset as the default input breaks capture, and the pre-built engine turns
  one bad attempt into a permanent one (2026-08-25, not yet fixed).** The user reported dicta had
  stopped responding. The record named it: six `capture-fault` entries, every one of them
  `-10868` — `kAudioUnitErr_FormatNotSupported`, thrown by
  `AUGraphParser::InitializeActiveNodesInInputChain` — and every one inside the window when AirPods
  Max were the default input.
  - **The formats disagree, and that IS the error.** Measured with a throwaway probe while the
    failure was live: the HAL reported the default input at **24 000 Hz**, and
    `AVAudioEngine.inputNode.outputFormat(forBus: 0)` in a **freshly launched process** reported
    **48 000 Hz** at the same moment. A tap installed at the format the node claims cannot be
    initialised against the device that is actually there.
  - **Why a headset is different from a slow device.** The AirPods run at 48 kHz as an output and
    switch to 24 kHz when something opens their microphone, so an engine built BEFORE the chord
    describes the device as it was, not as `start()` finds it. `InputDeviceIdentity` cannot see
    that: it samples the device id and the nominal rate before the start, and on both sides of the
    flip they match. This is the one cost of `4c2ac7c` that its own measurements could not show,
    because they were taken on a USB microphone that never changes rate.
  - **It repeats rather than passing, which is why it read as "dicta is broken".** The attempt that
    meets the flip fails; the next one 1.9 s later succeeds (record 812 → 813), because the rebuild
    that follows a failure happens while the input is still open. The device then drops back to
    48 kHz and the chord after that fails again. Six attempts in 40 s, one of them fine.
  - **Three candidate fixes, none of them chosen, and the reason is honesty about the instrument.**
    Retry once with a freshly built engine when `start()` fails with a format error, nothing having
    been recorded at that point; build the converter from the HAL's nominal rate rather than from
    the format the node claims; or pin the current default input on the input unit with
    `kAudioOutputUnitProperty_CurrentDevice`, which a probe showed starting and capturing 16 384
    frames. Which of them actually holds can only be measured with a Bluetooth headset selected as
    the input — with the USB microphone back, the failure cannot be reproduced at all, and a fix
    verified only against a machine that no longer fails is F4's lesson in a new costume.
  - The workaround until then is a wired or built-in input. Nothing else about the daemon was wrong:
    it was running, answering `idle`, holding the microphone grant, and the models were warm.
- **F2 — `claude -p` costs 8.6–10.5 s of fixed startup** per invocation. It cannot be the filter,
  which is why v1 ships the seam empty (D9c).
- **Recognition, measured on this machine (M3 Pro) with a throwaway probe in Task 10, since no unit
  test can establish any of it.** The probe fed real audio through `AudioCapture.convert` into
  `ParakeetTranscriber`, i.e. dicta's own path with only the daemon left out.
  - **Model load: 17.1 s once, on this machine, and 0.2–0.5 s on every start since.** The 17 s is
    CoreML compiling the int8 encoder for the ANE. This file used to add that the cache is *keyed
    per binary*, so **every rebuild pays it once** — that part did **not** reproduce: four daemon
    starts across three distinct signed binaries (14, 16 and 18 August, each a different cdhash)
    reported 0.4, 0.5, 0.2 and 0.3 s, and none paid the compile. So the compiled-model cache appears
    to be keyed by the model rather than by the calling binary, and the 17.1 s was a one-time cost
    on this machine. Not asserted as a new fact — four starts do not establish that it never returns
    after a reboot or a cache eviction — but the old claim is withdrawn.
    The warm-up still runs on its own thread after the socket is bound, and that is still right: it
    costs nothing when the load is fast and is the difference between a slow start and a deaf daemon
    when it is not.
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
  replacement engine, the record schema, the wire types, `Paths`. Anything worth asserting is here,
  **including everything the menu-bar UI decides** — `Presentation` (which glyph, which tint, which
  sentence), `MenuModel` (which banner, whether the daemon is gone rather than idle, what the
  menu-bar item draws), `DictationRow` (what a row shows and what may be copied), `SessionNames` and
  `AgtermTool`. That is not UI in the wrong module: `DictaMenu` is an executable target and SwiftPM
  **cannot import one**, so a decision written there would be unreachable from the test runner. The
  SwiftUI files turn `Tint.red` into a colour and do nothing else (D19, D27).
- `Sources/DictaIPC/` — the Unix-socket transport, **both halves in one module** so the two ends'
  framing cannot drift. Split from `DictaRuntime` for one concrete reason: `dictactl` needs the
  client half, and `DictaRuntime` is where AVFoundation and CoreML land — without the split every
  keypress would drag the capture stack through dyld.
- `Sources/DictaRecord/` — reading §9's record off disk, **bounded**. The same split as `DictaIPC`
  in its second instance rather than a new principle: the menu app needs the reader and
  `DictaRuntime` links FluidAudio. `RecordReader.tail` walks backwards in 16 KB chunks until it has
  seen the wanted number of distinct attempt ids, which makes the cost independent of a file that
  grows for ever — 0.16 ms against `all()`'s 8.4 ms on a 284 KB record, and the gap widens with use.
  Reading backwards is also what makes §9's superseding rule free: from the end, the first line seen
  for an id is the last one written. **It bounds READING and is not a licence to bound the FILE** —
  the header of that file says why, and names the three dependents append-only now has.
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
- `Sources/DictaMenu/` — the menu-bar UI (D27). **`DictaCore` + `DictaIPC` + `DictaRecord` plus
  SwiftUI, and nothing else** — `dictactl`'s dependency budget, one target wider. It opens no
  microphone, loads no model, and links no `DictaRuntime`, which is invariants 8 and 11 and is
  asserted by `Scripts/linkage.sh` rather than by any test. Wiring only: a socket, a thread and a
  `@Published`.
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
- **Only `sessionNotFound` is allowed to be called `targetGone`.** `Agterm.validate` wrapped *every*
  lookup failure that way, which made the user read a sentence that contradicts itself inside one
  line — "the target is gone: … — refusing to call it gone" — and wrote `target-gone` into §9's
  `outcome` for a session `searchTruncated` had explicitly refused to declare dead. A missing
  `agtermctl`, a timeout or a refused command say nothing about the session at all. `notStarted` is
  the truthful name for all of them: it claims only that no keystroke was sent.
- **A `discard` can outrun the `begin` it belongs to, and `begin` must re-assert ownership after
  `engine.start()`.** `begin` spends several AVFoundation calls before it can register anything —
  `inputNode` alone can block on a wedged CoreAudio HAL — while `abort` is served concurrently and
  the warm-up watchdog is armed by `sync` *before* `.beginCapture` is performed. A discard landing
  in either window (before the registration, or after taking the recording back out) used to leave
  `begin` free to start the engine afterwards: the microphone held open for the life of the daemon,
  orange indicator lit, for an attempt already over. `discard` therefore parks an id it did not
  find, and `begin` tears the engine down rather than announcing `.ready`. That teardown is the one
  place two threads run `tearDown` on the same `Recording` at once — every other caller holds it
  through `take` — so it is serialised on the recording's own `teardownLock` and **not** on `lock`:
  teardown calls `engine.stop()`, which returns only once the render thread has quiesced, and the
  render thread takes `lock` in `absorb`. Idempotent was never the same as thread-safe; unguarded,
  one thread iterated `observers` while the other assigned over it.
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
- **Recognition is long enough for the attempt to end underneath it, and the text still has to
  land** (invariant 10, §7's cap row). D15's cap fires from the clock's thread and a route change
  from capture's, so a fault can end an attempt while `transcriber.transcribe` is still running —
  the last second of a ten-minute dictation, or the first chord after a rebuild, where recognition
  waits up to `patience` on the one start-up model load. The text then comes back to a daemon that
  has already written the entry describing it: the draft is gone, and `updateDraft` silently does
  nothing. `storeRecognised` therefore asks the **machine**, not the draft, whether the attempt is
  still live (the draft outlives the transition by one `sync`, so a matching id can already be
  doomed), and text that missed goes through `recordLateRecognised`. Both writers take `appendLock`
  across `history.append`, because what must be ordered is the bytes on disk — a superseding line is
  only superseding if it lands second — and the two orders are handled symmetrically: supersede the
  ending if it is written, park the text for `appendEnding` to fold in if it is not. `aborted`
  **used to** refuse the text on purpose and no longer does — see the D26 note below. Do NOT "fix" this by
  disarming the cap during `processing`: a ten-minute dictation would then be injected, which is the
  one thing D15 exists to prevent.
- **A failing record append never blocks a delivery** (§7). It injects, then says loudly that
  recovery is unavailable — in that order, because a complaint arriving first reads as a refusal.
- **A rejection is audible; a no-op is silent** (§6). Pressing stop again because nothing visibly
  happened is normal behaviour, and an alarming noise would punish it.
- **Cancellation is refused once injection has begun** (D20). Keystrokes already in the terminal
  cannot be recalled.
- **Injection is never retried** (§7). A retry after keystrokes have begun would double part of the
  text; the notification says the insertion *may be partial* and stops there.
- **`agtermctl tree` is WINDOW-scoped; `--target <uuid>` is not.** `tree`'s only address is
  `--window`, which "defaults to the frontmost", while `session type`, `session status` and `notify`
  match a session id across every open window. Reading the first as if it had the second's scope is
  how a live session becomes `targetGone`: dictate in window A, click into window B, press stop
  there, and the re-validation asks B's tree about A's session. The text survives in the record and
  nothing is mis-aimed — D4 holds — but the input line never receives it and the reason the user
  reads is false. `Agterm.surfaces(ofSession:)` therefore asks the frontmost window first (the
  answer on every ordinary chord) and then sweeps the rest off `window list --json`, bounded by
  `maxWindowsSearched` because each window is another subprocess inside the handler lock. Past the
  bound it throws `searchTruncated` rather than `sessionNotFound`: a search that stopped early has
  not established that anything is gone. **A `window list` that fails is the same claim**, and it
  throws `searchUnavailable` for that reason — swallowing it into an empty list (`try? … ?? []`)
  walked straight past the truncation guard, since `0 <= 0`, and reported a session looked for in
  one window out of an unknown number as gone. A timeout on a busy machine was enough.
- **A killed child does not end a pipe read.** Foundation dups the pipe's write end into the child
  and **every descendant inherits it**, so `readDataToEndOfFile` returns at EOF — the last holder
  closing — not when the direct child dies. Measured: SIGKILL at 2 s, read returned at 8 s when the
  grandchild exited. `ProcessRunner` therefore drains both pipes on threads of their own and waits
  on semaphores against one absolute ceiling; the deadline alone bounded the child and not the call,
  which is the wedge it is documented to prevent. The consequence for the budget: one call can spend
  `worstCaseCallSeconds` — deadline **plus** both graces — not `defaultDeadline`.
- **`FileManager.createDirectory` ignores `attributes` when the directory already exists.** It
  succeeds, returns, and the mode is never applied — so `0700` held only for a directory dicta
  itself created under a strict umask, and one restored from a backup kept whatever it had for ever.
  `Paths.createPrivateDirectory` chmods after the create for that reason. The same class of trap:
  `Data.write(options: .atomic)` renames a temporary file into place at **0644**, which is how the
  parked target became the one file dicta owns that was more readable than the directory holding it.
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
- **Speech that was captured is written down even when nothing was delivered** (D26). An **abort**
  and D15's **cap** now DRAIN rather than discard — but NOT a device-raised `capture-fault`, whose
  samples the capture layer drops on purpose even with a full buffer, because the audio's boundary
  is in doubt (D16). Getting that wrong in a spec sentence is exactly what happened on the first
  draft, and no test would have caught it. The two that do work: the buffer is recognised on a thread of
  its own and the words land in §9's `recognised`, with `final` empty and nothing injected, ever.
  This reverses a rule this file used to state the other way round, so the reasoning matters. What
  an abort cancels is the **delivery** — the speaking already happened into an open microphone, and
  anything else recording the room (the sibling project `acta`, concretely) has it. Refusing to
  write the words down does not unmake them; it makes them unattributable, which is the harm rather
  than the protection.
  Three things hold it safe and none of them is a branch that declines to inject. The effect is
  emitted only by `StateMachine.cancel`, which has already set `.idle`; `journalRecognise` never
  calls `apply`, so no transition exists that could carry an `.inject` effect; and `dictactl last`
  answers off `final`, which stays empty, so a cancelled dictation reads as "produced no final text
  (aborted)" rather than as something re-sendable. `--recognised` does show it — that is diagnosis.
  Two traps if you touch this. An attempt cancelled while `warming` must journal NOTHING, because no
  buffer ever existed and a recogniser handed silence would write a line about speech that did not
  happen. And an attempt cancelled while **draining** must NOT issue a second `drain`: one is
  already in flight, `take` hands a recording to exactly one thread, and the loser gets nothing —
  that is why `retainDrainingCapture` exists beside `retainCapture` and does not call capture at all.
- **A config file never blocks a dictation** (§7). A missing or malformed dictionary skips the
  offending rules, applies the rest, and notifies once.
- **`docs/replacements.example.conf` carries its own expectations, and they are executed.** Lines
  reading `# check | <what was recognised> | <what the book must produce>` are comments to the
  parser and assertions to `test: every check line in the example dictionary produces what it
  claims`. They exist because the cascade fails in a way reading cannot catch — a rule above
  rewrites the sentence a rule below was written for, and both still look right on the page; the
  dead-rule test only covers a rule that cannot fire on its **own** pattern. Two rules of the file
  itself: a pattern that is also an ordinary Russian word is a `misfire` waiting for a sentence — so
  two garbles observed in the record have no rule on purpose, and the file says which and why — and
  a pattern with **letters** but no Cyrillic in it cannot be added at all — `test: the example
  dictionary that ships parses with no problems` requires one, so recogniser garbles that come back
  in pure Latin (`n-to-end` for "end-to-end") have no rule available and are a known gap rather than
  an oversight. A pattern with no letters at all is the carve-out, and it exists for exactly one
  thing: the third pass of the version-number block, where the left-hand side of the join is a digit
  an earlier rule produced, and `6 .` is the whole pattern. Stated as "no letters" rather than as an
  exemption list, because that is what keeps the edge — a rule matching an English word is still
  refused, whatever it is called.
- **The merge request is repaired in two passes, because writing out the pairs does not converge.**
  Fifteen entries in the record carry the term and eleven spell it differently: the recogniser
  garbles the first word, splits the pair where it likes, and inflects whichever half it lands on.
  Five rules covered five spellings and three more arrived the same week. So pass 1 repairs the
  first word on its own and pass 2 matches the pair -- nine garbles times fourteen endings is 126
  phrasings out of 23 rules, and tomorrow's garble is one line rather than one line per ending. The
  boundary rule is what makes pass 2 safe to list flat, since a pattern ending in a letter cannot
  fire inside a longer word. One spelling is refused on purpose and the file says so: the recogniser
  once heard the first word as an ordinary Russian pronoun, and a rule on that would rewrite the
  pronoun everywhere.
- **Spoken version numbers are three passes over the same dictionary, and the reason is the space.**
  A version dictated as words — "one tochka six tochka zero" — becomes `1.6.0` through thirty rules:
  `tochka <word>` → `.<digit>`, then `<word> .` → `<digit>.`, then the same join once the left side
  is already a digit. A literal rule cannot bridge a space unless its pattern contains **both**
  sides, and a pattern may not begin with one (the fields are trimmed), so the alternative to the
  three passes is 200 rules spelling out every pair. Number words are NOT converted anywhere else: a
  bare "two" stays a word, and only a `tochka` between two numbers says a version is being spelled
  out. The edge, which the record will show: pass 1 fires on `tochka <number>` even when nothing to
  its left can absorb the result, so a misspoken "one tochka five, tochka four" comes out `1.5, .4`.
  Measured before it shipped, which is the only reason it is here: the whole dictionary, old and
  new, was run over all 279 dictations in this machine's record. 24 came out different, every one of
  them an improvement, and no rule fired on ordinary speech.
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
  whole pipeline, which is why `ControlTimeouts.read(for:)` gives **every verb a chord can send** —
  `stop`, `toggle`, `start`, `abort` — `pipelineRead`, and leaves the 3 s `clientRead` to `status`
  and `last`, which are typed by hand. `start` does no work of its own and still needs it: `serve`
  serialises it, so it **queues behind** a pipeline that is still running. `pipelineRead` is not a
  guess but a ceiling over the daemon's own ceilings — `patience` + `inferenceCeiling` +
  `worstCaseCallsPerStop` × `worstCaseCallSeconds` — and `daemonCeilingsFitTheClientTimeout` asserts
  the sum still fits. Do not read a number off this page and trust it; read the constants. The
  consequence worth keeping in view: a chord arriving during the one start-up model load waits up to
  17 s and must not be reported as an unreachable daemon.
- **`abort` is the ONE verb `ControlServer` does not serialise** (`Command.isServedConcurrently`),
  and that is a requirement of §6 rather than an optimisation. The handler runs the whole tail of an
  attempt inline, so an abort taking `handlerLock` was decided only *after* the dictation it meant to
  cancel had been typed — `processing × abort → cancel` was accepted and cancelled nothing. Both
  orders are safe because the **transition**, not the handler, is the atomic point: an abort that
  wins leaves the machine idle, so `.recognised` yields no injection effect and `recognise` drops the
  text; one that arrives after `injecting` is refused by D20. It keeps `pipelineRead` even though it
  queues behind nothing, because a cancel spends two `agtermctl` subprocesses of its own and 3 s
  there makes `dictactl abort` announce a dead daemon that is at that moment cancelling for the user.
  Nothing else may join it: every other verb begins or ends an attempt, and two of those resolving at
  once is what the serialisation and D7 exist to prevent.
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
- **"No dock icon" means no dock TILE, and both bundles carry artwork** (§13). The two were one
  phrase for as long as dicta had neither, and they are different objects. What is refused is the
  tile: `LSUIElement` in both plists, because a clickable thing in the dock takes focus from the
  terminal dicta is about to type into and, under D22, silences the hold key by making agterm stop
  being frontmost. The artwork is refused nowhere — macOS lists the daemon in System Settings →
  Privacy & Security → Microphone whether it wants to be an application or not, and that is the one
  screen a user of dicta has to visit. The alternative there was never "no icon" but a blank sheet
  of paper beside a request for their microphone. `Scripts/icon.swift` cuts the shape on the drawn
  outline rather than on a rounded rectangle of its own, and insets it to Apple's 824-on-1024 grid;
  both bundles get the SAME file, since the daemon and the menu are one tool in two processes. It is
  not the menu-bar glyph — that is an SF Symbol per state in `Presentation`, and a menu bar renders
  a template symbol rather than artwork.
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

## Push-to-talk, and why it needs no permission

**Hold right Control, speak, let go.** It is a loop inside the daemon, not a keymap line: agterm's
custom commands fire on key *press* and reject a chord with no modifier, so neither half of "one
key, held" is expressible there (D5). The chords remain, and `⌃⌥⇧D` is the only way to reach **raw**
— a held key stops in `clean` because the gesture that ends the dictation is letting go of the key
that began it. The two mix, and `HoldTrigger` carries the attempt id from its own `start` so the
release lands as §6's silent no-op rather than an audible "nothing to stop" (D23).

The part that is easy to get wrong on a later edit: **this is not a keyboard monitor, and everything
depends on it staying that way.** `CGEventSource.flagsState` returns a word of modifier flags with
no key code and no character in it, which is why macOS asks for nothing — every other push-to-talk
tool on this platform wants Input Monitoring or Accessibility. Reach for `CGEvent.tapCreate` or
`NSEvent.addGlobalMonitorForEvents` "just to know which key" and the user gets a permission dialog
for a promise this project made. `Scripts/linkage.sh` fails by name if that happens.

More rules that are not obvious from the code:

- **The key is a *side*, and that is load-bearing.** Right Control is `0x2000`, left Control is
  `0x1`; right Command is `0x10`, left Command is `0x8` — the device-dependent bits, measured on
  this user's external keyboard (F6) and, for the Command pair and right Option `0x40`, on the
  built-in one (F6a). Matching the ordinary `.maskControl` instead would open the microphone on
  every `⌃C` and `⌃R` typed in a terminal, which is all day long.
- **TWO keys are armed, and they are one gesture** (F6a, 2026-08-24). **The laptop's built-in
  keyboard has no right Control key**, so D5's key existed on the external keyboard and nowhere
  else, and on the machine's own keyboard push-to-talk was not degraded but absent. `HoldWatch` in
  `DictaCore` multiplexes the watches: **whichever armed key goes down first owns the attempt until
  it is released**, and every edge of every other key is swallowed. Two traps live in that, and both
  are asserted. Report the non-owner's release and the other key, pressed idly mid-dictation, STOPS
  AND DELIVERS while the user is still speaking. Skip sampling the watches whose edges are being
  swallowed and their state goes stale, so a key pressed during someone else's hold fires a `down`
  minutes later, at whatever is frontmost then — every watch is sampled on every call, and only the
  reporting is filtered. Right Command was chosen over right Shift (a run of capitals holds it past
  the floor) and over Fn (`Fn`+arrows is Home/End, and macOS gives the key an action of its own;
  it does appear in the flags on this keyboard, which is F6's claim to the contrary corrected).
  `--hold-key <name>` re-arms without a rebuild and REPLACES the pair rather than adding to it.
- **A hold under 300 ms aborts and does not deliver** (D21). Both keys are real modifiers, so a
  combination typed with one is indistinguishable from a very short dictation to a source that sees
  only state. Duration is the whole separation: an ordinary press measured 90-150 ms on the external
  keyboard and 86-195 ms on the built-in one, speaking does not. **The margin is no longer "twice
  the longest press"** — F6a's 195 ms took that, leaving 105 ms — and the one everyday gesture that
  clears the floor on purpose is `⌘Tab` held with the right hand, which costs an attempt with no
  text in it and never an injection (D22 read frontmost at the press). The floor is NOT a delay
  before recording starts — waiting would spend it out of F4's budget on every real dictation.
- **`SystemFrontmost` holds an observer that looks unused and is the only reason any of this
  works.** `NSWorkspace.frontmostApplication` reads a per-process cache that is only refreshed if
  something in the process has subscribed to the workspace notification centre. With no observer it
  is filled by the first read and never changes again — measured, 17 samples across three app
  switches, in a process with a live main-thread run loop (F8a). A main run loop is necessary and
  NOT sufficient. Delete the observer in `SystemFrontmost` and D22 stops holding silently, in the
  worst direction: the value freezes at whatever was frontmost when the daemon started, which is
  agterm whenever it was started from an agterm session, so the key arms in every application for
  ever. `CGWindowList` is not the substitute — it tracks without an observer but answers "who owns
  the topmost layer-0 window", and with Finder frontmost and no Finder window open it names
  somebody else.
- **Frontmost is read at the press, not in the sender.** `NSWorkspace.frontmostApplication` matched
  against `com.umputun.agterm` (D22), captured in the poll loop, because the sender thread can be
  seconds behind the keypress and D4 forbids re-deciding a target mid-attempt. Not frontmost is
  **silent** — a notification there would fire on every right-Control combination typed in a
  browser. A session that cannot be resolved is loud, because the key did mean something and
  produced nothing.

- **`dictate` blocks, and must be served concurrently or it deadlocks** (D29). `dictactl dictate`
  waits for the user to speak and hands the text back on stdout instead of typing it. The `start`
  and `stop` that produce what it is waiting for run through the SAME handler, so holding
  `handlerLock` across the wait would make it wait for an event it was itself preventing. It is the
  second entry in `Command.isServedConcurrently` and the reasoning is not the same as `abort`'s:
  `abort` overtakes work in flight, `dictate` starts none.
  Two more that look like polish and are not. Its **stdout is data** — the output is spliced into a
  shell variable and from there into another program's argument, so a friendly "nobody dictated
  anything" printed there becomes the user's prompt; reasons go to stderr and emptiness becomes an
  exit code (`ClientCommand.writesDataToStdout`). And the outcome is `returned`, never `injected`:
  no keystroke was sent, and a record claiming one would be lying about the thing it exists to be
  trusted on.
  The claim is also what lifts D24's picker refusal — that rule protects the pane behind the dialog,
  and with a caller waiting the words are not going there anyway.
- **agterm's own picker is in front of the terminal, and D22 cannot see that.** The picker is
  agterm's window, so `frontmostApplication` says agterm and the dictation would land in the pane
  BEHIND the dialog — silently, since nothing on screen says otherwise. The tree's top-level
  `pickPending` names it, so `focusedTarget` refuses first and refuses **before** capture (D24). The
  user's own `claude-ask.sh` opens exactly such a picker on ⌃⌥C, so this is their daily path and not
  a corner. Typing INTO the picker needs an agterm verb that does not exist: `pick --query` sets the
  query only at open, and nothing sets it on an open one.
- **The trigger resolves nothing itself.** It sends `start` with `focus: true` and no session, and
  the daemon reads BOTH halves of the target out of one `agtermctl tree --json`. An earlier draft
  had the trigger look up the session and let the daemon resolve the pane afterwards: two
  subprocesses on the hot path, and a target assembled from two moments that can disagree. The flag
  is explicit and a missing session never implies it — `$AGT_SESSION_ID` expands to an empty string
  when unset, so "no session means use focus" would turn a stale keymap line into a chord that
  dictates wherever focus happens to be.

`HoldTrigger` reaches the daemon through the daemon's own control socket, exactly as `dictactl`
does, rather than calling into `Daemon` in-process. That is deliberate: `ControlServer` is where
commands are serialised, and a second door into the lifecycle would be a code path no chord has.
Two real `Thread`s — one polling at 16 ms, one sending — for the reason at the bottom of the list
below about the control socket: the sender blocks for the length of a whole dictation, and Darwin's
non-overcommit pool does not grow when its threads block.

## The menu bar, and why the daemon does not know it exists

**A second signed bundle, `DictaMenu.app`, under a LaunchAgent of its own (D27).** It is `dictactl`
with a face: a second client of the same control socket, linking `DictaCore`, `DictaIPC`,
`DictaRecord` and SwiftUI. `Scripts/bundle.sh` builds both bundles and `Scripts/install.sh` installs
both agents; one certificate, two identities, and the daemon's designated requirement did not move
when the second arrived — which is the property the microphone grant rests on.

**The daemon cannot tell whether a UI is running, and nothing about a dictation depends on it.** It
holds no reference to the menu, spawns nothing, and checks for nothing. With the menu absent, quit
or crashed, every dictation behaves identically — measured, not assumed: 120 warm attempts in two
alternating blocks put the difference below the run-to-run noise floor. That is what makes the strip
a *display* of dicta rather than a part of it, and it is why a UI bug can never cost a dictation.

More that is not obvious from the code:

- **`watch` is a second connection SHAPE, not a sixth verb.** Every other command is one frame in,
  one frame out, and every read timeout is sized as "how long may one answer take". A watcher
  outlives the commands it observes, so it needed a timeout invented rather than reused
  (`ControlTimeouts.watchIdle`), a cap, and a rule for ending. It is the third entry in
  `Command.isServedConcurrently`, and the test that list encodes is "does this verb begin an attempt
  or end one" — a watcher does neither, and holding the handler lock for its lifetime would not
  delay a chord, it would stop the daemon serving any at all.
- **A dropped connection is never how a stream ends.** `ControlClient` reads a close as
  `closedByPeer` and reports that the daemon died, so a watcher would announce a crash every time
  the daemon shut down cleanly. A shutdown sends `WatchEvent.end` with a reason and the panel says
  "dicta stopped" in amber; the watcher cap is refused with an ordinary short `Response` for the
  same reason.
- **Attaching is its own first event, and it was not, which is F9b.** The daemon publishes on
  transitions, so a watcher that attached to an idle daemon was told nothing until somebody
  dictated: after a restart the strip went on saying the daemon was unreachable over a connection
  that had been live for minutes, and nobody dictates at a strip that says dicta is dead. The
  handshake `Response` already carried the snapshot — `ControlClient.watch` was discarding it — and
  now delivers it as the stream's first `update`, with no `sequence`, which is already this
  protocol's word for "not a transition".
- **The subscription starts on the LABEL, never on the panel.** `MenuBarExtra` builds its content
  lazily, so a `.task` on the panel runs when somebody clicks the item and never otherwise (F9a: a
  freshly launched menu held zero sockets). The label is the one view that always exists.
- **The menu-bar item carries a running clock while the microphone is open**, because a glyph that
  changes only its fill is not legible without being looked at (F9). The clock changes the item's
  width, which moves every icon to its left, and that is the change peripheral vision reads. D13
  reaches it in full: the clock starts when capture confirms, never at the keypress, and is absent
  through `warming`.
- **The second hand runs only while something is counting** — a recording, or an open panel.
  Otherwise the menu accrues no CPU at all over a minute, which is the same argument that stopped
  the UI polling `status` at 1 Hz.
- **The UI never injects, and that is structural rather than remembered** (D28). Recovery is the
  clipboard, loaded from `final` and never from `recognised`, so a row that produced no `final` has
  **no copy button at all** rather than a disabled one — there is no branch that could point the
  affordance at the wrong field. There is no Start either: a click carries no session to aim at
  (D30), which is also why Stop and Abort are absent when idle rather than greyed out.
- **A row's reason is §9's own `error`, verbatim** — one event, one wording. Two exceptions found by
  reading the real record rather than by reasoning: an empty string, and a "reason" that is only the
  outcome's own raw value, which is what 870 of 902 entries on this machine actually contain.
- **The live target line resolves the session's NAME itself**, out of its own `agtermctl tree
  --json`, only while an attempt is live and only once per session id. The daemon is not asked to
  carry it: that would put a subprocess on the transition path, which F4 vetoes. `SessionNames` is
  therefore a second, deliberately narrower decoder of a tree `Agterm` already parses — safe because
  it decides nothing and falls back to the session id, where `Agterm`'s answer aims keystrokes and
  must fail closed. `test: the name reader and the target resolver read the same tree` runs both
  over one fixture so they cannot drift.
- **`docs/ui-vocabulary.md` is the written form of what acta and dicta share**, and it is a COPY in
  each repository because they share no package. When it disagrees with `Presentation.swift` and
  `MenuModel.swift`, those are what ship and the document is what is wrong.

## Not verified automatically (needs a human)

Push-to-talk adds three items and they are the ones most likely to be skipped: **H11** scores step
6's criteria (a)-(e) in a real pane, **H14** scores (f) — the same gesture on right Command with the
external keyboard UNPLUGGED, since with it attached a pass proves nothing about the laptop — and
**H12** exists because F8 measured `NSWorkspace` from a child of the user's terminal and *not* from
a LaunchAgent. If that call returns nil under launchd, D22 stops
holding and the key dictates from inside Safari — the same shape of gap that made F4's old number
describe a build with a fake microphone in it.

**`docs/manual-checklist.md` is the list, and it is complete** — every item states the observation
that counts as a pass, so two people scoring it agree. In short: that the chords fire and
land in the pane they were pressed in; that injection lands in **Claude Code's** input line
specifically (F5 verified a fish prompt, which is not the same thing); microphone TCC; recognition
quality on this user's own speech through their own microphone — the Task 10 probe used synthesised
speech and a meeting recording, which establishes that the pipeline works and not that it works for
them; sleep/wake and AirPods route changes mid-attempt; daemon lifecycle across logout/login.
