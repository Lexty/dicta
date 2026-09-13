# dicta

Voice dictation into **agterm** — hold the right Control key (or the right Command key, which is the
one a MacBook keyboard actually has), speak, let go, and the text appears in the input line you were
typing in. It is meant for dictating prompts to Claude Code and instructions
to agents running inside agterm.

It can also type into **the focused text field of any other application** — the VS Code editor and
its integrated terminal, Slack, a Safari text area — and then agterm becomes optional. That is a
choice you make once, in the menu bar's setup window, because it needs the Accessibility permission;
see [Dictating into any app](#dictating-into-any-app).

Everything is local. The audio is recognised on this machine by Parakeet TDT 0.6B v3 on the Apple
Neural Engine, is never written to disk, and never leaves the computer.

**The text is never submitted on your behalf.** `agtermctl session type` injects real keystrokes
with no bracketed paste, so any newline in recognised text would be a Return that fires a
half-written prompt. Every path through dicta ends in one sanitiser, and what it produces is a
single line.

`SPEC.md` is the normative document — every decision below is cited there as D*, every measurement
as F*, and the invariants as §8. `AGENTS.md` is the operating manual for working *on* dicta;
this file is for using it.

**Status: steps 1–3 of SPEC.md §10 are implemented.** The external filter (step 4) is not: the seam
exists as a pass-through, which is all `raw` mode needs in order to be *defined* as the mode that
skips it.
Dictating into the focused field of any application is implemented (D31, D32), and is chosen in the
setup window; what only a person can score about it is H24–H34, and about the setup window H35–H43,
in `docs/manual-checklist.md`.

## Requirements

- macOS on Apple silicon (measured on macOS 26.6, M3 Pro).
- Swift 6.3+ — Command Line Tools are enough; full Xcode is not required.
- `agterm` with `agtermctl` on `PATH` — **unless** you choose other applications in the setup window,
  where it is optional: without it the daemon dictates into other applications' fields and refuses
  only what needs agterm (the chords, and the key held in front of agterm). A daemon with no agterm
  and no choice yet does not exit: it waits for the choice. Under `--no-hold` it does exit, since
  then nothing could start a dictation without agterm.
- For other applications only: the Accessibility permission for `Dicta.app`, asked for from the
  setup window.
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

The installer does not choose where dictation goes, and takes no option for it. The menu-bar item's
setup window does: it opens by itself when a choice is pending, and "Set Up…" in the panel reopens it
(`dictactl configure` is the same choice from a shell). `install.sh --focused-fields` is refused. An
agent installed with that flag before the choice was stored keeps it for one more start, so the
daemon can seed the choice from it; afterwards the stored choice decides. The installer prints the
keymap step only when it finds `agtermctl`, and ends by naming the setup window.

**What the setup window asks, and when.** On a fresh install it says what dicta does and offers
**Set up dictation**, which is the choice to type into other applications; "Use only with agterm" is
a secondary link, shown only when agterm is found. If you were already dictating into agterm before
this window existed, nothing changes until you answer: it offers "Dicta can now type into other apps"
once, with Enable and Keep agterm only, and closing it counts as keeping. Until a choice is made,
agterm dictation works exactly as before, other applications stay closed, and no accessibility call
is made. The choice is stored in
`~/Library/Application Support/dev.personal.dicta/setup.json`, which only the daemon writes, and it
takes effect at the next hold without a restart — never in the middle of a dictation. It stays
reversible from the same window, in both directions. The window opens by itself only at the first
state the menu receives after it launches, and only when nothing is being dictated, so it never takes
focus from a pane in the middle of a session.

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

Finally, add the chords, if you want them — agterm only. Push-to-talk works without this step; the chords are how
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
  the models are not downloaded (runs `--fetch-models`), `agtermctl` is not on the PATH while the
  choice is agterm only. A step you have not taken yet is not a fault and is never red: a choice not
  made, or the Accessibility permission not granted, is an amber notice whose button opens the setup
  window. With other applications chosen, a missing `agtermctl` is an amber notice too, and
  dictation into other applications works.
- **where the current dictation is going**, by session name and pane (or by application name, for a
  focused field), with `Stop and type` and
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

It asks for **no permission** — unless you choose other applications in the setup window, which
needs Accessibility to type into another application, not to read the key — and that is worth being precise about, because every other
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
- **Unless other applications are chosen, it does nothing unless agterm is in front.** A chord carries the
  session it fired in; a held key carries nothing, so the session comes from live focus — and live
  focus is only meaningful while you are looking at agterm. Hold it in a browser and nothing at all
  happens, silently (D22). With other applications chosen, the same hold in a browser dictates into
  the focused field instead; agterm in front always takes the agterm path.

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

## Dictating into any app

Start from the setup window: click the menu-bar microphone, then **Set Up…**, and choose **Set up
dictation** (or **Enable**, if you had kept agterm only). From a shell the same choice is `dictactl
configure --scope other-apps`, and `dictactl configure --scope agterm-only` takes it back. From then
on, **holding the key in any application types into the text field that has focus there**. agterm in
front still takes the agterm path, exactly as before: it knows the session and the pane, it has the
indicator, and it needs no permission (D31).

The window then shows a checklist of what a dictation still needs: the Accessibility permission, the
models, the microphone, and the hold key that is actually armed (or that none is, under `--no-hold`).
"Use only with agterm" on the same screen is the way back.

**The Accessibility permission.** Posting keystrokes into another process needs it, and without it
macOS discards them silently (F11). The daemon never asks for it at start-up. The checklist's
**Allow Access…** asks — after the window has said why — and only once the choice is other
applications: the system dialog opens and `Dicta` is added to System Settings → Privacy & Security →
Accessibility, where you turn it on (add `~/Applications/Dicta.app` with `+` if it is somehow not
listed). After that the button becomes **Open Accessibility Settings**. The row turns done when you
come back to the window; nothing polls the permission, so while nobody looks, a grant or a revocation
is noticed at the next hold instead. `dictactl accessibility` reads the grant from a shell and
prints `accessibility is granted` or `accessibility is not granted`, and
`dictactl accessibility --prompt` asks, as the button does. Until it is granted, every hold outside
agterm that passes the floor does nothing, silently, the microphone never opens, and the menu bar
shows an amber notice. The grant is picked up without a restart, and a rebuild does not revoke it,
for the same signing reason as the microphone's. The daemon's log says where the choice came from
(`setup: other-apps, from setup.json`) and what it found: `focused fields: on, accessibility:
granted` or `not granted`. **Until other applications are chosen, dicta makes no accessibility call
and posts no event at all**, so the permission is never needed and never asked about.

**An install from before the setup window** that ran `install.sh --focused-fields` is not asked
again: on its first start the daemon records that choice in `setup.json` and logs that the flag
seeded it; afterwards it logs that the flag was ignored, because the file decides.

**Outside agterm, the start waits for the floor.** Right Control and right Command are real
modifiers, so a right-hand `⌘C` looks like the start of a dictation until 300 ms have passed. On
this path nothing is sent until the hold outlasts the floor: a shortcut released before it costs
nothing at all — no sound, no notification, no microphone, no line in the record. The price is that
`Pop` arrives **about 300 ms later** than it does in agterm. Nothing is lost by it: wait for `Pop`
before speaking, as always (D13). A shortcut held past the floor, such as `⌘Tab` with the right
hand, does start an attempt; one whose hold switched the application is cancelled silently, with no
text, no sound and no notification.

**What it types into, and what it refuses.** Only a real text field: a text area or text field whose
value can be edited. A focused button, list, sidebar tree or page receives nothing, because plain
characters there act as commands or type-to-select, and dicta is not voice control. **A password
field is refused**, by its kind, without anything in it being read; so is any dictation while
Secure Input is on anywhere on the machine. Each refusal happens before the microphone opens, with
`Basso` and a notification. dicta never reads what a field contains, only what kind of thing it is.

**Where the text goes, and where it does not.** The target is the application and the field that had
focus when the hold passed the floor. Before the first keystroke dicta checks that the same field is
still focused in the same application, and if not it types nothing and says so; the text is in
`dictactl last`. If you switch to another application while a long text is being typed, it stops
there, never finishes in the new application, and says the insertion may be partial. **Moving focus
inside the same application while the text is being typed is not detected** — the VS Code editor to
its terminal, for instance — so do not do that mid-delivery.

**Feedback is sounds and notifications**, since there is no agterm indicator: `Pop` when the
microphone is running, `Tink` on delivery, `Basso` with a notification when something went wrong.
Under a Focus mode macOS suppresses the notification, and `Basso` plus the record are all there is.
The menu bar works unchanged and names the application instead of a session.

**The chords stay agterm-only, and so does raw mode.** The chords fire through agterm's keymap; in
any other application the held key is the whole interface, and it always stops in **clean**.

**The pasteboard is never used.** The text arrives as Unicode keystrokes posted to that application's
process, not as a paste, so whatever you had copied is untouched — the clipboard stays yours, and
the panel's copy button is still the way to recover a dictation that went nowhere (D32).

**VS Code, and Electron applications in general, need their accessibility tree switched on.** VS
Code and Slack expose no focused field until something sets `AXManualAccessibility` on them (F11).
dicta sets it the first time you dictate into such an application and reads again; that setting
stays on for the life of that application's process. If the tree is not ready in time, the first
dictation after the application launches is refused, and the next one works — or relaunch the
application after granting. What F11 saw in VS Code, so that it is not mistaken for a dicta fault:
the text arrives identical in the editor, the integrated terminal (with Claude Code in it) and the
chat input; a long line in a JavaScript editor can make VS Code stop responding for several seconds
while it catches up, without changing the text; and a dictation that ends mid-word can leave the
editor's autocomplete open, so your next Return accepts the suggestion. Slack applies its own
rewrites — curly quotes, emoji as `:shortcodes:` — which dicta cannot see.

**Submitting is still yours.** The same sanitiser runs last on this path, so what is typed is a
single line with no Return in it; a terminal in VS Code submits on Return exactly as agterm does.

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

With other applications chosen, a hold in another application also feeds a waiting `dictactl
dictate`, and nothing is typed there. The refusals still apply as if it were typing: the grant,
Secure Input, and a focused element that has to be a text field.

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
  toggle         start if idle, otherwise stop and deliver — what every chord calls (D7)
  start          begin an attempt
  stop           end an attempt and deliver in the given mode
  abort          end an attempt and deliver nothing
  status         print the daemon's current state
  last           print the text of the most recent attempt
  watch          print the daemon's state as one JSON line per change, until it stops (D27)
  dictate        wait for the next dictation and print its text — nothing is typed (D29)
  configure      record where dictation goes, as the setup window does (D31)
  accessibility  read the Accessibility grant; with --prompt, ask the system for it first

options:
  --mode <clean|raw>   clean runs the filter, raw skips it and nothing else (§2)
  --session <id>       the agterm session the chord fired in; pass "$AGT_SESSION_ID"
  --socket <path>      agterm's control socket; pass "$AGT_SOCKET"
  --control <path>     dicta's own control socket (defaults to the one under
                       ~/Library/Application Support/dev.personal.dicta)
  --recognised         on last: print the recogniser's verbatim output instead of what was
                       injected — the two together are how a replacement misfire is diagnosed
  --timeout <seconds>  on dictate: how long to wait for the user to speak before giving up
  --scope <agterm-only|other-apps>
                       on configure: agterm's panes only, or the focused field of other apps too
  --offer-seen         on configure: the one-time offer to type into other apps was answered
  --prompt             on accessibility: show the system's permission dialog (other-apps only)

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
  --agterm-socket <path>   agterm's control socket, when it is not the default one
  --fetch-models           download the recognition models, then exit
  --no-hold                do not arm push-to-talk; the keymap chords still work
  --hold-key <name>        arm push-to-talk on this key instead of the default pair
                           (rightControl|rightCommand|rightOption); repeat the flag to arm several
  --focused-fields         the initial choice when setup has not been done: also dictate into
                           the focused text field of any other application
  --help                   print this
