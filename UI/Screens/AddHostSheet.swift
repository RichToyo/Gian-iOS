import SwiftUI

/// Add Host's pairing state and intents. The store keeps the current Host
/// open while another one pairs.
struct AddHostPresentation {
    var isWaiting = false
    /// The last attempt paired a Host (possibly one already paired).
    var didPair = false
    var notice: String? = nil
    var onPairPayload: (String) -> Void = { _ in }
    var onPairCode: (String) -> Void = { _ in }
    var onRefresh: () -> Void = {}
    /// Abandons a pairing in progress and clears the last outcome. Runs when
    /// the sheet opens (setup leaves a "paired" outcome behind) and closes.
    var onReset: () -> Void = {}
}

/// Pairs another Host while signed in: scan its QR code or type its one-time
/// code, then the Host confirms this device. Once confirmed the app switches to the
/// new Host and `addHostSheet` closes this.
struct AddHostSheet: View {
    let pairing: AddHostPresentation
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            // A plain stack, like setup: a scroll view swallowed the first tap.
            VStack(spacing: GianTheme.Metrics.paddingLarge) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 40))
                    .foregroundStyle(GianTheme.Colors.tint)
                    .accessibilityHidden(true)
                HostPairingPanel(
                    isWaiting: pairing.isWaiting,
                    notice: pairing.notice,
                    onScanPayload: pairing.onPairPayload,
                    onCode: pairing.onPairCode,
                    onRefreshPairing: pairing.onRefresh
                )
                Spacer(minLength: 0)
            }
            .frame(maxWidth: GianTheme.Metrics.formWidth)
            .padding(GianTheme.Metrics.paddingLarge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GianTheme.Colors.background)
            .navigationTitle("Add Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", action: onClose)
                }
            }
        }
    }
}

extension View {
    /// Presents Add Host and closes it once a Host is paired (the store has
    /// switched to it). Closing any other way abandons the pairing.
    func addHostSheet(isPresented: Binding<Bool>, pairing: AddHostPresentation) -> some View {
        sheet(isPresented: isPresented, onDismiss: pairing.onReset) {
            AddHostSheet(pairing: pairing, onClose: { isPresented.wrappedValue = false })
                .onAppear(perform: pairing.onReset)
        }
        .onChange(of: pairing.didPair) { _, paired in
            if paired { isPresented.wrappedValue = false }
        }
    }
}
