import SwiftUI

/// iPhone Duo bar adoption, guarded for the iOS 26 deployment target.
///
/// On iPhone Duo's outer display (and the inner display in landscape) system
/// toolbars become a vertical bar beside the status bar: top placements stack
/// at its top, `.bottomBar` items at its bottom. Items with a symbol and title
/// go vertical automatically; custom views stay horizontal unless they opt in.
/// Elsewhere these modifiers have no visible effect.
extension ToolbarContent {
    /// Lets a compact custom item (e.g. a 28 pt avatar) join the vertical bar.
    @ToolbarContentBuilder
    func verticalPreferredOnDuo() -> some ToolbarContent {
        if #available(iOS 27.1, *) {
            axisBehavior(.verticalPreferred)
        } else {
            self
        }
    }

    /// Keeps a frequent action (e.g. New chat) out of the overflow menu longest.
    @ToolbarContentBuilder
    func highVisibilityPriority() -> some ToolbarContent {
        if #available(iOS 27.0, *) {
            visibilityPriority(.high)
        } else {
            self
        }
    }
}

extension EnvironmentValues {
    /// The global New chat + Settings pair sits at the bottom of the bar
    /// everywhere except the expanded portrait layout, whose bars stay
    /// horizontal (set by `AdaptiveRoot`).
    @Entry var globalActionsAtBottom = true
    /// The full-page expanded portrait directory puts list controls on the left.
    @Entry var directoryActionsLeading = false
}

/// New chat and Settings are global, so every screen's bar carries them as one
/// group: pinned to the bottom of iPhone Duo's vertical bar (`.bottomBar`), or
/// beside the other trailing items in the expanded portrait layout. Not
/// `.topBarPinnedTrailing`: the pinned slot shows a single item and dropped
/// Settings.
struct GlobalToolbarActions: ToolbarContent {
    /// New chat itself omits the button; it is already the current screen.
    var showsNewChat: Bool = true
    /// From `globalActionsAtBottom`.
    var atBottom: Bool = true
    var onNewChat: () -> Void
    var onSettings: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: atBottom ? .bottomBar : .topBarTrailing) {
            if showsNewChat {
                Button("New chat", systemImage: "square.and.pencil", action: onNewChat)
                    .accessibilityLabel("Start a new chat")
            }
            Button("Settings", systemImage: "gearshape", action: onSettings)
        }
        .highVisibilityPriority()
    }
}
