import SwiftUI
import GianCore

/// An in-app notification about another conversation, as Gian's attention
/// events: a turn completed, the Agent waits on the user, a turn failed. Tap
/// opens the conversation (`.openBanner`, which keeps drafts and scroll); a
/// swipe up dismisses it (`.dismissBanner`, staying in place); untouched, it
/// leaves on its own after a few seconds.
struct TransientBanner: View {
    let banner: BannerPresentation
    var onTap: () -> Void
    var onDismiss: () -> Void

    /// How long an untouched banner stays.
    static let lifetime: Duration = .seconds(5)

    @State private var drag: CGFloat = 0
    @State private var isHeld = false

    var body: some View {
        HStack(spacing: GianTheme.Metrics.paddingMedium) {
            AgentAvatar(logo: banner.agent, name: banner.title, size: GianTheme.Metrics.avatarMedium)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(GianTheme.Typography.title)
                    .foregroundStyle(GianTheme.Colors.label)
                    .lineLimit(1)
                Text(banner.summary)
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // The list's status glyph for the same state.
            if let status = statusIcon { status }
        }
        .padding(.horizontal, GianTheme.Metrics.paddingMedium)
        .padding(.vertical, GianTheme.Metrics.paddingSmall + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GianTheme.Metrics.cornerRadiusLarge, style: .continuous)
                .fill(GianTheme.Colors.card)
                .shadow(color: .black.opacity(0.14), radius: 14, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GianTheme.Metrics.cornerRadiusLarge, style: .continuous)
                .stroke(GianTheme.Colors.separator, lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: GianTheme.Metrics.cornerRadiusLarge, style: .continuous))
        // Follows a finger up; resists one pulling down.
        .offset(y: drag < 0 ? drag : drag / 4)
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { value in
                    isHeld = true
                    drag = value.translation.height
                }
                .onEnded { value in
                    isHeld = false
                    if value.translation.height < -24 || value.predictedEndTranslation.height < -80 {
                        onDismiss()
                    } else {
                        withAnimation(.spring(duration: 0.3)) { drag = 0 }
                    }
                }
        )
        .onTapGesture(perform: onTap)
        .task(id: banner.id) {
            do { try await Task.sleep(for: Self.lifetime) } catch { return }
            // Not while a finger holds it.
            while isHeld {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
            onDismiss()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("transient-banner")
        .accessibilityHint("Opens the conversation")
        .accessibilityAction(named: "Dismiss", onDismiss)
    }

    private var statusIcon: SessionStatusIcon? {
        switch banner.kind {
        case .completed: SessionStatusIcon(badge: .idle, unread: true)
        case .waiting: SessionStatusIcon(badge: .waiting, unread: true)
        case .failed: SessionStatusIcon(badge: .failed, unread: true)
        }
    }
}

/// The in-app notification, shown over every screen (one at a time; the
/// next queued one follows when it leaves).
struct BannerHost: View {
    var banner: BannerPresentation?
    var onTap: (BannerID) -> Void
    var onDismiss: (BannerID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if let banner {
                TransientBanner(banner: banner, onTap: { onTap(banner.id) }, onDismiss: { onDismiss(banner.id) })
                    .id(banner.id)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: GianTheme.Metrics.readableWidth)
        .padding(.horizontal, GianTheme.Metrics.paddingMedium)
        .padding(.top, GianTheme.Metrics.paddingSmall)
        .animation(.spring(duration: 0.35), value: banner?.id)
    }
}

