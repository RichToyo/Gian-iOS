import SwiftUI
import GianCore

/// The current Host as a title: a green (online) or red (offline) dot and the
/// name on one line, with a chevron when it opens the Hosts menu.
struct HostTitleLabel: View {
    let name: String
    /// Nil when there is no Host to report on.
    var isReachable: Bool?
    var showsChevron = true
    var isSubtitle = false

    var body: some View {
        HStack(spacing: isSubtitle ? 4 : 6) {
            if let isReachable {
                Circle()
                    .fill(isReachable ? GianTheme.Colors.success : GianTheme.Colors.failure)
                    .frame(width: isSubtitle ? 6 : 8, height: isSubtitle ? 6 : 8)
            }
            Text(name)
                .font(isSubtitle ? GianTheme.Typography.navSubtitle : GianTheme.Typography.navTitle)
                .foregroundStyle(isSubtitle ? GianTheme.Colors.secondaryLabel : GianTheme.Colors.label)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isReachable.map { "\(name), \($0 ? "Online" : "Offline")" } ?? name)
    }
}

/// The current Host, centered in the bar on every screen that lists
/// conversations; tap it to switch Hosts or add one.
struct CurrentHostMenu: View {
    let hosts: [HostItem]
    var onSelect: (HostID) -> Void
    var onAddHost: () -> Void
    var onManage: () -> Void

    var body: some View {
        let current = hosts.first(where: \.isCurrent)
        Menu {
            HostTitleMenu(hosts: hosts, onSelect: onSelect, onAddHost: onAddHost, onManage: onManage)
        } label: {
            HostTitleLabel(name: current?.name ?? "Conversations", isReachable: current?.isReachable)
        }
        .accessibilityHint("Switch or add Hosts")
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
                HostTitleLabel(name: host.name, isReachable: host.isReachable, showsChevron: false, isSubtitle: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The Hosts menu: every paired Host with its status (selection dispatches
/// `.selectHost`; unreachable ones are listed but disabled), Add Host, and
/// Settings.
struct HostTitleMenu: View {
    let hosts: [HostItem]
    var onSelect: (HostID) -> Void
    var onAddHost: () -> Void
    var onManage: () -> Void

    var body: some View {
        Section("Hosts") {
            ForEach(hosts) { host in
                Button {
                    onSelect(host.id)
                } label: {
                    Label(host.name, systemImage: host.isCurrent ? "checkmark" : "laptopcomputer")
                    Text(host.isReachable ? "Online" : "Offline")
                }
                .disabled(!host.isReachable && !host.isCurrent)
            }
        }
        Section {
            Button("Add Host", systemImage: "plus", action: onAddHost)
            Button("Manage in Settings", systemImage: "gearshape", action: onManage)
        }
    }
}

/// List options as one toolbar menu: grouping (Tasks / Repositories) and an
/// explicit Refresh next to pull-to-refresh. The symbol shows the grouping.
struct DirectoryListMenu: View {
    @Binding var selection: DirectoryView
    var onRefresh: () -> Void

    var body: some View {
        Menu {
            Picker("Group by", selection: $selection) {
                Label("Tasks", systemImage: "checklist").tag(DirectoryView.tasks)
                Label("Repositories", systemImage: "folder").tag(DirectoryView.repos)
            }
            Section {
                Button("Refresh", systemImage: "arrow.clockwise", action: onRefresh)
            }
        } label: {
            Label("List options", systemImage: selection == .tasks ? "checklist" : "folder")
        }
        .accessibilityLabel("Directory views")
    }
}
