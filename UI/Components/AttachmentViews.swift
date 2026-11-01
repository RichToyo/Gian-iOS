import SwiftUI
import GianCore

/// Draft attachment chip inside the composer strip. The thumbnail comes from
/// a UI-local image cache populated at pick time (presentation state only);
/// upload bytes and cache identity live in the core.
struct DraftAttachmentChip: View {
    let attachment: DraftAttachment
    var thumbnail: Image?
    var onRemove: () -> Void
    var onRetryUpload: () -> Void

    var body: some View {
        content
            .frame(width: 72, height: 72)
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white, GianTheme.Colors.secondaryLabel)
                }
                .accessibilityLabel("Remove \(attachment.filename)")
                .offset(x: 4, y: -4)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch attachment.state {
        case .localOnly, .uploaded, .cached:
            base
        case .uploading, .downloading:
            ZStack {
                base
                ProgressView().controlSize(.small)
            }
        case .failed(let message):
            Button(action: onRetryUpload) {
                ZStack {
                    placeholder
                    VStack(spacing: 2) {
                        Image(systemName: "arrow.clockwise")
                        Text("Retry")
                            .font(GianTheme.Typography.badge)
                    }
                    .foregroundStyle(GianTheme.Colors.failure)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Upload failed: \(message). Retry.")
        case .expired, .unavailable, .hashMismatch:
            ZStack {
                placeholder
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(GianTheme.Colors.warning)
            }
            .accessibilityLabel("Attachment \(attachment.filename) is unavailable")
        }
    }

    @ViewBuilder
    private var base: some View {
        if let thumbnail {
            thumbnail
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipped()
                .clipShape(RoundedRectangle(
                    cornerRadius: GianTheme.Metrics.cornerRadiusSmall,
                    style: .continuous
                ))
        } else {
            fileChip
        }
    }

    private var placeholder: some View {
        RoundedRectangle(
            cornerRadius: GianTheme.Metrics.cornerRadiusSmall,
            style: .continuous
        )
        .fill(GianTheme.Colors.secondaryLabel.opacity(0.14))
    }

    private var fileChip: some View {
        VStack(spacing: 4) {
            Image(systemName: "doc")
                .font(.title3)
            Text(attachment.filename)
                .font(GianTheme.Typography.badge)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(GianTheme.Colors.secondaryLabel)
        .padding(6)
        .background(placeholder)
    }
}

/// Read-only transcript attachment rendering lives in
/// `TranscriptAttachmentView`, driven by Core descriptors and the bounded
/// download cache. This file keeps composer-side draft chips only.

#Preview("Attachment chips") {
    HStack {
        DraftAttachmentChip(
            attachment: DraftAttachment(
                id: AttachmentID(rawValue: "a1")!, filename: "palette.png", mime: "image/png",
                byteCount: 84_000, sha256: "", state: .uploading
            ),
            thumbnail: nil, onRemove: {}, onRetryUpload: {}
        )
        DraftAttachmentChip(
            attachment: DraftAttachment(
                id: AttachmentID(rawValue: "a2")!, filename: "spec.pdf", mime: "application/pdf",
                byteCount: 120_000, sha256: "", state: .failed("Network")
            ),
            thumbnail: nil, onRemove: {}, onRetryUpload: {}
        )
        TranscriptAttachmentView(
            presentation: .readyToDownload(name: "build-report.pdf", byteCount: 240_000, previewable: true)
        )
    }
    .padding()
}
