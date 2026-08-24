# dicta

Voice dictation into **agterm** — hold the right Control key (or the right Command key, which is the
one a MacBook keyboard actually has), speak, let go, and the text appears in the input line you were
typing in. It is meant for dictating prompts to Claude Code and instructions
to agents running inside agterm.

Everything is local. The audio is recognised on this machine by Parakeet TDT 0.6B v3 on the Apple
Neural Engine, is never written to disk, and never leaves the computer.

**The text is never submitted on your behalf.** `agtermctl session type` injects real keystrokes
with no bracketed paste, so any newline in recognised text would be a Return that fires a
half-written prompt. Every path through dicta ends in one sanitiser, and what it produces is a
single line.

`SPEC.md` is the normative document — every decision below is cited there as D*, every measurement
as F*, and the invariants as §8. `CLAUDE.md` is the operating manual for working *on* dicta;
this file is for using it.

**Status: steps 1–3 of SPEC.md §10 are implemented.** The external filter (step 4) is not: the seam
exists as a pass-through, which is all `raw` mode needs in order to be *defined* as the mode that
skips it.

## Requirements

- macOS on Apple silicon (measured on macOS 26.6, M3 Pro).
- Swift 6.3+ — Command Line Tools are enough; full Xcode is not required.
- `agterm` with `agtermctl` on `PATH`.
- ~600 MB of disk for the recognition models, and one download to fetch them.

## Install

```sh
bash Scripts/install.sh
```

That one command builds a release, signs `Dicta.app`, installs the pieces and reloads the agent:

| what | where | why there |
|---|---|---|
| `dictactl` | `~/.local/bin/dictactl` | the keymap invokes it by absolute path, so it must not move with the checkout |
| `Dicta.app` | `~/Applications/Dicta.app` | the signed bundle is the identity the microphone permission attaches to (D11) |
| `DictaMenu.app` | `~/Applications/DictaMenu.app` | the menu-bar item — a second bundle, so the daemon's identity and its permission are untouched |
| the LaunchAgent | `~/Library/LaunchAgents/dev.personal.dicta.plist` | starts the daemon at login and keeps it running |
| the menu's agent | `~/Library/LaunchAgents/dev.personal.dicta.menu.plist` | starts the menu-bar item at login |
| the log | `~/Library/Logs/dicta.log` | the daemon's stderr |

The signing identity is self-signed, created in a dedicated keychain by `Scripts/setup-signing.sh`,
which `bundle.sh` calls on its own when it is missing. It matters because the resulting *designated
requirement* names the identity rather than a hash of the code: rebuilding dicta does not revoke the
microphone permission you granted it. `bash Scripts/bundle.sh --print-requirement` prints it.

Then fetch the models, once, and restart the daemon afterwards:

```sh
~/Applications/Dicta.app/Contents/MacOS/Dicta --fetch-models
launchctl kickstart -k gui/$UID/dev.personal.dicta
```

The restart is not optional on a fresh install, and the reason is worth a sentence. The models are
loaded **once**, at daemon start, and never on the attempt path (D10) — so the daemon the installer
has just started has already found them missing and given up. Without the kickstart it would refuse
every dictation until the next login, and you would find that out by pressing a chord and losing an
utterance. `--fetch-models` prints this command when it finishes, for the same reason.

The daemon never downloads anything by itself. It starts at login, on whatever network the laptop
woke up on, and six hundred megabytes of unannounced traffic is not something to do quietly — so a
missing model bundle is a loud message at startup naming this command, and that message is the
asking.

The models land in FluidAudio's own cache at
`~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3`.

Finally, add the chords, if you want them. Push-to-talk works without this step; the chords are how
**raw** mode is reached, and the installer deliberately does not edit your keymap:

```sh
cat docs/keymap.snippet.conf >> ~/.config/agterm/keymap.conf
agtermctl keymap reload
```

## The menu bar

A microphone appears in the menu bar, and while you are dictating it turns red and grows a clock:

```
… ⏱  🎙  〰  🔋 100% …          idle
… ⏱  ⏺ 0:42  〰  🔋 100% …     dictating, 42 seconds in
```

The clock is there because a glyph that only changes its fill is not something you notice while
working — and because macOS's own microphone indicator tells you that *some* application is
recording, not which. It goes amber in the last minute before the ten-minute cap, so the cap stops
being a surprise that eats a dictation.

Clicking it opens a small panel:

- **what dicta is doing right now**, and — if it cannot dictate at all — one red sentence saying why,
  with the single button that fixes it: the microphone was denied (opens the right Settings pane),
  the models are not downloaded (runs `--fetch-models`), `agtermctl` is not on the PATH.
