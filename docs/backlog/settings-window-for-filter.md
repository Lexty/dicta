---
worth: later
added: 2026-09-12
---
# the filter's configuration belongs in a Settings window, not in the panel

Tier 2 of `docs/ui-proposal.md` waits for step 4 of SPEC §10, the external filter (D9b). When it
arrives, **its standing configuration** — the command line, and whatever else D9b ends up exposing —
should go in a real Settings window reached by one "Settings… ⌘," row (`SettingsLink`), not in a
`DisclosureGroup` inside the panel.

acta made that move on 2026-09-12 (`~/dev/acta` commit `77739ca`, `Sources/Acta/SettingsWindow.swift`).
Configuration grew inside its panel until the panel ran off the screen, and a second copy of controls
is the kind that drifts.

Scope, so this does not swallow all of Tier 2:

- **Stays with the dictation, not in Settings:** per-attempt detail, meaning `recognised` against
  `final` and the rules that fired, which remains an expanded row in Recent Dictations.
- **Applied by the daemon.** The daemon must pick settings up without the menu running (D27). A
  `SettingsLink` window is only an editor for a file or a verb the daemon already honours; it does
  not provide that by itself.

**Unresolved:** whether D9b exposes enough standing configuration to justify a window at all.
Tier 2's own argument is that a settings panel with one row in it is worse than none. Settle it when
step 4 defines the filter's configuration.

Agreed with Codex on 2026-09-12 while reviewing what dicta should inherit from acta's `dev` branch.
