import AVFoundation
import SwiftUI
import VisionKit
import GianCore

/// Host pairing in two pages: scanning the Host's QR code (the default) and,
/// from a small link under it, typing the Host's one-time code. Once claimed,
/// the wait for the Host to confirm this device. Shared by setup and Add Host.
struct HostPairingPanel: View {
    let isWaiting: Bool
    var notice: String? = nil
    var onScanPayload: (String) -> Void
    var onCode: (String) -> Void
    var onRefreshPairing: () -> Void

    @State private var entersCode = false

    var body: some View {
        Group {
            if isWaiting {
                waiting
            } else if entersCode {
                OneTimeCodeEntry(notice: notice, onSubmit: onCode, onScanInstead: { entersCode = false })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                QRScanEntry(notice: notice, onPayload: onScanPayload, onEnterCode: { entersCode = true })
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.default, value: entersCode)
    }

    private var waiting: some View {
        VStack(spacing: GianTheme.Metrics.paddingSmall) {
            ProgressView()
            Text("Confirm this device on your Host.")
                .font(GianTheme.Typography.caption)
                .foregroundStyle(GianTheme.Colors.secondaryLabel)
            Button("Check confirmation", action: onRefreshPairing)
                .buttonStyle(GianSecondaryButtonStyle())
        }
        // The Host confirms out of band; check periodically so the app moves
        // on by itself. The button stays as a manual check.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                onRefreshPairing()
            }
        }
    }
}

/// The default page: the camera, scanning for the Host's QR code.
private struct QRScanEntry: View {
    var notice: String?
    var onPayload: (String) -> Void
    var onEnterCode: () -> Void

