import SwiftUI
import GianCore

/// Settings bound to the contract: Back, Account (login + sign out via
/// `.logout`), Server (address; changing signs out and returns to setup),
/// paired Hosts list, Appearance (UI-local preference), and the evictable
/// attachment cache (`.clearAttachmentCache`). There are intentionally no
/// OS-notification entries.
///
/// CONTRACT_NEEDED (parent): no host-revoke action, no offline-history clear
/// action and no cache-size query exist in the contract yet, so those rows are
/// omitted rather than rendered as fake unconnected buttons.
struct SettingsScreen: View {
    enum Appearance: String, CaseIterable, Sendable {
        case system = "System"
        case light = "Light"
        case dark = "Dark"
    }

    let accountLogin: String
    let serverAddress: String
    let hosts: [HostItem]
    /// Honest disclosures from the store (sanitized; never raw data).
    var storageError: String? = nil
    var serverOutcomeUnconfirmed: Bool = false
    var invalidationUnconfirmed: Bool = false

    @Binding var appearance: Appearance

    var onBack: () -> Void = {}
    var onSignOut: () -> Void = {}
    var onChangeServer: () -> Void = {}
    var onEvictAttachmentCache: () -> Void = {}

    var body: some View {
        List {
            accountSection
            serverSection
            hostsSection
            appearanceSection
            storageSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(GianTheme.Colors.background)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                }
            }
        }
    }

    private var accountSection: some View {
        Section("Account") {
            HStack(spacing: GianTheme.Metrics.paddingMedium) {
                UserAvatar(login: accountLogin, size: GianTheme.Metrics.avatarLarge)
                VStack(alignment: .leading, spacing: 2) {
                    Text(accountLogin)
                        .font(GianTheme.Typography.title)
                    Text("Signed in with GitHub")
                        .font(GianTheme.Typography.caption)
                        .foregroundStyle(GianTheme.Colors.secondaryLabel)
                }
            }
            Button("Sign out", role: .destructive, action: onSignOut)
                .accessibilityHint("Hides this account's local data until you sign in again")
        }
    }

    private var serverSection: some View {
        Section("Server") {
            LabeledContent("Address", value: serverAddress)
            Button("Change server…", action: onChangeServer)
                .accessibilityHint("Signs out and returns to server setup")
        }
    }

    private var hostsSection: some View {
        Section("Hosts") {
            ForEach(hosts) { host in
                HStack {
                    Image(systemName: "laptopcomputer")
                        .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    Text(host.name)
                    Spacer()
                    HostReachabilityDot(isReachable: host.isReachable)
                    if host.isCurrent {
                        Text("Current")
                            .font(GianTheme.Typography.badge)
                            .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    }
                }
            }
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $appearance) {
                ForEach(Appearance.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }
        }
    }

    private var storageSection: some View {
        Section("Storage") {
            if let storageError {
                Label("Local storage error: \(storageError). Changes may not be saved.",
                      systemImage: "exclamationmark.triangle")
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.failure)
            }
            if serverOutcomeUnconfirmed {
                Text("The last server sign-out is not confirmed. Local data stays hidden on this device.")
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.warning)
            }
            if invalidationUnconfirmed {
                Text("Durable removal of saved authorization could not be confirmed. Do not treat this device as clean after a restart without signing in again.")
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.warning)
            }
            Button("Evict attachment cache", action: onEvictAttachmentCache)
                .accessibilityHint("Re-downloads attachments when needed; drafts and history are kept")
        }
    }
}
