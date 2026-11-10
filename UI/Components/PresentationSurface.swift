import SwiftUI

/// Builds its content in its own body, so the observed presentation values the
/// content reads re-render this surface alone, not the view that contains it.
struct PresentationSurface<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}
