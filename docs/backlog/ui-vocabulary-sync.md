---
worth: yes
where: docs/ui-vocabulary.md:69
added: 2026-09-12
---
# dicta's copy of the shared UI vocabulary no longer describes acta

`docs/ui-vocabulary.md` exists in both repositories as a copy, and nothing mechanical keeps the copies
in step. acta's copy gained two amendments that dicta's lacks:

- **2026-09-11**: `ControlViewModel` moved into an importable module; a bounded, self-sizing
  microphone section; the `BoundedSectionLayout` trap.
- **2026-09-12**: the quiet panel's five divergences — no dividers but one, a one-line header with
  no status text, no status dot, the real recording title, and a utility line instead of a footer —
  plus a Settings window replacing the settings disclosure.

Sync dicta's copy **as an accurate description of what acta now does**. Those amendments state
explicitly that they ask nothing of dicta, so copying them in is not adopting the design.

Record dicta's own decisions separately, as they are taken in `quiet-outcome-markers` and
`menu-panel-visual-review`, including the ones that keep a divergence (the header status line, no
Quit, no revision).

Do not paste acta's introduction verbatim: it describes dicta as the place the other copy lives, and
its account of who wrote the file is written from acta's side. The existing rule stands — shipped
code decides behaviour and the document is what gets corrected — but that rule does not turn a bug in
the code into a decision.

Agreed with Codex on 2026-09-12 while reviewing what dicta should inherit from acta's `dev` branch.
