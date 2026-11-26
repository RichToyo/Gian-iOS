import SwiftUI
import GianCore

/// Where a link in a reply leads. Web links open in the browser; a relative
/// link ("src/foo.ts", "./README.md#setup") or a `file:` link names a file
/// in the conversation's repository, opened read-only through the Host;
/// anything else (`javascript:`, `data:`) goes nowhere.
enum LinkDestination: Equatable {
    case web
    case file(String)
    case blocked

    init(_ url: URL) {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto", "tel":
            self = .web
        case "file":
            self = url.path.isEmpty ? .blocked : .file(url.path)
        case nil:
            let raw = url.absoluteString.removingPercentEncoding ?? url.absoluteString
            let reference = raw.hasPrefix("./") ? String(raw.dropFirst(2)) : raw
            self = reference.isEmpty || reference.hasPrefix("#") ? .blocked : .file(reference)
        default:
            self = .blocked
        }
    }
}

/// A linked file, read-only: text and code in a monospaced, selectable view;
/// images as images; anything else through Quick Look.
struct FileReferenceSheet: View {
    let reference: String
    let load: (String) async -> FileReferencePreviewResponse
    var onClose: () -> Void

    @State private var result: FileReferencePreviewResponse?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: onClose)
                    }
                    if case .preview(_, let data) = result, let text = String(data: data, encoding: .utf8) {
                        ToolbarItem(placement: .primaryAction) {
                            CopyTextButton(text: text, label: "Copy file")
                        }
                    }
                }
        }
        .task(id: reference) {
            result = nil
            result = await load(reference)
        }
    }

    private var title: String {
        if case .preview(let name, _) = result { return name }
        if case .notPreviewable(let name) = result { return name }
        return (reference as NSString).lastPathComponent
    }

    @ViewBuilder
    private var content: some View {
        switch result {
        case nil:
            VStack(spacing: GianTheme.Metrics.paddingSmall) {
                ProgressView()
                Text("Opening \(reference)…")
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .preview(let name, let data):
            if let image = UIImage(data: data) {
                ScrollView {
                    Image(uiImage: image).resizable().scaledToFit().padding()
                }
            } else if let text = String(data: data, encoding: .utf8) {
                ScrollView([.vertical, .horizontal]) {
                    Text(CodeHighlighter.highlighted(text, language: (name as NSString).pathExtension))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("file-reference-text")
            } else {
                AttachmentPreviewSheet(name: name, data: data, onClose: onClose)
            }
        case .notPreviewable:
            ContentUnavailableView("Can't preview this file", systemImage: "doc",
                                   description: Text("The Host previews text files and images up to 1 MB."))
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't open \((reference as NSString).lastPathComponent)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { result = nil; result = await load(reference) } }
            }
        case .unsupported:
            ContentUnavailableView("Files can't be opened here", systemImage: "doc.questionmark",
                                   description: Text("This Host doesn't share files with this device."))
        }
    }
}
