import SwiftUI
import GianCore

/// Settings bound to the contract: Done, Server (address; "Change server…"
/// asks for the new address with Cancel first and only then signs out; a
/// confirmed Sign out via `.logout`), paired Hosts list with Add Host, Appearance (UI-local preference), and the evictable
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

    let serverAddress: String
    let hosts: [HostItem]
    /// Honest disclosures from the store (sanitized; never raw data).
    var storageError: String? = nil
    var serverOutcomeUnconfirmed: Bool = false
    var invalidationUnconfirmed: Bool = false

    @Binding var appearance: Appearance

    var onBack: () -> Void = {}
    var onSignOut: () -> Void = {}
    /// Called only after the new address is confirmed; signs out of this server.
    var onChangeServer: (String) -> Void = { _ in }
    var onEvictAttachmentCache: () -> Void = {}
    var addHost = AddHostPresentation()

    @State private var confirmsSignOut = false
    @State private var changesServer = false
    @State private var addsHost = false

    var body: some View {
        List {
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
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onBack)
            }
        }
        .addHostSheet(isPresented: $addsHost, pairing: addHost)
    }

    private var serverSection: some View {
        Section("Server") {
            LabeledContent("Address", value: serverAddress)
            Button("Change server…") { changesServer = true }
                .accessibilityHint("Asks for the new address; nothing changes until you confirm")
                .sheet(isPresented: $changesServer) {
                    ChangeServerSheet(current: serverAddress) { address in
                        changesServer = false
                        onChangeServer(address)
                    }
                }
            Button("Sign out", role: .destructive) { confirmsSignOut = true }
                .accessibilityHint("Forgets this server and its Hosts on this device")
                .confirmationDialog("Sign out of \(serverAddress)?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
                    Button("Sign out", role: .destructive, action: onSignOut)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This device forgets this server and its Hosts. You'll pair a Host again to reconnect.")
                }
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
            Button("Add Host", systemImage: "plus") { addsHost = true }
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
            Button("Clear cached attachments", action: onEvictAttachmentCache)
                .accessibilityHint("Re-downloads attachments when needed; drafts and history are kept")
        }
    }
}

/// New server address with Cancel. Switching signs out of the current server,
/// so nothing happens until the user confirms a different address.
private struct ChangeServerSheet: View {
    let current: String
    var onSwitch: (String) -> Void

    @State private var address = ""
    @Environment(\.dismiss) private var dismiss

    private var trimmed: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://server.example.com", text: $address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Switching signs this device out of \(current). You'll pair a Host on the new server.")
                }
            }
            .navigationTitle("Change Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Switch") { onSwitch(trimmed) }
                        .disabled(trimmed.isEmpty || trimmed == current)
                }
            }
        }
        .onAppear { address = current }
    }
}
