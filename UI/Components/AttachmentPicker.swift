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

    @State private var photoSelection: PhotosPickerItem?
    @State private var fileImporterPresented = false

    var body: some View {
        Menu {
            PhotosPicker(
                selection: $photoSelection,
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
            await loadPhoto()
        }
        .fileImporter(
            isPresented: $fileImporterPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    loadFile(url)
                }
            case .failure:
                break
            }
        }
    }

    private func loadPhoto() async {
        guard let selection = photoSelection else { return }
        defer { photoSelection = nil }
        guard let data = try? await selection.loadTransferable(type: Data.self) else { return }
        let filename = selection.itemIdentifier ?? "Photo.jpg"
        let mime = selection.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
        let thumbnail = UIImage(data: data).map { Image(uiImage: $0) }
        onPicked(AttachmentDraftInput(filename: filename, mime: mime, bytes: data), thumbnail)
    }

    private func loadFile(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url) else { return }
        let type = UTType(filenameExtension: url.pathExtension)
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        let thumbnail = type?.conforms(to: .image) == true
            ? UIImage(data: data).map { Image(uiImage: $0) }
            : nil
        onPicked(
            AttachmentDraftInput(filename: url.lastPathComponent, mime: mime, bytes: data),
            thumbnail
        )
    }
}

#Preview("Attachment picker") {
    AttachmentPickerButton { _, _ in }
        .padding()
}
