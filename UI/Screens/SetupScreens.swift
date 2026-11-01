import SwiftUI
import GianCore

/// Phase-driven setup flow bound to `GianClientState.phase`:
/// manual server address → GitHub device login (user code + safe OS browser
/// opening of the core-validated verification URI) → Host pairing (QR scan or
/// manual payload; QR pairs Hosts only). The app never collects a GitHub
/// password and never invents an OAuth redirect.
struct SetupFlowView: View {
    let phase: ClientPhase
    let account: AccountAuthorization
    let server: ServerAddress?
    let pendingPairing: PendingHostPairing?

    var onSubmitServer: (String) -> Void = { _ in }
    var onStartGitHubLogin: () -> Void = {}
    var onCancelGitHubLogin: () -> Void = {}
    var onOpenVerificationURL: (URL) -> Void = { _ in }
    var onPairPayload: (String) -> Void = { _ in }
    var onRefreshPairing: () -> Void = {}

    @State private var serverAddress = ""

    var body: some View {
        VStack(spacing: GianTheme.Metrics.paddingLarge) {
            brandHeader
            Spacer()
            stepContent
            Spacer()
        }
        .padding(GianTheme.Metrics.paddingLarge)
        .background(GianTheme.Colors.background)
    }

    private var brandHeader: some View {
        VStack(spacing: GianTheme.Metrics.paddingSmall) {
            Image("brand-icon")
                .resizable()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text("Gian")
                .font(.title.weight(.bold))
                .foregroundStyle(GianTheme.Colors.label)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch phase {
        case .signedOut, .serverEntered:
            serverAndSignInStep
        case .awaitingGitHubDeviceLogin:
            deviceLoginStep
        case .awaitingHostPairing:
            pairingStep
        case .ready:
            EmptyView()
        }
    }

    // MARK: - Server address + sign-in

    @ViewBuilder
    private var serverAndSignInStep: some View {
        VStack(spacing: GianTheme.Metrics.paddingMedium) {
            Text("Connect to your Gian server")
                .font(GianTheme.Typography.title)
                .foregroundStyle(GianTheme.Colors.label)

            accountStatusMessage

            TextField("https://server.example.com", text: $serverAddress)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
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
                .disabled(phase == .serverEntered)

            if phase == .signedOut {
                Button("Continue") {
                    onSubmitServer(serverAddress)
                }
                .buttonStyle(GianPrimaryButtonStyle())
                .disabled(serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                if let server {
                    Text(server.absoluteString)
                        .font(GianTheme.Typography.caption)
                        .foregroundStyle(GianTheme.Colors.secondaryLabel)
                }
                Button(action: onStartGitHubLogin) {
                    Label("Continue with GitHub", systemImage: "person.crop.circle.badge.checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GianPrimaryButtonStyle())
                Text("The server checks account admission and device grants. Gian never asks for your GitHub password.")
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private var accountStatusMessage: some View {
        switch account.status {
        case .denied:
            statusMessage("Sign-in was denied. Check your GitHub account and try again.", color: GianTheme.Colors.failure)
        case .expired:
            statusMessage("The sign-in code expired. Start again.", color: GianTheme.Colors.warning)
        case .error:
            statusMessage("Sign-in failed. Check the server address and try again.", color: GianTheme.Colors.failure)
        case .signedOut, .pending, .signedIn:
            EmptyView()
        }
    }

    private func statusMessage(_ text: String, color: Color) -> some View {
        Text(text)
            .font(GianTheme.Typography.caption)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
    }

    // MARK: - GitHub device login

    private var deviceLoginStep: some View {
        VStack(spacing: GianTheme.Metrics.paddingMedium) {
            Text("Authorize this device")
                .font(GianTheme.Typography.title)
                .foregroundStyle(GianTheme.Colors.label)

            if let login = account.deviceLogin {
                Text(login.userCode)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(GianTheme.Colors.label)
                    .textSelection(.enabled)
                    .padding(GianTheme.Metrics.paddingMedium)
                    .background(
                        GianTheme.Colors.card,
                        in: RoundedRectangle(
                            cornerRadius: GianTheme.Metrics.cornerRadiusMedium,
                            style: .continuous
                        )
                    )
                    .accessibilityLabel("GitHub device code \(login.userCode)")

                Text("Enter this code on GitHub. The code expires \(login.expiresAt.formatted(date: .omitted, time: .shortened)).")
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    .multilineTextAlignment(.center)

                Button {
                    onOpenVerificationURL(login.verificationURI)
                } label: {
                    Label("Open GitHub", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GianPrimaryButtonStyle())

                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for authorization…")
                        .font(GianTheme.Typography.caption)
                        .foregroundStyle(GianTheme.Colors.secondaryLabel)
                }
            }

            Button("Cancel", action: onCancelGitHubLogin)
                .buttonStyle(GianSecondaryButtonStyle())
        }
    }

    // MARK: - Host pairing

    private var pairingStep: some View {
        VStack(spacing: GianTheme.Metrics.paddingMedium) {
            Text("Pair a Host")
                .font(GianTheme.Typography.title)
                .foregroundStyle(GianTheme.Colors.label)

            if pendingPairing != nil {
                VStack(spacing: GianTheme.Metrics.paddingSmall) {
                    ProgressView()
                    Text("Confirm this device on your Host.")
                        .font(GianTheme.Typography.caption)
                        .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    Button("Check confirmation", action: onRefreshPairing)
                        .buttonStyle(GianSecondaryButtonStyle())
                }
            } else {
                Text("Scan the QR code shown by the Host, or paste the pairing link. QR codes pair Hosts only.")
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    .multilineTextAlignment(.center)
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

#Preview("Setup · device login") {
    SetupFlowView(
        phase: .awaitingGitHubDeviceLogin,
        account: AccountAuthorization(
            status: .pending,
            deviceLogin: GitHubDeviceLoginState(
                loginID: LoginID(rawValue: "login-1")!,
                userCode: "ABCD-EFGH",
                verificationURI: URL(string: "https://github.com/login/device")!,
                expiresAt: .now.addingTimeInterval(900),
                intervalSeconds: 5,
                nextPollAt: .now
            )
        ),
        server: ServerAddress(parsing: "https://remote.example.test"),
        pendingPairing: nil
    )
}
