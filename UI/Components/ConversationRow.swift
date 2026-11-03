import SwiftUI
import GianCore

/// Directory row: Agent icon, user-language title with last activity, a
/// subtitle (repository, or the Agent where the group already names the
/// repository) and the state pill. Selection dispatches upward.
struct ConversationRow: View {
    let item: ConversationRowItem
    var isSelected: Bool = false
    /// False inside repository groups, where the header already names it.
    var showsRepo: Bool = true
    var onSelect: () -> Void

    private var subtitle: String? {
        showsRepo ? (item.repoName ?? item.agentName) : item.agentName
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: GianTheme.Metrics.paddingMedium) {
                AgentAvatar(
                    logo: item.agent,
                    name: item.agentName,
                    size: GianTheme.Metrics.avatarMedium
                )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: GianTheme.Metrics.paddingSmall) {
                        Text(item.title)
                            .font(GianTheme.Typography.title)
                            .foregroundStyle(GianTheme.Colors.label)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let lastActivity = item.lastActivity {
                            Text(RowTimestamp.text(for: lastActivity))
                                .font(.footnote)
                                .foregroundStyle(GianTheme.Colors.secondaryLabel)
                                .monospacedDigit()
                        }
                    }
                    HStack(spacing: GianTheme.Metrics.paddingSmall) {
                        if let subtitle {
                            Text(subtitle)
                                .font(GianTheme.Typography.caption)
                                .foregroundStyle(GianTheme.Colors.secondaryLabel)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        StatusPill(badge: item.badge)
                    }
                }
            }
            .padding(.horizontal, GianTheme.Metrics.paddingMedium)
            .padding(.vertical, 10)
            .frame(minHeight: GianTheme.Metrics.minHitTarget)
            .background(
                isSelected ? GianTheme.Colors.tint.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: GianTheme.Metrics.cornerRadiusMedium, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, GianTheme.Metrics.paddingSmall)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Messages-style row time: clock time today, weekday this week, else date.
enum RowTimestamp {
    static func text(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7, days >= 0 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(date: .numeric, time: .omitted)
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
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GianTheme.Colors.label)
                    .lineLimit(1)
                Text(count, format: .number)
                    .font(.subheadline)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .padding(.horizontal, GianTheme.Metrics.paddingLarge)
            .padding(.top, GianTheme.Metrics.paddingSmall)
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
