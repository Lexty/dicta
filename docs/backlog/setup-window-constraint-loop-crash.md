---
worth: yes
where: Sources/DictaMenu/SetupWindow.swift (SetupWindowController.fitHeight)
added: 2026-09-14
---
# the setup window's layout loops, and AppKit kills DictaMenu when it opens

**Status: fixed in code (`78405f9`), not yet confirmed on hardware.** A probe confirmed the cause,
and the window now sets its height from `fittingSize` instead of tracking `.preferredContentSize`
(Tasks 1 and 2 of `docs/plans/completed/20260914-dicta-setup-window-and-dead-watchers.md`). This
item stays until the installed menu survives **H48**; delete it then.

Observed on 2026-09-14, installing `85665d7` over the build of 2026-08-25. The daemon migrated the
existing user (`setup: agterm-only, migrated: the record holds 651 entries, so this is an update`),
so the offer was pending, and the menu opened the setup window by itself on its first snapshot. About
three seconds after launch DictaMenu died with `Trace/BPT trap: 5`, every time, and launchd's
`KeepAlive` turned that into a crash loop (13 runs within minutes). No `.ips` report was written;
the reason came from running the bundle's executable under `lldb`:

```
NSGenericException: The window has been marked as needing another Update Constraints in Window pass,
but it has already had more Update Constraints in Window passes than there are views in the window.
<NSWindow: 0x8c5296300> {{755, 495}, {440, 224}}
... -[NSWindow(NSConstraintBasedLayoutInternal) updateConstraintsIfNeeded]
... +[NSApplication _crashOnException:]
```

The 440 × 224 window is the offer screen. **Suspected, not verified:** `hosting.sizingOptions =
[.preferredContentSize]` feeds the hosting view's size back into the window while the text inside
it wraps with `.fixedSize(horizontal: false, vertical: true)`, so each window resize changes the
wrapping, which changes the preferred size again. Candidates: size the window once from
`fittingSize` per screen change instead of continuously, or drop the vertical `fixedSize` in favour
of a measured height.

Any fix is scored on hardware, because no test draws this window: the offer opening by itself on a
migrated install, the checklist screen (taller than the offer), and "Set Up…" from the panel. This
was the unmeasured half of the plan's Task 12, and H35 and H41 were never scored.

Until it is fixed, a pending offer makes the menu unusable, and each crash also leaks a watch slot
in the daemon: `dead-watchers-hold-slots-while-idle`.
