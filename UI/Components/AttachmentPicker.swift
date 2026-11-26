import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import GianCore

/// Native attachment acquisition for the composer: Photos picker and file
/// importer. File URLs are opened with security-scoped access; bytes go
/// straight into `.addDraftAttachment` — the UI never persists or transports
/// them itself. Thumbnails are captured in a UI-local cache for display only.
struct AttachmentPickerButton: View {
    /// UI-local thumbnails, keyed by the attachment id returned after add.
    /// Because the add action assigns the id inside the core, thumbnails are
    /// keyed by content hash here and resolved by the composer mapper.
    var onPicked: (AttachmentDraftInput, Image?) -> Void

    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var fileImporterPresented = false

    var body: some View {
        Menu {
            PhotosPicker(
                selection: $photoSelection,
                maxSelectionCount: 10,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label("Photo library", systemImage: "photo")
            }
            Button {
                fileImporterPresented = true
            } label: {
                Label("Files", systemImage: "folder")
            }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.medium))
                .foregroundStyle(GianTheme.Colors.label)
                .gianHitTarget()
        }
        .accessibilityLabel("Add attachment")
        .task(id: photoSelection) {
            await loadPhotos()
        }
        .fileImporter(
            isPresented: $fileImporterPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls.prefix(10) { loadFile(url) }
            case .failure:
                break
            }
        }
    }

    private func loadPhotos() async {
        let selection = photoSelection
        guard !selection.isEmpty else { return }
        defer { photoSelection = [] }
        let stamp = PickedImage.stamp.string(from: Date())
        for (index, item) in selection.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = PickedImage.prepare(data, type: item.supportedContentTypes.first) else { continue }
            // Not `itemIdentifier`: that is the library's asset ID ("UUID/L0/001"),
            // and its "/" made every library photo an unsafe filename.
            let number = selection.count > 1 ? " \(index + 1)" : ""
            let filename = "Photo \(stamp)\(number).\(image.fileExtension)"
            let thumbnail = UIImage(data: image.data).map { Image(uiImage: $0) }
            onPicked(AttachmentDraftInput(filename: filename, mime: image.mime, bytes: image.data), thumbnail)
        }
    }

    private func loadFile(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url) else { return }
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true, let image = PickedImage.prepare(data, type: type) {
            let name = image.data == data ? url.lastPathComponent
                : url.deletingPathExtension().lastPathComponent + "." + image.fileExtension
            onPicked(AttachmentDraftInput(filename: name, mime: image.mime, bytes: image.data),
                     UIImage(data: image.data).map { Image(uiImage: $0) })
            return
        }
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        onPicked(AttachmentDraftInput(filename: url.lastPathComponent, mime: mime, bytes: data), nil)
    }
}

/// Images the Host and its Agents can read: the Host treats only PNG, JPEG,
/// GIF and WebP as images, so camera formats (HEIC) become JPEG, and very
/// large images are scaled down so Agents accept them.
enum PickedImage {
    struct Prepared { var data: Data; var mime: String; var fileExtension: String }

    static let readable: [String: String] = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp"]
    static let comfortableBytes = 5 * 1024 * 1024
    static let longestSide: CGFloat = 2560

    static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    static func prepare(_ data: Data, type: UTType?) -> Prepared? {
        if let mime = type?.preferredMIMEType, let ext = readable[mime], data.count <= comfortableBytes {
            return Prepared(data: data, mime: mime, fileExtension: ext)
        }
        guard let image = UIImage(data: data) else { return nil }
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let factor = data.count > comfortableBytes ? min(1, longestSide / max(pixels.width, pixels.height)) : 1
        let size = CGSize(width: (pixels.width * factor).rounded(), height: (pixels.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // Drawing bakes the photo's orientation into the pixels.
        let jpeg = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.85) { context in
            UIColor.white.setFill()  // JPEG has no transparency
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return Prepared(data: jpeg, mime: "image/jpeg", fileExtension: "jpg")
    }
}

#Preview("Attachment picker") {
    AttachmentPickerButton { _, _ in }
        .padding()
}