    /// Nil while asking for camera access.
    @State private var cameraReady: Bool?
    /// A new scanner after a failed attempt (one scan delivers once).
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: GianTheme.Metrics.paddingMedium) {
            Text("Scan the QR code shown on the Host.")
                .font(GianTheme.Typography.caption)
                .foregroundStyle(GianTheme.Colors.secondaryLabel)
                .multilineTextAlignment(.center)
            camera
                .frame(maxWidth: 280)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: GianTheme.Metrics.cornerRadiusMedium, style: .continuous))
            if let notice { PairingNotice(text: notice) }
            Button("Enter one-time code", action: onEnterCode)
                .font(GianTheme.Typography.caption.weight(.semibold))
                .foregroundStyle(GianTheme.Colors.tint)
                .buttonStyle(.plain)
                .frame(minHeight: GianTheme.Metrics.minHitTarget)
        }
        .task { cameraReady = await Self.cameraAvailable() }
        .onChange(of: notice) { _, _ in attempt += 1 }
    }

    @ViewBuilder
    private var camera: some View {
        switch cameraReady {
        case .some(true):
            QRScannerSheet(onPayload: onPayload, onCancel: {})
                .id(attempt)
                .accessibilityLabel("QR code scanner")
        case .some(false):
            ZStack {
                GianTheme.Colors.card
                VStack(spacing: GianTheme.Metrics.paddingSmall) {
                    Image(systemName: "camera.slash")
                        .font(.title2)
                    Text("The camera isn't available. Enter the one-time code instead.")
                        .font(GianTheme.Typography.caption)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(GianTheme.Colors.secondaryLabel)
                .padding(GianTheme.Metrics.paddingMedium)
            }
        case .none:
            ZStack { GianTheme.Colors.card; ProgressView() }
        }
    }

    private static func cameraAvailable() async -> Bool {
        guard DataScannerViewController.isSupported else { return false }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return DataScannerViewController.isAvailable
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}

/// The Host's one-time code as 8 boxes with the hyphen fixed in the middle;
/// a person types only the characters. Pairs as soon as all 8 are in.
struct OneTimeCodeEntry: View {
    var notice: String?
    var onSubmit: (String) -> Void
    var onScanInstead: () -> Void

    @State private var code = ""
    @State private var focused = false

    var body: some View {
        VStack(spacing: GianTheme.Metrics.paddingMedium) {
            Text("Enter the one-time code shown on the Host.")
                .font(GianTheme.Typography.caption)
                .foregroundStyle(GianTheme.Colors.secondaryLabel)
                .multilineTextAlignment(.center)
            boxes
            if let notice { PairingNotice(text: notice) }
            Button("Pair") { onSubmit(characters) }
                .buttonStyle(GianPrimaryButtonStyle())
                .disabled(characters.count < PairingCode.length)
            Button("Scan QR code instead", action: onScanInstead)
                .font(GianTheme.Typography.caption.weight(.semibold))
                .foregroundStyle(GianTheme.Colors.tint)
                .buttonStyle(.plain)
                .frame(minHeight: GianTheme.Metrics.minHitTarget)
        }
        .onChange(of: code) { _, value in
            // Only drop what can't be part of a code. Rewriting the field for
            // case alone (k → K) would swallow the next keystrokes; the boxes
            // show the mapped characters anyway.
            let cleaned = PairingCode.characters(from: value)
            if cleaned.count != value.count { code = cleaned; return }
            if cleaned.count == PairingCode.length { onSubmit(cleaned) }
        }
    }

    /// What the boxes show and what pairs: uppercased, I/L → 1, O → 0.
    private var characters: String { PairingCode.characters(from: code) }

    private var boxes: some View {
        ZStack {
            // One field takes the typing; the boxes only draw it.
            CodeInputField(text: $code, isFocused: $focused)
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { box($0) }
                Text("-")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    .accessibilityHidden(true)
                ForEach(4..<8, id: \.self) { box($0) }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .frame(height: 48)
    }

    private func box(_ index: Int) -> some View {
        let characters = Array(self.characters)
        let isCurrent = focused && index == min(characters.count, PairingCode.length - 1)
        return Text(index < characters.count ? String(characters[index]) : "")
            .font(.system(.title3, design: .monospaced).weight(.semibold))
            .foregroundStyle(GianTheme.Colors.label)
            .frame(width: 32, height: 44)
            .background(GianTheme.Colors.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isCurrent ? GianTheme.Colors.tint : GianTheme.Colors.separator, lineWidth: isCurrent ? 2 : 0.5)
            )
    }
}

/// The hidden field under the code boxes. UIKit rather than a SwiftUI
/// `TextField`: inside the Add Host sheet SwiftUI drops every programmatic
/// focus request, and the keyboard should be up without a tap.
private struct CodeInputField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    func makeUIView(context: Context) -> SelfFocusingTextField {
        let field = SelfFocusingTextField()
        field.keyboardType = .asciiCapable
        field.autocapitalizationType = .allCharacters
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.textContentType = .oneTimeCode
        field.textColor = .clear
        field.tintColor = .clear
        field.accessibilityLabel = "One-time code"
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: SelfFocusingTextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: CodeInputField
        init(_ parent: CodeInputField) { self.parent = parent }

        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }
        func textFieldDidBeginEditing(_ field: UITextField) { parent.isFocused = true }
        func textFieldDidEndEditing(_ field: UITextField) { parent.isFocused = false }
    }
}

/// Takes the keyboard once it's on screen, after the page or sheet
/// transition (a request made mid-transition is ignored).
private final class SelfFocusingTextField: UITextField {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        Task { @MainActor [weak self] in
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.window != nil else { return }
                if self.isFirstResponder || self.becomeFirstResponder() { return }
            }
        }
    }
}

private struct PairingNotice: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(GianTheme.Typography.caption)
            .foregroundStyle(GianTheme.Colors.failure)
            .multilineTextAlignment(.center)
    }
}

#Preview("Pairing · scan") {
    HostPairingPanel(isWaiting: false, onScanPayload: { _ in }, onCode: { _ in }, onRefreshPairing: {})
        .padding()
}

#Preview("Pairing · code") {
    OneTimeCodeEntry(notice: nil, onSubmit: { _ in }, onScanInstead: {})
        .padding()
}
