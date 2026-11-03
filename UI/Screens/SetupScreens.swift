import SwiftUI
import GianCore

/// Phase-driven setup bound to `GianClientState.phase`, two steps: the
/// Remote Server (its identity is verified and pinned on first use; there is
/// no account sign-in), then Host pairing (QR scan or pairing link; QR pairs
/// Hosts only, and the Host confirms the device).
struct SetupFlowView: View {
    let phase: ClientPhase
    let account: AccountAuthorization
    let server: ServerAddress?
    let pendingPairing: PendingHostPairing?
    /// Why the last pairing attempt failed, if it did.
    var pairingNotice: String? = nil

    var onSubmitServer: (String) -> Void = { _ in }
    /// Trusts a Server whose identity changed (e.g. it was reinstalled).
    var onTrustNewServerIdentity: () -> Void = {}
    var onPairPayload: (String) -> Void = { _ in }
    var onRefreshPairing: () -> Void = {}
    /// Leaves pairing for the Server step, so this step is never a dead end.
    var onStartOver: () -> Void = {}

    @State private var serverAddress = ""
    @State private var confirmsTrust = false

    var body: some View {
        // A plain stack, not a ScrollView: inside a scroll view that re-centers
        // as the keyboard resizes it, the first tap on Continue was swallowed.
        VStack(spacing: GianTheme.Metrics.paddingLarge * 1.5) {
            Spacer(minLength: 0)
            brandHeader
            stepContent
            Spacer(minLength: 0)
        }
        .frame(maxWidth: GianTheme.Metrics.formWidth)
        .padding(GianTheme.Metrics.paddingLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GianTheme.Colors.background)
        .onAppear { serverAddress = server?.absoluteString ?? serverAddress }
        .onChange(of: server) { _, value in
            if let value { serverAddress = value.absoluteString }
        }
    }

    private var brandHeader: some View {
        VStack(spacing: GianTheme.Metrics.paddingSmall) {
            Image("brand-icon")
                .resizable()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text("Gian")
                .font(.title2.weight(.bold))
                .foregroundStyle(GianTheme.Colors.label)
            if let step {
                Text("Step \(step) of 2")
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var step: Int? {
        switch phase {
        case .signedOut, .serverEntered: 1
        case .awaitingHostPairing: 2
        case .ready: nil
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch phase {
        case .signedOut, .serverEntered:
            serverStep
        case .awaitingHostPairing:
            pairingStep
        case .ready:
            EmptyView()
        }
    }

    // MARK: - Server

    private var isConnecting: Bool { account.status == .pending }

    private var canSubmit: Bool {
        !isConnecting && !serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var serverStep: some View {
        VStack(spacing: GianTheme.Metrics.paddingMedium) {
            Text("Connect to your Gian server")
                .font(GianTheme.Typography.title)
                .foregroundStyle(GianTheme.Colors.label)

            TextField("https://server.example.com", text: $serverAddress)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.continue)
                .onSubmit { if canSubmit { onSubmitServer(serverAddress) } }
                .disabled(isConnecting)
                .font(GianTheme.Typography.body)
                .padding(GianTheme.Metrics.paddingMedium)
                .background(
                    GianTheme.Colors.card,
                    in: RoundedRectangle(
                        cornerRadius: GianTheme.Metrics.cornerRadiusMedium,
                        style: .continuous
                    )
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: GianTheme.Metrics.cornerRadiusMedium,
                        style: .continuous
                    )
                    .stroke(GianTheme.Colors.separator, lineWidth: 0.5)
                )

            connectionStatus

            Button("Continue") { onSubmitServer(serverAddress) }
                .buttonStyle(GianPrimaryButtonStyle())
                .disabled(!canSubmit)
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch account.status {
        case .pending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking the server…")
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
            }
        case .error:
            statusMessage("Couldn't connect. \(account.failure ?? "Check the server address and try again.")",
                          color: GianTheme.Colors.failure)
        case .serverIdentityChanged:
            VStack(spacing: GianTheme.Metrics.paddingSmall) {
                statusMessage("This server's identity changed since this device last connected. Only continue if you reinstalled or reset the server.",
                              color: GianTheme.Colors.warning)
                Button("Trust new identity", role: .destructive) { confirmsTrust = true }
                    .font(GianTheme.Typography.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .frame(minHeight: GianTheme.Metrics.minHitTarget)
                    .confirmationDialog("Trust this server's new identity?", isPresented: $confirmsTrust, titleVisibility: .visible) {
                        Button("Trust new identity", role: .destructive, action: onTrustNewServerIdentity)
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Hosts paired with this server on this device must be paired again.")
                    }
            }
        case .signedOut, .signedIn:
            EmptyView()
        }
    }

    private func statusMessage(_ text: String, color: Color) -> some View {
        Text(text)
            .font(GianTheme.Typography.caption)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
    }

    // MARK: - Host pairing

    private var pairingStep: some View {
        VStack(spacing: GianTheme.Metrics.paddingMedium) {
            Text("Pair a Host")
                .font(GianTheme.Typography.title)
                .foregroundStyle(GianTheme.Colors.label)

            HostPairingPanel(
                isWaiting: pendingPairing != nil,
                notice: pairingNotice,
                onPairPayload: onPairPayload,
                onRefreshPairing: onRefreshPairing
            )

            Button("Use a different server", action: onStartOver)
                .font(GianTheme.Typography.caption)
                .foregroundStyle(GianTheme.Colors.secondaryLabel)
                .buttonStyle(.plain)
                .frame(minHeight: GianTheme.Metrics.minHitTarget)
        }
    }
}

/// Pairing entry (QR or link), or once claimed, the wait for the Host to
/// confirm this device. Shared by setup and Add Host.
struct HostPairingPanel: View {
    let isWaiting: Bool
    var notice: String? = nil
    var onPairPayload: (String) -> Void
    var onRefreshPairing: () -> Void

    var body: some View {
        VStack(spacing: GianTheme.Metrics.paddingMedium) {
            if isWaiting {
                VStack(spacing: GianTheme.Metrics.paddingSmall) {
                    ProgressView()
                    Text("Confirm this device on your Host.")
                        .font(GianTheme.Typography.caption)
                        .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    Button("Check confirmation", action: onRefreshPairing)
                        .buttonStyle(GianSecondaryButtonStyle())
                }
                // The Host confirms out of band; check periodically so the app
                // moves on by itself. The button stays as a manual check.
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled else { return }
                        onRefreshPairing()
                    }
                }
            } else {
                Text("Scan the QR code shown by the Host, or paste the pairing link. QR codes pair Hosts only.")
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    .multilineTextAlignment(.center)
                if let notice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(GianTheme.Typography.caption)
                        .foregroundStyle(GianTheme.Colors.failure)
                        .multilineTextAlignment(.center)
                }
                QRPairingEntry(onPayload: onPairPayload)
            }
        }
    }
}

/// QR scan (VisionKit data scanner) plus a manual pairing-link fallback.
/// Both produce the raw payload string dispatched to
/// `.beginHostPairingFromQR`; the core validates and rejects mismatches.
struct QRPairingEntry: View {
    var onPayload: (String) -> Void

