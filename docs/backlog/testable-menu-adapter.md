---
worth: yes
where: Sources/DictaMenu/StatusViewModel.swift:129
added: 2026-09-12
---
# the menu's view model is untestable, and three defects live in it

`StatusViewModel` sits in the `DictaMenu` executable target, which SwiftPM cannot import, so the
asynchronous logic it owns is unreachable from `DictaTestRunner`. `MenuModel` and `DictationRow` are
pure and tested; the connection, ticker and record-reading code that drives them is not. acta had
the same shape: its `ControlViewModel` lived in the executable, and moving it into an importable
module surfaced four defects the day it became testable (`~/dev/acta` `docs/ui-vocabulary.md`,
amendment of 2026-09-11).

Three defects were found here by reading, and none has a reproducing test yet:

- **The ticker outlives the connection.** `receive(.end)` (line 142) and `finished` (line 148) clear
  the snapshot but never call `updateTicker()`. A ticker started for a recording therefore goes on
  firing once a second after the daemon disconnects, even with the panel closed. The screen does
  not lie — `speakingSeconds` returns nil off `.connected` — but it spends the idle wake-ups
  `updateTicker` exists to refuse.
- **Recent can roll back.** `refreshRecent` (line 197) publishes whichever off-main read finishes
  last, with no generation. Two reads that finish out of order let an older result overwrite a
  newer one.
- **A read error is drawn as an empty record.** `try? RecordReader.tail` turns any failure into `[]`,
  which renders as "Nothing yet." `AGENTS.md` calls the empty/unread confusion unreachable, but
  that argument covers the moment before the first read completes, not a read that failed.

Fix: extract an importable UI adapter with injected dependencies (socket client, record reader,
clock/timer, main-actor hop).

- **Not into `DictaRuntime`.** That module links FluidAudio and AVFoundation, and D27 keeps the menu
  out of it.
- **The menu's linkage budget in `Scripts/linkage.sh` must still hold.**

Acceptance criteria, each with a test that fails before the fix:

- **(a) Ticker.** `.end` and an abnormal disconnect stop the ticker while the panel is closed. With
  the panel open, the ticks the relative dates need keep coming.
- **(b) Ordering.** Two reads completed in reverse order, under test control, do not roll Recent
  back. The generation check is on the side that publishes the result, and the test drives
  completion order rather than relying on a real filesystem race.
- **(c) Read errors.** A failed read is not rendered as an authoritative "Nothing yet." Keeping the
  last good rows marked stale, or showing a distinct error state, is an implementation choice; a
  new banner is not required.

Agreed with Codex on 2026-09-12 while reviewing what dicta should inherit from acta's `dev` branch.
