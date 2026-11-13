import SwiftUI

/// Renders markdown source as native blocks: text with inline styling and
/// links, headings, code, tables, lists, quotes. Content-language is left
/// untouched; only chrome is English.
struct MarkdownView: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: GianTheme.Metrics.paddingMedium) {
            ForEach(Array(MarkdownCache.blocks(source).enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
    }
}

/// Parsed blocks and inline runs by source text. Transcript rows re-render on
/// every store change; parsing once per distinct text keeps that cheap, and a
/// streaming message only parses its newest form.
@MainActor
enum MarkdownCache {
    private static var blockCache = RecentCache<[MarkdownBlock]>(entries: 1_024, bytes: 4 * 1024 * 1024)
    private static var inlineCache = RecentCache<AttributedString>(entries: 4_096, bytes: 4 * 1024 * 1024)
    /// The last text parsed of each kind. A streaming message's next form
    /// extends it, and replaces it: keeping every form would fill the cache
    /// within one long reply.
    private static var lastBlocks: String?
    private static var lastInline: String?

    static func blocks(_ source: String) -> [MarkdownBlock] {
        if let cached = blockCache[source] { return cached }
        let parsed = MarkdownBlockParser.parse(source)
        if let last = lastBlocks, source.hasPrefix(last) { blockCache.remove(last) }
        lastBlocks = source
        blockCache.insert(parsed, for: source)
        return parsed
    }

    static func inline(_ text: String) -> AttributedString? {
        if let cached = inlineCache[text] { return cached }
        guard let attributed = InlineMarkdown.attributed(text) else { return nil }
        if let last = lastInline, text.hasPrefix(last) { inlineCache.remove(last) }
        lastInline = text
        inlineCache.insert(attributed, for: text)
        return attributed
    }

    /// Text with its inline Markdown rendered, or as written if it can't be parsed.
    static func text(_ source: String) -> Text {
        inline(source).map(Text.init) ?? Text(source)
    }

    /// Parses the messages not cached yet off the main thread, so a message
    /// coming into view (scrolling up into history) finds its blocks and text
    /// ready instead of parsing them in that frame.
    static func prepare(_ sources: [String]) async {
        let missing = sources.filter { !blockCache.contains($0) }
        guard !missing.isEmpty else { return }
        let parsed = await Task.detached(priority: .utility) {
            missing.map { source in
                let blocks = MarkdownBlockParser.parse(source)
                let texts = blocks.flatMap(\.inlineTexts).compactMap { text in
                    InlineMarkdown.attributed(text).map { (text, $0) }
                }
                return (source, blocks, texts)
            }
        }.value
        guard !Task.isCancelled else { return }
        for (source, blocks, texts) in parsed {
            if !blockCache.contains(source) { blockCache.insert(blocks, for: source) }
            for (text, attributed) in texts where !inlineCache.contains(text) {
                inlineCache.insert(attributed, for: text)
            }
        }
    }
}

extension MarkdownBlock {
    /// The texts its view renders as inline Markdown.
    var inlineTexts: [String] {
        switch self {
        case .heading(_, let text), .paragraph(let text), .blockquote(let text): [text]
        case .list(_, let items): items
        case .table(let headers, let rows): headers + rows.flatMap { $0 }
        case .code, .thematicBreak: []
        }
    }
}

/// A bounded cache that forgets what hasn't been used lately, never what is on
/// screen. Two generations: when the current one fills, it becomes the old one
/// and the previous old one is dropped; a hit in the old one moves back. So a
/// full cache never empties at once, which made everything shown re-parse in
/// one frame (an occasional hard stutter while scrolling a long chat).
struct RecentCache<Value> {
    let entries: Int
    let bytes: Int
    private var current: [String: Value] = [:]
    private var old: [String: Value] = [:]
    private var currentBytes = 0

    init(entries: Int, bytes: Int) {
        self.entries = entries
        self.bytes = bytes
    }

    subscript(key: String) -> Value? {
        mutating get {
            if let value = current[key] { return value }
            guard let value = old.removeValue(forKey: key) else { return nil }
            insert(value, for: key)
            return value
        }
    }

    mutating func insert(_ value: Value, for key: String) {
        let size = key.utf8.count
        if current[key] == nil, current.count >= entries || currentBytes + size > bytes {
            old = current
            current = [:]
            currentBytes = 0
        }
        if current.updateValue(value, forKey: key) == nil { currentBytes += size }
    }