- **where the current dictation is going**, by session name and pane, with `Stop and type` and
  `Abort`. They are there only while something is being dictated. There is no Start, and there
  cannot be: a click carries no session to aim at, so dictations are started by the key or a chord
  and nothing else.
- **the last five dictations**, each with what was said, how long ago, how it ended, and — when it
  did not go well — the same sentence the notification gave you. A button copies the text. That is
  the whole recovery story: if a dictation went nowhere because you closed the pane, this is where
  you get the words back without opening a terminal.

A dictation that was cancelled shows what dicta *heard*, in italic, and has **no copy button**. That
is deliberate: those words were never prepared for delivery, and the clipboard is only ever loaded
with text that was.

The menu bar is **optional**. It is a separate application that watches the daemon through the same
socket `dictactl` uses; the daemon does not start it, cannot tell whether it is running, and every
dictation behaves identically without it. To stop it:

```sh
launchctl bootout gui/$UID/dev.personal.dicta.menu
```

`launchctl kickstart -k gui/$UID/dev.personal.dicta.menu` starts it again. Installing it asks for no
permission of any kind, and does not disturb the microphone permission you granted the daemon.

## Holding the key

**Hold right Control, speak, let go.** That is the whole interface, and it needs no keymap line and
no setup: the daemon arms it at startup and says which keys in its log. Nothing is configured
because nothing has to be — these are keys you already have and, on macOS, ones that do nothing by
themselves when held alone.

**Two keys are armed, not one: right Control and right Command.** A MacBook's built-in keyboard has
no right Control key at all, so on the laptop the first one is unreachable and the second is the
whole feature; on an external keyboard both work. They are one gesture rather than two — whichever
you press first owns the dictation until you let it go, and pressing the other one in the middle
does nothing at all. Pass `--hold-key rightOption` (repeatable) to the daemon to arm something else;
`--hold-key` replaces the pair rather than adding to it.

It asks for **no permission**, and that is worth being precise about, because every other
push-to-talk tool on this platform asks for Input Monitoring or Accessibility. dicta does not read
your keyboard. It reads the *state of the modifier keys* — a word of flags that says which of Shift,
Control, Option, Command and Fn are down right now, and carries no key code and no character. There
is nothing in that source for dicta to learn what you type, which is why macOS never asks. The
built daemon is checked for this by `Scripts/linkage.sh`: if it ever gained the ability to read a
keystroke, the check fails by name (invariant 11).

Two rules follow from holding a key rather than pressing a chord:

- **A tap is not a dictation.** Hold it under 300 ms and the attempt is thrown away — no text, no
  injection, no sound. Both are real modifiers, so `⌃C` and `⌘V` typed with your right hand look
  exactly like a very short dictation; the only thing that tells them apart is that an ordinary
  press lasts 86–195 ms and speaking does not (D21). The one combination that does hold a key past
  300 ms is `⌘Tab` — do that with the right-hand Command inside agterm and you spend a dictation
  that recognises nothing. Nothing is typed anywhere; if it becomes a nuisance, arm right Option
  instead.
- **It does nothing unless agterm is in front.** A chord carries the session it fired in; a held key
  carries nothing, so the session comes from live focus — and live focus is only meaningful while
  you are looking at agterm. Hold it in a browser and nothing at all happens, silently (D22).

## The chords

They still work, and one of them is not reachable any other way. The snippet in
`docs/keymap.snippet.conf` binds three, and the file explains each choice in place:

| chord | what it does |
|---|---|
| `⌃⌥D` | start dictating; press again to stop and deliver in **clean** mode |
| `⌃⌥⇧D` | start dictating; press again to stop and deliver in **raw** mode |
| `⌃⌥X` | abort — end the attempt and deliver nothing |

The mode is chosen by *whatever stops* the recording, so nothing has to be decided before you start
speaking (D3). The held key always stops in **clean** — one key cannot carry two meanings — which
is why `⌃⌥⇧D` is where **raw** lives. The two mix: begin by holding the key, then press `⌃⌥⇧D` to
end it, and the text comes back unfiltered. Letting go afterwards is silent (D23).

## Dictating into something dicta cannot type into

agterm's native picker — the dialog `agtermctl pick` opens, and the one your own custom commands use
to collect a line — is a text field, not a terminal surface. `agtermctl session type` cannot reach
it, and there is no way to set the query of a picker that is already open. So a dictation aimed at a
dialog has to arrive **before** the dialog does:

```sh
PROMPT=$(dictactl dictate) && agtermctl pick --query "$PROMPT" --allow-custom
```

`dictactl dictate` blocks, you dictate exactly as always — hold the key, speak, let go — and the
text is printed on stdout instead of being typed anywhere. Nothing reaches an input line. Its stdout
is data, so a timeout or a refusal goes to stderr and shows up as an exit code (4 = nobody spoke,
1 = refused, 3 = no daemon), never as a line of prose that would otherwise become your prompt.

