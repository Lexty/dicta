---
worth: later
where: Sources/DictaMenu/DictaMenuApp.swift:92
added: 2026-09-12
---
# the panel's layout has not been judged against acta's quiet redesign

acta redesigned its panel on 2026-09-12 as "variant A, quiet", the idiom of Apple's own menu extras
(`~/dev/acta` commit `324fdd0`). The
two panels sit next to each other in one menu bar, so the question is which of those changes dicta's
panel should follow. **Whether the rest is worth doing is unresolved**, and it is settled only by
looking at the built panel in four states: idle, recording, processing, and unavailable (daemon not
running).

**Decided:**

- **"Open Record" moves to the header of Recent Dictations**, next to the list it opens. acta moved
  "Open Archive" there for the same reason.
- **The footer loses it.** "Restart" stays, as a quiet verb rather than a bordered button. There is
  still no Quit (`docs/ui-vocabulary.md`, deliberate divergences).
- **The status line in the header stays.** acta dropped its status text because it repeated the Start
  button, and dicta has no Start (D30). "Recognising…", "Typing…" and the daemon-link states are said
  nowhere else on the panel.
- **No build revision in the panel.** The menu can only read its own bundle's revision, while
  "Restart" restarts the daemon, and the two bundles can be different builds. A daemon revision would
  need a new snapshot field on the wire, which is not worth adding until real build confusion occurs.

**Candidates, to be judged on the built panel rather than adopted:**

- **Grouping by distance instead of rules**, 6 pt inside a group and 16 pt between (acta keeps one
  rule, above its utility line).
  - The source has four `Divider()`s, but two are conditional (the banner and the target line), so
    the count visible in each state is what matters.
  - acta's own amendment says rules are cheaper to keep right, since a wrong `spacing:` breaks
    grouping silently and no test sees it.
- **A 22 pt tinted tile behind the header glyph.**
- **Type levels.** On this machine `.caption` and `.caption2` both measured 10 pt (acta's board,
  `NSFont.preferredFont(forTextStyle:)`, 2026-09-11). The header status, the row's second line and
  the reason share a size.
  - Take that measurement, not a universal claim about SwiftUI: equal sizes are acceptable when
    placement or an explicit `foregroundStyle` separates them.
  - This is not a standalone "fix caption2" task.

Agreed with Codex on 2026-09-12 while reviewing what dicta should inherit from acta's `dev` branch.