    /// Whether it holds `key`, without moving it.
    func contains(_ key: String) -> Bool {
        current[key] != nil || old[key] != nil
    }

    mutating func remove(_ key: String) {
        if current.removeValue(forKey: key) != nil { currentBytes -= key.utf8.count }
        old.removeValue(forKey: key)
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(headingFont(level))
                .fontWeight(.semibold)
        case .paragraph(let text):
            inlineText(text)
                .font(GianTheme.Typography.body)
        case .code(let language, let code):
            CodeBlockView(language: language, code: code)
        case .table(let headers, let rows):
            TableBlockView(headers: headers, rows: rows)
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(offset + 1)." : "•")
                            .foregroundStyle(GianTheme.Colors.secondaryLabel)
                        inlineText(item)
                    }
                    .font(GianTheme.Typography.body)
                }
            }
        case .blockquote(let text):
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(GianTheme.Colors.secondaryLabel.opacity(0.5))
                    .frame(width: 3)
                inlineText(text)
                    .font(GianTheme.Typography.body)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    .padding(.leading, GianTheme.Metrics.paddingSmall)
            }
        case .thematicBreak:
            Divider().overlay(GianTheme.Colors.separator)
        }
    }

    private func inlineText(_ text: String) -> Text {
        MarkdownCache.text(text)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2
        case 2: .title3
        default: .headline
        }
    }
}

/// Fenced code block with a filename/language header, copy action and
/// horizontal scrolling for long lines.
struct CodeBlockView: View {
    var language: String?
    let code: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(GianTheme.Typography.code)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(GianTheme.Colors.secondaryLabel)
                        .gianHitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, GianTheme.Metrics.paddingMedium)
            .padding(.vertical, 6)
            .background(GianTheme.Colors.separator.opacity(0.5))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(GianTheme.Typography.code)
                    .foregroundStyle(GianTheme.Colors.label)
                    .textSelection(.enabled)
                    .padding(GianTheme.Metrics.paddingMedium)
            }
        }
        .background(
            GianTheme.Colors.codeBackground,
            in: RoundedRectangle(
                cornerRadius: GianTheme.Metrics.cornerRadiusMedium,
                style: .continuous
            )
        )
        .clipShape(RoundedRectangle(
            cornerRadius: GianTheme.Metrics.cornerRadiusMedium,
            style: .continuous
        ))
        .overlay(
            RoundedRectangle(
                cornerRadius: GianTheme.Metrics.cornerRadiusMedium,
                style: .continuous
            )
            .stroke(GianTheme.Colors.separator, lineWidth: 0.5)
        )
    }
}

/// Markdown table with a styled header row and hairline separators.
struct TableBlockView: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        VStack(spacing: 0) {
            row(cells: headers, isHeader: true)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                Divider().overlay(GianTheme.Colors.separator)
                row(cells: cells, isHeader: false)
            }
        }
        .background(GianTheme.Colors.card)
        .clipShape(RoundedRectangle(
            cornerRadius: GianTheme.Metrics.cornerRadiusSmall,
            style: .continuous
        ))
        .overlay(
            RoundedRectangle(
                cornerRadius: GianTheme.Metrics.cornerRadiusSmall,
                style: .continuous
            )
            .stroke(GianTheme.Colors.separator, lineWidth: 0.5)
        )
    }

    private func row(cells: [String], isHeader: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                // Cells carry inline Markdown (bold, code, links) like paragraphs.
                MarkdownCache.text(cell)
                    .font(isHeader ? GianTheme.Typography.caption.weight(.semibold) : GianTheme.Typography.caption)
                    .foregroundStyle(isHeader ? GianTheme.Colors.secondaryLabel : GianTheme.Colors.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, GianTheme.Metrics.paddingSmall)
                    .padding(.vertical, 6)
            }
        }
    }
}

#Preview("Markdown") {
    ScrollView {
        MarkdownView(source: """
        Done — Prod is the outlier ([build report](https://example.com)):

        | Env | Median | Δ |
        |---|---|---|
        | Dev | 72 s | — |
        | Prod | 206 s | +186% |

        Cache the install step:

        ```ci-cache.sh
        if cache-hit "pnpm-lock";
        then restore-cache
        ```

        - first item
        - second item

        > Quoted context
        """)
        .padding()
    }
}