While a caller is waiting like this, holding the key **does** work in front of an open picker —
which it otherwise refuses to do, because the text would land in the terminal behind the dialog
(D24). With somewhere for the words to go, that refusal has nothing to protect.

Each chord is one `toggle`, because start-or-stop is resolved inside the daemon atomically —
writing it in the shell as `status | grep idle && start || stop` leaves a window in which one
keypress can both start and stop (D7).

While an attempt runs, the session's own indicator says where it is: blinking red while listening,
amber while the text is being produced, a brief green on delivery, and blocked plus a notification
when something went wrong. **Nothing is announced until capture confirms the microphone is actually
running** — announcing at the keypress would train you to start speaking before audio flows and lose
the first syllable every time (D13).

## `dictactl`

The client the chords invoke. It is also usable by hand:

```
usage: dictactl <verb> [options]

verbs:
  toggle   start if idle, otherwise stop and deliver — what every chord calls (D7)
  start    begin an attempt
  stop     end an attempt and deliver in the given mode
  abort    end an attempt and deliver nothing
  status   print the daemon's current state
  last     print the text of the most recent attempt
  watch    print the daemon's state as one JSON line per change, until it stops (D27)
  dictate  wait for the next dictation and print its text — nothing is typed anywhere (D29)

options:
  --mode <clean|raw>   clean runs the filter, raw skips it and nothing else (§2)
  --session <id>       the agterm session the chord fired in; pass "$AGT_SESSION_ID"
  --socket <path>      agterm's control socket; pass "$AGT_SOCKET"
  --control <path>     dicta's own control socket (defaults to the one under
                       ~/Library/Application Support/dev.personal.dicta)
  --recognised         on last: print the recogniser's verbatim output instead of what was
                       injected — the two together are how a replacement misfire is diagnosed
  --timeout <seconds>  on dictate: how long to wait for the user to speak before giving up

examples:
  # dictate into a native dialog that dicta cannot type into: collect the text first,
  # then open the dialog already carrying it.
  PROMPT=$(dictactl dictate) && agtermctl pick --query "$PROMPT" --allow-custom
```

`dictactl last` reads the record rather than the daemon's memory, so it survives a restart. Reading
text back out is not injection, and `--recognised` therefore prints exactly what the recogniser
produced, line breaks and all.

The client links nothing but the wire types and the socket. It never opens the microphone: the
permission belongs to the daemon's signed bundle, and a second binary touching the device would
fracture it (D12, §8.8). That is asserted against the linked binary itself by `Scripts/linkage.sh`.

### `Dicta` — the daemon

Normally started by the LaunchAgent that `Scripts/install.sh` writes, and rarely invoked by hand.
Its own options:

```
usage: Dicta [options]

options:
  --control <path>         dicta's own control socket (defaults to the one under
                           ~/Library/Application Support/dev.personal.dicta)
  --agterm-socket <path>   agterm's control socket, when it is not the default one. A chord that
                           passes "$AGT_SOCKET" overrides this per attempt; this is the fallback
                           for a keymap that does not
  --fetch-models           download the recognition models, then exit
  --no-hold                do not arm push-to-talk; the keymap chords still work
  --hold-key <name>        arm push-to-talk on this key instead of the default pair
                           (rightControl|rightCommand|rightOption); repeat the flag to
                           arm several, and note that the first one REPLACES the pair
  --help                   print this
```

`--fetch-models` is a separate invocation rather than something the daemon does at start-up, and
that is deliberate: it starts at login, on whatever network the laptop woke up on, and pulling six
hundred megabytes there without being asked is not a thing to do quietly. A missing bundle is
reported at start-up with this command named in the message.

Two commands read the same socket from two ends, so mind which `--socket` is which: `dictactl
--socket` is **agterm's**, and `--control` is **dicta's**. Conflating them sends dictations to
whichever agterm answers first.

## The replacement dictionary

Parakeet recognises Russian well and **transliterates English technical terms spoken inside Russian
into Cyrillic** — say "FluidAudio" in a Russian sentence and it comes back spelled phonetically, in
Cyrillic letters. That is measured on this machine, not assumed. Undoing it is the whole job of the
dictionary (D9a).

Copy the annotated example and edit it:

```sh
cp docs/replacements.example.conf \
   ~/Library/Application\ Support/dev.personal.dicta/replacements.conf
```

One rule per line, `<id> | <pattern> | <replacement>` — the pattern being the Cyrillic spelling the
recogniser produced, and the replacement the term you actually said:

```
<id>         | <what the recogniser wrote>   | <what you meant>
```

The example file carries real entries from this user's vocabulary; it is also the one file exempt
from the repository's English-only check, because every pattern in it is Cyrillic by construction.

