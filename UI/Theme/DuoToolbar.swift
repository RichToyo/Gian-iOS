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
    /// The expanded layouts (landscape split and portrait) put screen titles on
    /// the leading edge; elsewhere they are centered.
    @Entry var titlesLeading = false
}

/// A screen's title: centered, or on the leading edge in the expanded layouts
/// (`titlesLeading`), where it reads as a title rather than a button.
struct ScreenTitleItem<Content: View>: ToolbarContent {
    var leading: Bool
    @ViewBuilder var content: () -> Content

    var body: some ToolbarContent {
        if leading {
            ToolbarItem(placement: .topBarLeading) {
                // The bar proposes leading items little width: take the
                // title's own, up to a cap past which it truncates.
                content()
                    .frame(maxWidth: 280, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .sharedBackgroundVisibility(.hidden)
            // Otherwise the system title takes the center, and the space this
            // one needs.
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 0, height: 0) }
        } else {
            ToolbarItem(placement: .principal) { content() }
        }
    }
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
