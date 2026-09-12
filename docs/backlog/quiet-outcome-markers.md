---
worth: yes
where: Sources/DictaMenu/RecentDictations.swift:106
added: 2026-09-12
---
# Recent Dictations colours the ordinary outcome

Every row in Recent Dictations carries a coloured dot, and most rows are `typed`, so the green dot
marks the ordinary outcome. The eye learns to ignore the field of dots, and an amber or red row
stands out by hue alone, which does not survive a user who cannot tell the hues apart.

acta found the same defect in its recordings list and fixed it (`~/dev/acta` commit `324fdd0`,
`docs/ui-vocabulary.md` amendment of 2026-09-12). The ordinary row is now quiet, and exceptions carry
a symbol as well as a word.

What dicta takes, and what it does not:

- **Only the dot goes on the ordinary outcomes** (`injected`, `returned`).
- **The word stays on every row.** `typed` and `returned to caller` say different things about where
  the text went, and `DictationRow.secondary(at:)` already includes `AttemptOutcome.label`, which
  remains the only source of that word. A marker must not print a second copy of it.
- **The symbol is optional, per outcome, and decided in `DictaCore`** (`DictationRow`, next to
  `tint`), so the test runner can assert it. acta decides its marker in the view (`marker(for:)` in
  `ActaApp.swift`), which D19 rules out here.
- **Absence is not failure.** `cancelled` and `nothing heard` must not get a warning triangle; they
  stay faint.

Agreed with Codex on 2026-09-12 while reviewing what dicta should inherit from acta's `dev` branch.