- The **id** is yours and never changes on its own; it is what the record names when the rule fires,
  so a rule written months ago is still identifiable.
- The **pattern** is literal text, not a regular expression, matched case-insensitively. A misfiring
  literal is findable by reading the file.
- Rules run **top to bottom, each over the previous one's result**, so put specific rules above
  general ones.
- **Word boundaries are respected**, and only on a side where the pattern's own edge is a letter or
  a digit — so a pattern ending in `.` or `+` imposes no condition after itself.
- The file is re-read before every dictation. An edit takes effect on the next chord; no restart.

A dictionary never costs you a dictation. A malformed line is skipped, every other rule still
applies, the text is still delivered, and you are notified **once** that the dictionary is degraded.
A file that has never existed is not degraded and says nothing — that is how someone with no
dictionary says so. A rule that empties your text is refused loudly, and the notification says the
dictionary did it, so you are not left inspecting your microphone over a rule you wrote.

## What is kept

Every attempt — delivered, empty, faulted or aborted — leaves one entry in

```
~/Library/Application Support/dev.personal.dicta/record.jsonl
```

one line of JSON each, appended and never rewritten. The entry is written **before** the keystrokes
are attempted, which is the only route by which recognised text survives a delivery failure (§8.10).

| field | what it holds |
|---|---|
| `id` | the attempt's monotonic id, never reused |
| `at` | when the attempt ended |
| `outcome` | one of `injected`, `empty`, `capture-fault`, `recognition-failed`, `filter-fell-back`, `dictionary-degraded`, `target-gone`, `injection-failed`, `injection-partial`, `capped`, `aborted`, `returned` |
| `mode` | `clean` or `raw`, as the stopping chord chose |
| `recognised` | verbatim recogniser output, hazards and all |
| `final` | what was injected, or would have been: replaced, filtered, sanitised |
| `rules` | the ids of the replacement rules that fired, and the dictionary's mtime |
| `target` | the session id and pane resolved at the start, and never substituted |
| `error` | the reason you were shown, when there was one |

`recognised` and `final` are separate on purpose: comparing them, with `rules` beside them, is what
makes a misfiring rule nameable without re-running anything.

```sh
dictactl last                # what dicta typed
dictactl last --recognised   # what you actually said
tail -1 ~/Library/Application\ Support/dev.personal.dicta/record.jsonl | jq .
```

An attempt whose delivery went differently than the saved line claims gets a **second line with the
same id**, and the last line per id wins. The file is append-only; "one entry per attempt" is a
property of the reader.

Audio is not kept — not on disk, not in a journal, not anywhere but RAM for the length of the
attempt (D14). Losing an utterance costs one keypress.

## When something goes wrong

- **Nothing happens on the chord.** `dictactl status`. If the daemon is unreachable the client says
  so with a desktop notification as well as a non-zero exit, and distinguishes "never started" from
  "crashed and left its socket behind". `launchctl kickstart -k gui/$UID/dev.personal.dicta`
  restarts it; `~/Library/Logs/dicta.log` says why it stopped.
- **A fault, and no text.** The audio's integrity was in doubt — an interruption, a route change, a
  sleep, or the ten-minute cap — and dicta discards rather than guessing at the boundary (D16). It
  is reported as hardware and never as silence, because "you said nothing" sends you to the wrong
  place. Whatever text a capped attempt produced is still in the record.
- **The text went nowhere.** If the session or the pane is gone when the keystrokes are due, the
  attempt fails and is recorded; it is never re-aimed at whatever has focus now, because that would
  put your prompt in somebody else's agent (D4).
- **Wrong words.** Compare `recognised` with `final`. If they differ, `rules` names what changed it.
  If they agree, it is the recogniser, and a dictionary rule is how you fix it.

## Building and testing

```sh
swift build                 # debug
bash Scripts/test.sh        # the gate — NOT `swift test`
bash Scripts/lint.sh
bash Scripts/coverage.sh    # DictaCore, with an 80% floor
bash Scripts/run.sh         # the daemon in the foreground, for development
```

`swift test` is not a gate here. Under Command Line Tools with no full Xcode it *builds* the test
bundle and never runs it — there is no `xctest` host — and reports success (D18). `Scripts/test.sh`
runs the tests through an executable target instead, and runs `Scripts/linkage.sh` first.

`Scripts/measure.sh` scores the two timing criteria from numbers rather than impressions: keypress
to recording by default, and stop to injection behind `--stop`. The second one **delivers text into
a pane**, because the interval being measured ends at the last keystroke. It **exits non-zero when
either criterion misses its budget** — a scorer that exits 0 on a FAIL it printed is D18 again, in
the one place a budget is actually scored.
