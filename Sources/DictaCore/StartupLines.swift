import Foundation

// What the daemon's log says about the person's choice at start-up (D31 as amended on 2026-09-13).
//
// A value rather than a handful of `log` calls in `main.swift`, because these lines are what a
// person reads to find out why a hold in another application did nothing: whether the scope came
// from `setup.json` or was decided by the migration, whether the LaunchAgent's `--focused-fields`
// was ignored, and whether the daemon is waiting for a choice nobody has made. H37 scores the
// sentences on a real upgrade; the decisions behind them are held here.

/// The start-up log lines that describe the choice in force.
public enum StartupLines {
    /// One line per fact, in the order they matter: where the scope came from, what went wrong
    /// with the file, whether the flag was ignored, and whether the daemon is waiting for setup.
    /// `agtermFound` decides only the last: undecided with agterm still dictates into agterm.
    public static func describe(_ bootstrap: SetupBootstrap, agtermFound: Bool) -> [String] {
        let scope = bootstrap.state.scope.rawValue
        var lines: [String] = []
        switch bootstrap.source {
        case .file:
            lines.append("setup: \(scope), from setup.json")
        case let .migrated(flag, record):
            let origin = if flag {
                "seeded from --focused-fields"
            } else {
                switch record {
                case let .lines(count) where count > 0:
                    "migrated: the record holds \(count) "
                        + (count == 1 ? "entry" : "entries") + ", so this is an update"
                case .lines:
                    "migrated: the record holds nothing, so this is a fresh install"
                case .unreadable:
                    "migrated: the record could not be read, so this is taken as an update"
                }
            }
            let written = bootstrap.saveError == nil
                ? "written to setup.json"
                : "in force for this run only"
            lines.append("setup: \(scope), \(origin); \(written)")
        case let .unreadable(problem):
            lines.append("setup problem: \(problem); dicta behaves as \(scope) and keeps the file "
                         + "as it is until a choice replaces it")
        }
        if let saveError = bootstrap.saveError {
            lines.append("setup problem: \(saveError)")
        }
        if bootstrap.flagIgnored {
            lines.append("setup: --focused-fields was ignored, because setup.json exists and "
                         + "decides")
        }
        if bootstrap.state.scope == .undecided {
            lines.append(agtermFound
                ? "setup: waiting for setup -- agterm dictation works as before, and other "
                    + "applications stay closed until a choice is made"
                : "not configured: waiting for setup -- nothing can be dictated until a choice is "
                    + "made in the menu bar's Set Up… or with dictactl configure")
        }
        return lines
    }
}
