import SwiftUI
import QuickLook
import ImageIO
import GianCore

enum InlineImagePolicy {
    static func shouldLoad(isImage: Bool, enabled: Bool, presentation: AttachmentFilePresentation) -> Bool {
        guard isImage, enabled else { return false }
        if case .readyToDownload(_, _, let previewable) = presentation { return previewable }
        return false
    }
}

/// Real transcript attachment row driven by the Core descriptor and bounded
/// download-cache state. Download dispatches `.downloadAttachment`; preview is
/// offered only after Core returns verified bytes, via protected temporary
/// files with generated safe names — never a Host-local path.
struct TranscriptAttachmentView: View {
    let presentation: AttachmentFilePresentation
    var isImage: Bool = false
    /// Verified bytes, read only when a cached image needs decoding: reading
    /// re-verifies the bytes, too costly to repeat on every render.
    var imageData: () -> Data? = { nil }
    var autoLoadEnabled: Bool = false
    var attachmentNumber: Int? = nil
    var onDownload: () -> Void = {}
    var onPreview: () -> Void = {}
    @State private var requestedAutomatically = false
    @State private var thumbnail: UIImage?
    @State private var imageDecodeFinished = false

    var body: some View {
        content
            .onChange(of: autoLoadEnabled) { _, enabled in
                if !enabled { requestedAutomatically = false }
            }
            // Loaded once; if the cache later drops it, load it again on sight.
            .onChange(of: isCached) { _, cached in
                if cached { requestedAutomatically = false }
            }
            .task(id: shouldAutoDownload) {
                guard shouldAutoDownload, !requestedAutomatically else { return }
                requestedAutomatically = true
                onDownload()
            }
            .task(id: isImage && isCached) {
                guard isImage, isCached else {
                    thumbnail = nil; imageDecodeFinished = false
                    return
                }
                thumbnail = imageData().flatMap(Self.makeThumbnail)
                imageDecodeFinished = true
            }
    }

    private var shouldAutoDownload: Bool {
        InlineImagePolicy.shouldLoad(isImage: isImage, enabled: autoLoadEnabled, presentation: presentation)
    }

    private var isCached: Bool {
        if case .cached = presentation { true } else { false }
    }

    @ViewBuilder
    private var content: some View {
        switch presentation {
        case .unknown:
            note(icon: "questionmark.folder", text: "Attachment details are unavailable.", tint: GianTheme.Colors.secondaryLabel)
        case .readyToDownload(let name, let byteCount, let previewable):
            if isImage && previewable && !(autoLoadEnabled && requestedAutomatically) {
                note(icon: "photo", text: autoLoadEnabled ? "Loading image…" : "Image waiting for connection.", tint: GianTheme.Colors.secondaryLabel)
            } else if isImage && previewable {
                // The automatic load already ran and didn't stick: the user decides.
                Button(action: onDownload) {
                    rowContent(icon: "photo", name: name, detail: "Load image", tint: GianTheme.Colors.tint)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Loads the image")
            } else {
                Button(action: onDownload) {
                    rowContent(icon: "arrow.down.circle", name: name, detail: byteCountText(byteCount), tint: GianTheme.Colors.tint)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Downloads the file")
            }
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
            if isImage, previewable, let thumbnail {
                Button(action: onPreview) {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: GianTheme.Metrics.cornerRadiusSmall))
                        .overlay(alignment: .bottomTrailing) {
                            if let attachmentNumber {
                                Text("\(attachmentNumber)")
                                    .font(GianTheme.Typography.badge)
                                    .foregroundStyle(.white)
                                    .padding(4)
                                    .background(.black.opacity(0.65), in: Capsule())
                                    .padding(4)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open image \(name)")
            } else if isImage, previewable, !imageDecodeFinished {
                ProgressView().frame(width: 120, height: 100)
            } else if previewable {
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
                    .disabled(isImage && !autoLoadEnabled)
            }
            .padding(GianTheme.Metrics.paddingSmall)
            .accessibilityElement(children: .combine)
            .accessibilityHint(message)
        }
    }

    private static func makeThumbnail(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
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
