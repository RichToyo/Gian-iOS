import SwiftUI
import QuickLook
import GianCore

/// Real transcript attachment row driven by the Core descriptor and bounded
/// download-cache state. Download dispatches `.downloadAttachment`; preview is
/// offered only after Core returns verified bytes, via protected temporary
/// files with generated safe names — never a Host-local path.
struct TranscriptAttachmentView: View {
    let presentation: AttachmentFilePresentation
    var onDownload: () -> Void = {}
    var onPreview: () -> Void = {}

    var body: some View {
        switch presentation {
        case .unknown:
            note(icon: "questionmark.folder", text: "Attachment details are unavailable.", tint: GianTheme.Colors.secondaryLabel)
        case .readyToDownload(let name, let byteCount, _):
            Button(action: onDownload) {
                rowContent(icon: "arrow.down.circle", name: name, detail: byteCountText(byteCount), tint: GianTheme.Colors.tint)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Downloads the file")
        case .downloading(let name):
            HStack(spacing: GianTheme.Metrics.paddingSmall) {
                ProgressView().controlSize(.small)
                Text(name)
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(GianTheme.Metrics.paddingSmall)
        case .cached(let name, let previewable):
            if previewable {
                Button(action: onPreview) {
                    rowContent(icon: "doc.text.magnifyingglass", name: name, detail: "Downloaded", tint: GianTheme.Colors.success)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Previews the downloaded file")
            } else {
                rowContent(icon: "checkmark.circle", name: name, detail: "Downloaded", tint: GianTheme.Colors.success)
            }
        case .expired(let name):
            note(icon: "clock.badge.exclamationmark", text: "\(name) — the remote file expired.", tint: GianTheme.Colors.warning)
        case .unavailable(let name):
            note(icon: "exclamationmark.triangle", text: "\(name) is unavailable.", tint: GianTheme.Colors.warning)
        case .failed(let name, let message):
            HStack(spacing: GianTheme.Metrics.paddingSmall) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(GianTheme.Colors.warning)
                Text(name)
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Retry", action: onDownload)
                    .font(GianTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(GianTheme.Colors.tint)
                    .gianHitTarget()
            }
            .padding(GianTheme.Metrics.paddingSmall)
            .accessibilityElement(children: .combine)
            .accessibilityHint(message)
        }
    }

    private func rowContent(icon: String, name: String, detail: String, tint: Color) -> some View {
        HStack(spacing: GianTheme.Metrics.paddingSmall) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(GianTheme.Typography.caption.weight(.medium))
                    .foregroundStyle(GianTheme.Colors.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(GianTheme.Typography.badge)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
            }
            Spacer(minLength: 0)
        }
        .padding(GianTheme.Metrics.paddingSmall)
        .background(
            GianTheme.Colors.secondaryLabel.opacity(0.1),
            in: RoundedRectangle(
                cornerRadius: GianTheme.Metrics.cornerRadiusSmall,
                style: .continuous
            )
        )
    }

    private func note(icon: String, text: String, tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(GianTheme.Typography.caption)
            .foregroundStyle(tint)
            .padding(GianTheme.Metrics.paddingSmall)
            .accessibilityElement(children: .combine)
    }

    private func byteCountText(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

/// Attachment preview sheet: images render natively; other types use
/// QuickLook over a protected temporary file with a generated safe name.
/// File creation happens once in the presentation lifecycle (never in body);
/// the temporary file is removed on dismissal, replacement or disappearance.
/// Creation failure renders an honest unavailable state.
struct AttachmentPreviewSheet: View {
    let name: String
    let data: Data
    var onClose: () -> Void

    @State private var tempFileURL: URL?
    @State private var preparationFailed = false

    var body: some View {
        NavigationStack {
            Group {
                if let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding()
                } else if let url = tempFileURL {
                    // `.id(url)` forces controller replacement when the
                    // presented file changes; the old controller can never
                    // keep a deleted URL.
                    QuickLookPreview(url: url)
                        .id(url)
                } else if preparationFailed {
                    ContentUnavailableView(
                        "Preview unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("The downloaded file could not be prepared for preview.")
                    )
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        cleanupTemporaryFile()
                        onClose()
                    }
                }
            }
        }
        .task { prepareTemporaryFileIfNeeded() }
        .onChange(of: data) { _, _ in
            cleanupTemporaryFile()
            preparationFailed = false
            prepareTemporaryFileIfNeeded()
        }
        .onDisappear { cleanupTemporaryFile() }
    }

    /// Creates the protected temporary file once per presented data. Images
    /// never touch the filesystem.
    private func prepareTemporaryFileIfNeeded() {
        guard tempFileURL == nil, UIImage(data: data) == nil else { return }
        tempFileURL = Self.makeTemporaryFile(name: name, data: data)
        preparationFailed = tempFileURL == nil
    }

    private func cleanupTemporaryFile() {
        guard let url = tempFileURL else { return }
        try? FileManager.default.removeItem(at: url)
        tempFileURL = nil
    }

    /// Protected temporary file with a generated name; the Host-supplied name
    /// contributes only a sanitized extension, never a path.
    static func makeTemporaryFile(name: String, data: Data) -> URL? {
        let pathExtension = (name as NSString).pathExtension
        let safeExtension = pathExtension
            .filter { $0.isLetter || $0.isNumber }
            .prefix(10)
        var filename = UUID().uuidString
        if !safeExtension.isEmpty {
            filename += "." + safeExtension
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            return nil
        }
    }
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
