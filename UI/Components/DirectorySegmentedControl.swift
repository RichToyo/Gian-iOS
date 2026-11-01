import SwiftUI
import GianCore

/// Tasks/Repos segmented control with a glass container and sliding selection.
/// Bound to the contract `DirectoryView`; selection dispatches
/// `.selectDirectoryView`.
struct DirectorySegmentedControl: View {
    @Binding var selection: DirectoryView
    @Namespace private var glassNamespace

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 0) {
                segmentButton(.tasks, title: "Tasks")
                segmentButton(.repos, title: "Repos")
            }
            .padding(3)
        }
        .gianGlassSurface(in: Capsule())
        .padding(.horizontal, GianTheme.Metrics.paddingLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Directory views")
    }

    private func segmentButton(_ segment: DirectoryView, title: String) -> some View {
        Button {
            withAnimation(.spring(duration: 0.25)) {
                selection = segment
            }
        } label: {
            Text(title)
                .font(GianTheme.Typography.body.weight(selection == segment ? .semibold : .regular))
                .foregroundStyle(
                    selection == segment
                        ? GianTheme.Colors.label
                        : GianTheme.Colors.secondaryLabel
                )
                .frame(maxWidth: .infinity)
                .frame(minHeight: GianTheme.Metrics.minHitTarget)
                .contentShape(Rectangle())
                .background {
                    if selection == segment {
                        Capsule()
                            .fill(GianTheme.Colors.card)
                            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                            .glassEffectID(segment.rawValue, in: glassNamespace)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == segment ? .isSelected : [])
    }
}

#Preview("Segmented") {
    VStack(spacing: 20) {
        DirectorySegmentedControl(selection: .constant(.tasks))
        DirectorySegmentedControl(selection: .constant(.repos))
    }
    .padding(.vertical)
}
