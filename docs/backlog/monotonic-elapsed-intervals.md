---
worth: yes
where: Sources/DictaCore/PushToTalk.swift:243
added: 2026-09-12
---
# elapsed intervals are measured on the wall clock

Several intervals are measured as a difference of wall-clock `Date`s, so a step of the system clock
moves them without any time having passed:

- **Push-to-talk hold (D21).** `PushToTalk.up(at:)` computes the hold as `now.timeIntervalSince(since)`,
  and both ends come from `clock.now` in `HoldTrigger.sample()`, i.e. `Date()`.
  - A forward step during a short press can turn an accidental modifier chord into a **delivery**.
  - A backward step of a few seconds during an ordinary multi-second dictation can make
    `held < floor` and **discard** it. The 300 ms floor is where the classification flips, not the
    length of the vulnerable holds.
- **The recording timer.** `Daemon.snapshot` computes `speakingSeconds` as `clock.now` minus
  `speechStartedAt` (`Sources/DictaRuntime/Daemon.swift:1496`), and `MenuModel.speakingSeconds(at:)`
  extrapolates with `Date` minus `receivedAt` (`Sources/DictaCore/MenuModel.swift:177`). The effect
  there is cosmetic: the clock jumps.

This is a provable sensitivity to the input times. It is not an observed defect: no frequent clock
step has been seen on this machine, which is why the item ranks below F10 and the menu adapter.

acta fixed the same class in its reminder rules (`~/dev/acta` `Sources/ActaKit/MonotonicClock.swift`,
commit `62274b5`): a `Date`-shaped timeline built from `ContinuousClock`, so that differences are
real elapsed time.

**Take the principle, not a wholesale swap of `SystemClock.now`.** The same clock writes the calendar
timestamps in §9's record, and those must stay wall time. The fix therefore separates wall timestamps
from elapsed intervals. Not in scope, because they already avoid the problem:

- the cap and the drain watchdog, which wait on relative semaphore timeouts;
- `audioSeconds`, which comes from the buffer length.

Tests to add:

- a short hold plus a forward wall-clock step still discards;
- an ordinary hold plus a backward step still delivers;
- the timer does not jump on either step.

Agreed with Codex on 2026-09-12 while reviewing what dicta should inherit from acta's `dev` branch.
