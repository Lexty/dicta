import DictaMenuKit
import SwiftUI

/// The pairing the app keeps for its lifetime: the view model, and the setup window's presenter
/// attached to it (D27).
///
/// **The presenter is attached before anything can start the model**, in acta's order (retain the
/// panel, assign the presenter, then start). The first snapshot of a launch is the one moment the
/// window may open by itself, and `FirstSnapshotLatch` consumes that moment whether or not a
/// presenter is there, so a presenter attached later would silently lose it. Both starts come after
/// this `init`: the label's `.task`, and `panelAppeared()` on a panel that is built lazily.
///
/// **Ownership, not observation.** An `ObservableObject` does not forward a child's changes, so
/// holding the model here does not redraw anything when it changes. The views that draw it,
/// `MenuBarLabel` and `Panel`, each observe it themselves.
@MainActor
final class MenuRoot: ObservableObject {
    let model: StatusViewModel
    private let setupWindow: SetupWindowController

    init() {
        model = StatusViewModel(world: .system)
        setupWindow = SetupWindowController(model: model)
        model.setupPresenter = setupWindow
    }
}
