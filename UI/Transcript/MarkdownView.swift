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
        case .heading(_, let text), .paragraph(let text): [text]
        case .blockquote(let blocks): blocks.flatMap(\.inlineTexts)
        case .list(let list): list.items.flatMap { $0.blocks.flatMap(\.inlineTexts) }
        case .table(let headers, _, let rows): headers + rows.flatMap { $0 }
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
        case .table(let headers, let alignments, let rows):
            TableBlockView(headers: headers, alignments: alignments, rows: rows)
        case .list(let list):
            MarkdownListView(list: list)
        case .blockquote(let blocks):
            HStack(alignment: .top, spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(GianTheme.Colors.secondaryLabel.opacity(0.5))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: GianTheme.Metrics.paddingSmall) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        MarkdownBlockView(block: block)
                    }
                }
                .foregroundStyle(GianTheme.Colors.secondaryLabel)
                .padding(.leading, GianTheme.Metrics.paddingSmall)
            }
            .fixedSize(horizontal: false, vertical: true)
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

/// A list as written: its own start number counting up, items that hold
/// paragraphs, code and nested lists, task checkboxes. Markers sit in one
/// column as wide as the widest, so wrapped lines and nested lists align.
struct MarkdownListView: View {
    let list: MarkdownList
    @Environment(\.markdownListDepth) private var depth

    var body: some View {
        let widest = marker(list.items.count - 1, checked: nil)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { offset, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    ZStack(alignment: .trailing) {
                        Text(widest).hidden()
                        markerView(offset, checked: item.checked)
                    }
                    .font(GianTheme.Typography.body.monospacedDigit())
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    .accessibilityHidden(item.checked == nil)
                    VStack(alignment: .leading, spacing: 6) {
                        if item.blocks.isEmpty {
                            Text(" ").font(GianTheme.Typography.body)
                        }
                        ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, block in
                            MarkdownBlockView(block: block)
                        }
                    }
                    .environment(\.markdownListDepth, depth + 1)
                }
            }
        }
    }

    @ViewBuilder
    private func markerView(_ offset: Int, checked: Bool?) -> some View {
        if let checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? GianTheme.Colors.tint : GianTheme.Colors.secondaryLabel)
                .accessibilityLabel(checked ? "Done" : "Not done")
        } else {
            Text(marker(offset, checked: nil))
        }
    }

    private func marker(_ offset: Int, checked: Bool?) -> String {
        guard list.ordered else { return ["•", "◦", "▪"][depth % 3] }
        return "\(list.start + max(offset, 0))."
    }
}

extension EnvironmentValues {
    /// How deeply the list being drawn is nested (bullets change per level).
    @Entry var markdownListDepth = 0
}

/// Fenced code block: a slim language label and Copy (with a checkmark for a
/// moment after), coloured code that scrolls sideways for long lines.
struct CodeBlockView: View {
    var language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(language ?? "code")
                    .font(.caption.monospaced())
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    .lineLimit(1)
                Spacer(minLength: GianTheme.Metrics.paddingSmall)
                CopyTextButton(text: code, label: "Copy code")
            }
            .padding(.leading, GianTheme.Metrics.paddingMedium)
            .padding(.trailing, GianTheme.Metrics.paddingSmall)
            .padding(.top, 2)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(CodeHighlighter.highlighted(code, language: language))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(GianTheme.Colors.label)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, GianTheme.Metrics.paddingMedium)
                    .padding(.bottom, GianTheme.Metrics.paddingMedium - 2)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .background(
            GianTheme.Colors.codeBackground,
            in: RoundedRectangle(cornerRadius: GianTheme.Metrics.cornerRadiusMedium, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GianTheme.Metrics.cornerRadiusMedium, style: .continuous)
                .stroke(GianTheme.Colors.separator, lineWidth: 0.5)
        )
    }
}

/// Markdown table: columns as wide as their content (up to a share of the
/// width, then cells wrap), aligned as the delimiter row says; a table wider
/// than the screen scrolls sideways instead of squeezing every column.
struct TableBlockView: View {
    let headers: [String]
    var alignments: [TableAlignment] = []
    let rows: [[String]]

    @State private var width: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { column, cell in
                        self.cell(cell, column: column, isHeader: true)
                    }
                }
                .background(GianTheme.Colors.secondaryLabel.opacity(0.08))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                    Divider().overlay(GianTheme.Colors.separator)
                    GridRow {
                        ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                            self.cell(cell, column: column, isHeader: false)
                        }
                    }
                }
            }
            .background(GianTheme.Colors.card)
            .clipShape(RoundedRectangle(cornerRadius: GianTheme.Metrics.cornerRadiusSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: GianTheme.Metrics.cornerRadiusSmall, style: .continuous)
                    .stroke(GianTheme.Colors.separator, lineWidth: 0.5)
            )
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// The widest a cell grows before its text wraps: an even share of the
    /// width, but never so narrow that words break apart.
    private var cellLimit: CGFloat {
        guard width > 0, !headers.isEmpty else { return 220 }
        return max(120, (width / CGFloat(headers.count)).rounded(.down))
    }

    private func cell(_ text: String, column: Int, isHeader: Bool) -> some View {
        let alignment = column < alignments.count ? alignments[column] : .leading
        // Cells carry inline Markdown (bold, code, links) like paragraphs.
        // A cell is as wide as its text up to the limit, then wraps; the row
        // takes the wrapped height (sizing the text first let a Grid column
        // come out a hair narrower, wrap it, and keep the one-line height).
        return CellText(text: MarkdownCache.text(text), limit: cellLimit - GianTheme.Metrics.paddingSmall * 2,
                        alignment: alignment.text)
            .font(isHeader ? GianTheme.Typography.caption.weight(.semibold) : GianTheme.Typography.caption)
            .foregroundStyle(isHeader ? GianTheme.Colors.secondaryLabel : GianTheme.Colors.label)
            .frame(maxWidth: .infinity, alignment: alignment.frame)
            .padding(.horizontal, GianTheme.Metrics.paddingSmall)
            .padding(.vertical, 6)
            .gridColumnAlignment(alignment.horizontal)
    }
}

/// Text that takes its one-line width up to `limit`, wrapping past it, and
/// always its full height for whatever width it gets.
private struct CellText: View {
    let text: Text
    let limit: CGFloat
    let alignment: TextAlignment

    init(text: Text, limit: CGFloat, alignment: TextAlignment) {
        self.text = text; self.limit = limit; self.alignment = alignment
    }

    var body: some View {
        CellTextLayout(limit: limit) {
            text.multilineTextAlignment(alignment)
        }
    }
}

private struct CellTextLayout: Layout {
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        let natural = text.sizeThatFits(.unspecified)
        // One line when that fits the limit (with a point of slack, or the
        // exact width can wrap the last glyph); otherwise wrapped at the limit.
        let width = natural.width + 1 <= limit ? (natural.width + 1).rounded(.up) : limit
        let height = text.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

private extension TableAlignment {
    var text: TextAlignment {
        switch self { case .leading: .leading; case .center: .center; case .trailing: .trailing }
    }
    var frame: Alignment {
        switch self { case .leading: .leading; case .center: .center; case .trailing: .trailing }
    }
    var horizontal: HorizontalAlignment {
        switch self { case .leading: .leading; case .center: .center; case .trailing: .trailing }
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
