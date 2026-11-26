import SwiftUI

/// Why the last tap did nothing ("Choose an Agent first."): a small capsule
/// under the top edge that leaves on its own; tap or swipe up to dismiss.
struct ActionNoticeHost: View {
    var notice: AppPresentation.ActionNotice?
    var onDismiss: (UUID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let lifetime: Duration = .seconds(4)

    var body: some View {
        VStack(spacing: 0) {
            if let notice {
                Label {
                    Text(notice.message)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                }
                .font(GianTheme.Typography.caption)
                .foregroundStyle(GianTheme.Colors.label)
                .padding(.horizontal, GianTheme.Metrics.paddingMedium)
                .padding(.vertical, GianTheme.Metrics.paddingSmall + 2)
                .background(Capsule().fill(GianTheme.Colors.card).shadow(color: .black.opacity(0.14), radius: 12, y: 4))
                .overlay(Capsule().stroke(GianTheme.Colors.separator, lineWidth: 0.5))
                .contentShape(Capsule())
                .onTapGesture { onDismiss(notice.id) }
                .gesture(DragGesture(minimumDistance: 6).onEnded { value in
                    if value.translation.height < -12 { onDismiss(notice.id) }
                })
                .task(id: notice.id) {
                    do { try await Task.sleep(for: Self.lifetime) } catch { return }
                    onDismiss(notice.id)
                }
                .onAppear { AccessibilityNotification.Announcement(notice.message).post() }
                .accessibilityAddTraits(.isStaticText)
                .accessibilityIdentifier("action-notice")
                .id(notice.id)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: GianTheme.Metrics.readableWidth)
        .padding(.horizontal, GianTheme.Metrics.paddingMedium)
        .padding(.top, GianTheme.Metrics.paddingSmall)
        .animation(.spring(duration: 0.35), value: notice?.id)
    }
}
