---
worth: maybe
where: Sources/DictaRuntime/HoldTrigger.swift:521
added: 2026-09-13
---
# a right-hand ⌘Tab can be refused out loud before it switches

On the focused-field path the refusals are decided at the threshold (D31, as the plan specified):
the grant, then the daemon's Secure Input and eligibility checks. F11 measured a right-hand `⌘Tab`
with a window being chosen at 490–675 ms, always past the floor, and the frontmost pid changes only
when `⌘` comes up. So while the switcher is still open the threshold sees the original application,
and any refusal plays `Basso` and notifies:

- with `--focused-fields` on and no grant, every right-hand `⌘Tab` in any application says the grant
  is missing;
- with the grant, a `⌘Tab` from a focus that is not a text field (a Finder list, a page body, a
  sidebar) says "not a text field".

A hold whose release switched the application is silent once it started (the `silent` abort); a hold
refused before it could start is not, because nothing can know at the threshold that a switch is
coming.

The fix is a trade the user has to make, which is why it is not done: holding the refusal's sound
and notification until the release, and dropping them when the frontmost pid changed by the end of
the settle window, makes `⌘Tab` silent but moves every real refusal from "at the floor" to "when you
let go", after the user may have spoken a whole sentence into a microphone that never opened. The
daemon would also have to stop saying field refusals itself, since today it says them at once.

H32 (c) counts the held-past-the-floor combinations over a day; this item is what to look at if that
count, or the refusals among them, turn out to be a daily annoyance.
