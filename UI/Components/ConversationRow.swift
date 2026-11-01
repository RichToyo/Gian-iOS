import SwiftUI
import GianCore

/// Directory row: Agent icon, user-language title, optional repo subtitle,
/// state badge on the trailing edge. Selection dispatches upward.
struct ConversationRow: View {
    let item: ConversationRowItem
    var isSelected: Bool = false
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: GianTheme.Metrics.paddingMedium) {
                AgentAvatar(
                    logo: item.agent,
                    name: item.agentName,
                    size: GianTheme.Metrics.avatarMedium
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(GianTheme.Typography.title)
                        .foregroundStyle(GianTheme.Colors.label)
                        .lineLimit(1)
                    if let repo = item.repoName {
                        Text(repo)
                            .font(GianTheme.Typography.caption)
                            .foregroundStyle(GianTheme.Colors.secondaryLabel)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: GianTheme.Metrics.paddingSmall)
                StatusPill(badge: item.badge)
            }
            .padding(.horizontal, GianTheme.Metrics.paddingLarge)
            .padding(.vertical, GianTheme.Metrics.paddingSmall)
            .frame(minHeight: GianTheme.Metrics.minHitTarget)
            .background(isSelected ? GianTheme.Colors.tint.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Collapsible group header, e.g. "Auth Reliability Sprint  2".
struct DirectoryGroupHeader: View {
    let title: String
    let count: Int
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(GianTheme.Typography.caption.weight(.semibold))
                Text(count, format: .number)
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                Spacer()
            }
            .foregroundStyle(GianTheme.Colors.secondaryLabel)
            .padding(.horizontal, GianTheme.Metrics.paddingLarge)
            .frame(minHeight: GianTheme.Metrics.minHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) conversations")
        .accessibilityHint(isExpanded ? "Collapse group" : "Expand group")
    }
}

#Preview("Conversation rows") {
    VStack(spacing: 0) {
        DirectoryGroupHeader(title: "Auth Reliability Sprint", count: 2, isExpanded: .constant(true))
        ConversationRow(
            item: ConversationRowItem(
                id: SessionID(rawValue: "c1")!, title: "Fix login redirect",
                agent: .claude, agentName: "Claude", repoName: "gian-dev",
                badge: .working, lastActivity: .now
            ),
            onSelect: {}
        )
        ConversationRow(
            item: ConversationRowItem(
                id: SessionID(rawValue: "c2")!, title: "iOS client design board",
                agent: .kimi, agentName: "Kimi", repoName: "design",
                badge: .waiting, lastActivity: .now
            ),
            isSelected: true,
            onSelect: {}
        )
        ConversationRow(
            item: ConversationRowItem(
                id: SessionID(rawValue: "c3")!, title: "Release check script",
                agent: .codex, agentName: "Codex", repoName: "infra",
                badge: .failed, lastActivity: .now
            ),
            onSelect: {}
        )
    }
}