    @State private var manualPayload = ""
    @State private var scannerPresented = false

    var body: some View {
        VStack(spacing: GianTheme.Metrics.paddingMedium) {
            Button {
                scannerPresented = true
            } label: {
                Label("Scan QR code", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GianPrimaryButtonStyle())
            .sheet(isPresented: $scannerPresented) {
                QRScannerSheet { payload in
                    scannerPresented = false
                    onPayload(payload)
                } onCancel: {
                    scannerPresented = false
                }
            }

            HStack(spacing: GianTheme.Metrics.paddingSmall) {
                TextField("Paste pairing link", text: $manualPayload)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(GianTheme.Typography.caption)
                    .padding(GianTheme.Metrics.paddingSmall)
                    .background(
                        GianTheme.Colors.card,
                        in: RoundedRectangle(
                            cornerRadius: GianTheme.Metrics.cornerRadiusSmall,
                            style: .continuous
                        )
                    )
                    .overlay(
                        RoundedRectangle(
                            cornerRadius: GianTheme.Metrics.cornerRadiusSmall,
                            style: .continuous
                        )
                        .stroke(GianTheme.Colors.separator, lineWidth: 0.5)
                    )
                Button("Pair") {
                    onPayload(manualPayload)
                }
                .buttonStyle(GianSecondaryButtonStyle())
                .disabled(manualPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .frame(width: 88)
            }
        }
    }
}

#Preview("Setup · server") {
    SetupFlowView(
        phase: .signedOut,
        account: .signedOut,
        server: nil,
        pendingPairing: nil
    )
}

#Preview("Setup · identity changed") {
    SetupFlowView(
        phase: .serverEntered,
        account: AccountAuthorization(status: .serverIdentityChanged),
        server: ServerAddress(parsing: "https://remote.example.test"),
        pendingPairing: nil
    )
}
