import SwiftUI
import GianCore

/// Phase-driven setup bound to `GianClientState.phase`, two steps: the
/// Remote Server (address plus a single-use enrollment token from its
/// enrollment page; its identity is verified and pinned on first use; there
/// is no account sign-in), then Host pairing (scan the Host's QR code, or
/// type its one-time code; the Host confirms the device).
struct SetupFlowView: View {
    let phase: ClientPhase
    let account: AccountAuthorization
    let server: ServerAddress?
    let pendingPairing: PendingHostPairing?
    /// Why the last pairing attempt failed, if it did.
    var pairingNotice: String? = nil

    /// Address and enrollment token.
    var onSubmitServer: (String, String) -> Void = { _, _ in }
    /// Trusts a Server whose identity changed (e.g. it was reinstalled), with
    /// the enrollment token for the new controller identity.
    var onTrustNewServerIdentity: (String) -> Void = { _ in }
    var onPairPayload: (String) -> Void = { _ in }
    var onPairCode: (String) -> Void = { _ in }
    var onRefreshPairing: () -> Void = {}
    /// Leaves pairing for the Server step, so this step is never a dead end.
    var onStartOver: () -> Void = {}

    @State private var serverAddress = ""
    @State private var enrollmentToken = ""
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
            && !enrollmentToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        onSubmitServer(serverAddress, enrollmentToken)
    }

    /// Where the token comes from, for the typed address when it parses.
    private var enrollmentHint: String {
        let page = ServerAddress(parsing: serverAddress).map { "\($0.absoluteString)/enrollment" } ?? "the server's /enrollment page"
        return "Generate an enrollment token at \(page). It works once and expires after 5 minutes."
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
                .submitLabel(.next)
                .disabled(isConnecting)
                .setupFieldStyle()

            TextField("Enrollment token", text: $enrollmentToken)
                .textContentType(.oneTimeCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.continue)
                .onSubmit(submit)
                .disabled(isConnecting)
                .setupFieldStyle()

            Text(enrollmentHint)
                .font(GianTheme.Typography.caption)
                .foregroundStyle(GianTheme.Colors.secondaryLabel)
                .multilineTextAlignment(.center)

            connectionStatus

            Button("Continue", action: submit)
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
                        Button("Trust new identity", role: .destructive) { onTrustNewServerIdentity(enrollmentToken) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This device connects with the enrollment token above, and its Hosts must be paired again.")
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
                onScanPayload: onPairPayload,
                onCode: onPairCode,
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

private extension View {
    func setupFieldStyle() -> some View {
        font(GianTheme.Typography.body)
            .padding(GianTheme.Metrics.paddingMedium)
            .background(GianTheme.Colors.card,
                        in: RoundedRectangle(cornerRadius: GianTheme.Metrics.cornerRadiusMedium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: GianTheme.Metrics.cornerRadiusMedium, style: .continuous)
                    .stroke(GianTheme.Colors.separator, lineWidth: 0.5)
            )
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
