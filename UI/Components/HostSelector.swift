import SwiftUI
import GianCore

/// The current Host as a title: a green (online) or red (offline) dot and the
/// name on one line, with a chevron when it opens the Hosts menu.
struct HostTitleLabel: View {
    let name: String
    /// Nil when there is no Host to report on.
    var status: HostStatus?
    var showsChevron = true
    var isSubtitle = false

    var body: some View {
        HStack(spacing: isSubtitle ? 4 : 6) {
            if let status {
                HostStatusDot(status: status, size: isSubtitle ? 6 : 8)
            }
            Text(name)
                .font(isSubtitle ? GianTheme.Typography.navSubtitle : GianTheme.Typography.navTitle)
                .foregroundStyle(isSubtitle ? GianTheme.Colors.secondaryLabel : GianTheme.Colors.label)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.map { "\(name), \($0.label)" } ?? name)
    }
}

/// Green online, pulsing amber while connecting, red when the current Host
/// can't be reached, gray when there is no connection to report on.
struct HostStatusDot: View {
    let status: HostStatus
    var size: CGFloat = 8
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(status == .connecting && dimmed ? 0.35 : 1)
            .animation(status == .connecting ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: dimmed)
            .onAppear { dimmed = status == .connecting }
            .onChange(of: status) { _, value in dimmed = value == .connecting }
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch status {
        case .online: GianTheme.Colors.success
        case .connecting: GianTheme.Colors.warning
        case .offline: GianTheme.Colors.failure
        case .notConnected: GianTheme.Colors.secondaryLabel
        }
    }
}

/// The current Host, centered in the bar on every screen that lists
/// conversations; tap it to switch Hosts or add one.
struct CurrentHostMenu: View {
    let hosts: [HostItem]
    var onSelect: (HostID) -> Void
    var onAddHost: () -> Void
    var onManage: () -> Void

    @State private var showsHosts = false

    var body: some View {
        let current = hosts.first(where: \.isCurrent)
        Button { showsHosts = true } label: {
            HostTitleLabel(name: current?.name ?? "Conversations", status: current?.status)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Switch or add Hosts")
        .popover(isPresented: $showsHosts) {
            HostList(hosts: hosts, onSelect: onSelect, onAddHost: onAddHost, onManage: onManage)
        }
    }
}

/// A screen title centered over the current Host (dot + name), for chats and
/// New chat.
struct HostScopedTitle: View {
    let title: String
    let host: HostItem?
    /// For short fixed titles ("New chat"): opening straight into a screen
    /// with a full Duo vertical bar measured the title too narrow ("New…").
    var keepsWholeTitle = false

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(GianTheme.Typography.navTitle)
                .foregroundStyle(GianTheme.Colors.label)
                .lineLimit(1)
                .fixedSize(horizontal: keepsWholeTitle, vertical: false)
            if let host {
                HostTitleLabel(name: host.name, status: host.status, showsChevron: false, isSubtitle: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The Hosts list: every paired Host with its status and the current one
/// checked at the end. Selection dispatches `.selectHost`, including for an
/// offline Host to retry it, then Add Host and Settings.
struct HostList: View {
    let hosts: [HostItem]
    var onSelect: (HostID) -> Void
    var onAddHost: () -> Void
    var onManage: () -> Void

    var hostRows: [ChoiceListRow] {
        hosts.map { host in
            // The reachability shown can be stale; selecting a paired Host
            // always tries it again, so an offline one stays selectable.
            ChoiceListRow(id: host.id.rawValue, title: host.name, subtitle: host.status.label,
                          systemImage: "laptopcomputer", isSelected: host.isCurrent) { onSelect(host.id) }
        }
    }

    var body: some View {
        ChoiceList(
            header: "Hosts",
            rows: hostRows,
            actions: [
                ChoiceListRow(id: "add", title: "Add Host", systemImage: "plus", action: onAddHost),
                ChoiceListRow(id: "manage", title: "Manage in Settings", systemImage: "gearshape", action: onManage),
            ]
        )
    }
}

/// List options as one toolbar button: grouping (Tasks / Repositories, the
/// current one checked at the end) and an explicit Refresh next to
/// pull-to-refresh. The symbol shows the grouping.
struct DirectoryListMenu: View {
    @Binding var selection: DirectoryView
    var timeFilter: DirectoryTimeFilter
    var onSelectTimeFilter: (DirectoryTimeFilter) -> Void
    var onRefresh: () -> Void

    @State private var showsOptions = false

    var body: some View {
        Button { showsOptions = true } label: {
            Label("List options", systemImage: selection == .tasks ? "checklist" : "folder")
        }
        .accessibilityLabel("List options")
        .popover(isPresented: $showsOptions) {
            ChoiceList(
                header: "Group by",
                rows: [
                    ChoiceListRow(id: "tasks", title: "Tasks", systemImage: "checklist", isSelected: selection == .tasks) { selection = .tasks },
                    ChoiceListRow(id: "repos", title: "Repos", systemImage: "folder", isSelected: selection == .repos) { selection = .repos },
                ],
                additionalHeader: "Time filter",
                additionalRows: [
                    ChoiceListRow(id: "hour", title: "Last hour", isSelected: timeFilter == .lastHour) { onSelectTimeFilter(.lastHour) },
                    ChoiceListRow(id: "day", title: "Last 24 hours", isSelected: timeFilter == .last24Hours) { onSelectTimeFilter(.last24Hours) },
                    ChoiceListRow(id: "week", title: "Last 7 days", isSelected: timeFilter == .last7Days) { onSelectTimeFilter(.last7Days) },
                ],
                actions: [ChoiceListRow(id: "refresh", title: "Refresh", systemImage: "arrow.clockwise", action: onRefresh)]
            )
        }
    }
}