```

A chord that passes `"$AGT_SOCKET"` overrides `--agterm-socket` per attempt; the flag is the
fallback for a keymap that does not. The first `--hold-key` **replaces** the default pair rather than
adding to it.

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
| `target` | what was resolved at the start, and never substituted: `sessionID` and `pane` for agterm, or `field` with the application's `appName`, `bundleID` and `pid` for a focused field |
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
  put your prompt in somebody else's agent (D4). A focused field is the same: if another field or
  application has focus when the text is due, nothing is typed and the text is in `dictactl last`.
- **A hold in another application does nothing, or says it was refused.** Silence means the choice
  is not other applications (`~/Library/Logs/dicta.log` says `setup: agterm-only` or `undecided`,
  and `focused fields: off`), or the Accessibility grant is missing. A refusal
  names the reason: the Accessibility grant, Secure Input, or a focused thing that is not a text
  field. A refused first dictation into a freshly launched VS Code or Slack is their accessibility
  tree not being ready yet; the next one works.
- **The log says `setup problem:`.** `setup.json` could not be used — not valid JSON, written by a
  newer build, or not a readable file — so dicta types only into agterm, and the setup window opens
  with "Choose where dictation goes again". Choosing again replaces the file and keeps the original
  beside it as `setup.json.unreadable`. A `setup problem:` naming a step that failed is a choice that
  could not be saved: it holds for this run only, and the window shows the reason.
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