/// The chat title's status. `AppPresentation` only passes one that has lasted
/// a moment; when it clears, the title simply fades it out.
struct ConversationStatusView: View {
    let status: ConversationStatusPresentation
    var onRetryConnection: () -> Void
    var onRetryMessages: () -> Void
    @State private var showsDetails = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { showsDetails = true } label: {
            Label {
                Text(status.label)
            } icon: {
                // Reconnecting and syncing spin until they finish.
                Image(systemName: status.symbol)
                    .symbolEffect(.rotate, options: .repeat(.continuous), isActive: status.isActivity && !reduceMotion)
            }
            .font(GianTheme.Typography.caption)
            .foregroundStyle(status.isError ? GianTheme.Colors.failure : GianTheme.Colors.secondaryLabel)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .contentTransition(.opacity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connection status: \(status.label)")
        .accessibilityHint("Shows status details")
        .popover(isPresented: $showsDetails) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(status.details.enumerated()), id: \.offset) { _, detail in
                    Text(detail).font(GianTheme.Typography.caption)
                }
                if status.retryConnection {
                    Button("Retry connection") { showsDetails = false; onRetryConnection() }
                }
                if status.retryMessages {
                    Button("Retry messages") { showsDetails = false; onRetryMessages() }
                }
            }
            .padding(16)
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 300, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// The chat title's status: the current state, or for a moment after a sync
/// finishes, a "Synced" mark that fades away. Nothing otherwise.
struct ConversationTitleStatus: View {
    let status: ConversationStatusPresentation?
    var onRetryConnection: () -> Void
    var onRetryMessages: () -> Void
    @State private var showsSynced = false

    var body: some View {
        // A ZStack, not a Group: it stays in place (so the change handlers run)
        // even while it shows nothing.
        ZStack {
            if let status {
                ConversationStatusView(status: status, onRetryConnection: onRetryConnection,
                                       onRetryMessages: onRetryMessages)
                    .padding(.leading, 6)
                    .transition(.opacity)
            } else if showsSynced {
                Label {
                    Text("Synced").foregroundStyle(GianTheme.Colors.secondaryLabel)
                } icon: {
                    Image(systemName: "checkmark.circle").foregroundStyle(GianTheme.Colors.success)
                }
                    .font(GianTheme.Typography.caption)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.leading, 6)
                    .transition(.opacity)
                    .accessibilityLabel("Messages are up to date")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: status)
        .animation(.easeInOut(duration: 0.3), value: showsSynced)
        .onChange(of: status) { old, new in
            // Only a sync that just finished earns the mark.
            showsSynced = new == nil && old?.isActivity == true
        }
        .task(id: showsSynced) {
            guard showsSynced else { return }
            try? await Task.sleep(for: .seconds(1.5))
            showsSynced = false
        }
    }
}

/// Sanitized transient diagnostic from the service (closed connection,
/// resync). Never raw error text, URLs or payloads.
struct DiagnosticBar: View {
    let diagnostic: DiagnosticPresentation
    var onRetrySynchronization: (() -> Void)? = nil

    var body: some View {
        switch diagnostic {
        case .none:
            EmptyView()
        case .connectionClosed(let message):
            row(icon: "wifi.exclamationmark", text: message, color: GianTheme.Colors.warning)
        case .resyncRequired(let reason):
            HStack(spacing: GianTheme.Metrics.paddingSmall) {
                Label("Sync required", systemImage: "arrow.triangle.2.circlepath")
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.warning)
                    .accessibilityHint("Reason: \(reason)")
                if let onRetrySynchronization {
                    Button("Retry", action: onRetrySynchronization)
                        .font(GianTheme.Typography.caption.weight(.semibold))
                        .gianHitTarget()
                }
            }
            .frame(maxWidth: .infinity)
            .background(GianTheme.Colors.card)
        }
    }

    private func row(icon: String, text: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(GianTheme.Typography.caption)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(GianTheme.Colors.card)
            .accessibilityElement(children: .combine)
    }
}

#Preview("Banner") {
    VStack(spacing: 24) {
        BannerHost(
            banner: BannerPresentation(
                id: BannerID(rawValue: "b1")!,
                sessionID: SessionID(rawValue: "c9")!,
                agent: .kimi,
                title: "iOS client design board",
                kind: .completed,
                summary: "Turn complete"
            ),
            onTap: { _ in }, onDismiss: { _ in }
        )
        ConversationStatusView(status: .make(connectivity: .offlineHistory, diagnostic: .none, transcriptSync: .idle)!,
                               onRetryConnection: {}, onRetryMessages: {})
    }
    .padding()
}
