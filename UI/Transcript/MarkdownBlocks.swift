import Foundation

/// Deterministic block-level Markdown splitter for transcript rendering.
///
/// Presentation-only: inline emphasis/links are delegated to
/// `InlineMarkdown`; this parser handles block structure (headings, fenced
/// code, tables, lists, quotes) so each block maps to a native view. It
/// follows CommonMark/GFM where Agents rely on it — loose and nested lists,
/// a list's own start number, continuation lines, tables without outer pipes,
/// `~~~` fences — and is lenient where Agents are sloppy (a list or table
/// right under a paragraph). Remote payloads are untrusted: parsing never
/// evaluates content, nesting is bounded, and unknown structures degrade to
/// plain paragraphs.
enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, code: String)
    case table(headers: [String], alignments: [TableAlignment], rows: [[String]])
    case list(MarkdownList)
    case blockquote([MarkdownBlock])
    case thematicBreak
}

enum TableAlignment: Equatable, Sendable {
    case leading, center, trailing
}

struct MarkdownList: Equatable, Sendable {
    var ordered: Bool
    /// The number the list starts at ("3." starts at 3); items count up.
    var start: Int
    var items: [Item]

    struct Item: Equatable, Sendable {
        var blocks: [MarkdownBlock]
        /// A task-list checkbox ("- [ ]", "- [x]"); nil for a plain item.
        var checked: Bool?
    }
}

enum MarkdownBlockParser {
    /// Quotes and lists nested deeper than this read as plain text.
    static let maximumDepth = 12

    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map(expandingLeadingTabs)
        return parse(lines[...], depth: 0)
    }

    private static func parse(_ lines: ArraySlice<String>, depth: Int) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = lines.startIndex

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph.removeAll()
        }

        while index < lines.endIndex {
            let line = lines[index]
            let indent = leadingSpaces(line)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            // Deeper indentation is text (no indented code blocks: Agents
            // indent prose, and rarely code without a fence).
            if indent > 3 {
                paragraph.append(trimmed)
                index += 1
                continue
            }

            if let fence = openingFence(trimmed) {
                flushParagraph()
                var code: [String] = []
                index += 1
                while index < lines.endIndex, !closesFence(lines[index], fence) {
                    code.append(removingIndent(lines[index], upTo: indent))
                    index += 1
                }
                index += 1  // the closing fence; an unclosed one runs to the end (a streaming reply)
                blocks.append(.code(language: fence.language, code: code.joined(separator: "\n")))
                continue
            }

            if isThematicBreak(trimmed) {
                flushParagraph()
                blocks.append(.thematicBreak)
                index += 1
                continue
            }

            if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">"), depth < maximumDepth {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.endIndex {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    if next.hasPrefix(">") {
                        var content = next.dropFirst()
                        if content.first == " " { content = content.dropFirst() }
                        quoted.append(String(content))
                    } else if !next.isEmpty, let last = quoted.last, !last.trimmingCharacters(in: .whitespaces).isEmpty,
                              !startsBlock(lines[index]) {
                        quoted.append(next)  // a lazy continuation of the quoted paragraph
                    } else {
                        break
                    }
                    index += 1
                }
                blocks.append(.blockquote(parse(quoted[...], depth: depth + 1)))
                continue
            }

            if depth < maximumDepth, let marker = listMarker(line) {
                flushParagraph()
                let (list, next) = parseList(lines, from: index, first: marker, depth: depth)
                blocks.append(.list(list))
                index = next
                continue
            }

            if index + 1 < lines.endIndex, let table = parseTable(lines, from: index) {
                flushParagraph()
                blocks.append(table.block)
                index = table.next
                continue
            }

            paragraph.append(String(line.dropFirst(indent)))
            index += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: - Lists

    struct ListMarker: Equatable {
        var ordered: Bool
        var number: Int
        /// "-", "*", "+" for bullets; "." or ")" after an ordered number.
        var delimiter: Character
        /// Where the item's content starts: its continuation lines are
        /// indented at least this far.
        var contentIndent: Int
        var text: String
    }

    static func listMarker(_ line: String) -> ListMarker? {
        let characters = Array(line)
        var position = 0
        while position < characters.count, characters[position] == " " { position += 1 }
        guard position <= 3, position < characters.count else { return nil }
        let ordered: Bool
        var number = 0
        let delimiter: Character
        if "-*+".contains(characters[position]) {
            ordered = false
            delimiter = characters[position]
            position += 1
        } else {
            var digits = 0
            while position < characters.count, let digit = characters[position].wholeNumberValue,
                  characters[position].isASCII, digits < 9 {
                number = number * 10 + digit
                digits += 1
                position += 1
            }
            guard digits > 0, position < characters.count, characters[position] == "." || characters[position] == ")" else { return nil }
            ordered = true
            delimiter = characters[position]
            position += 1
        }
        // The marker must be followed by a space (or end an empty item).
        guard position == characters.count || characters[position] == " " else { return nil }
        var contentStart = position
        while contentStart < characters.count, characters[contentStart] == " " { contentStart += 1 }
        let spaces = contentStart - position
        let contentIndent = contentStart == characters.count || spaces > 4 ? position + 1 : contentStart
        let text = contentIndent < characters.count ? String(characters[contentIndent...]) : ""
        return ListMarker(ordered: ordered, number: number, delimiter: delimiter, contentIndent: contentIndent, text: text)
    }

    private static func continuesList(_ marker: ListMarker, after first: ListMarker) -> Bool {
        marker.ordered == first.ordered && (!marker.ordered || marker.delimiter == first.delimiter)
    }

    private static func parseList(_ lines: ArraySlice<String>, from start: Int, first: ListMarker,
                                  depth: Int) -> (MarkdownList, Int) {
        var items: [MarkdownList.Item] = []
        var itemLines: [String] = [first.text]
        var contentIndent = first.contentIndent
        var index = start + 1
        var afterBlank = false

        func finishItem() {
            while itemLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { itemLines.removeLast() }
            var checked: Bool?
            if var head = itemLines.first {
                for (box, value) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where head.hasPrefix(box) {
                    checked = value
                    head.removeFirst(box.count)
                }
                if ["[ ]", "[x]", "[X]"].contains(head) { checked = head != "[ ]"; head = "" }
                itemLines[0] = head
            }
            items.append(MarkdownList.Item(blocks: parse(itemLines[...], depth: depth + 1), checked: checked))
        }

        while index < lines.endIndex {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                itemLines.append("")
                afterBlank = true
                index += 1
                continue
            }
            let indent = leadingSpaces(line)
            if indent >= contentIndent {
                itemLines.append(removingIndent(line, upTo: contentIndent))
            } else if let marker = listMarker(line), continuesList(marker, after: first), !isThematicBreak(trimmed) {
                finishItem()
                itemLines = [marker.text]
                contentIndent = marker.contentIndent
            } else if !afterBlank, let last = itemLines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty,
                      !startsBlock(line), !itemHasOpenFence(itemLines) {
                itemLines.append(trimmed)  // a lazy continuation of the item's paragraph
            } else {
                break
            }
            afterBlank = false
            index += 1
        }
        finishItem()
        return (MarkdownList(ordered: first.ordered, start: first.number, items: items), index)
    }

    private static func itemHasOpenFence(_ lines: [String]) -> Bool {
        var open: Fence?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = open {
                if closesFence(line, fence) { open = nil }
            } else if let fence = openingFence(trimmed) {
                open = fence
            }
        }
        return open != nil
    }

    /// Whether a line starts a block of its own (so it can't continue a
    /// paragraph lazily).
    private static func startsBlock(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return openingFence(trimmed) != nil || isThematicBreak(trimmed) || heading(trimmed) != nil
            || trimmed.hasPrefix(">") || listMarker(line) != nil
    }

    // MARK: - Tables

    private static func parseTable(_ lines: ArraySlice<String>, from start: Int) -> (block: MarkdownBlock, next: Int)? {
        let header = lines[start].trimmingCharacters(in: .whitespaces)
        guard header.contains("|"), let alignments = tableDelimiter(lines[start + 1]) else { return nil }
        let headers = tableCells(header)
        guard !headers.isEmpty, headers.contains(where: { !$0.isEmpty }) else { return nil }
        let columns = headers.count
        func fitted<T>(_ cells: [T], filler: T) -> [T] {
            cells.count >= columns ? Array(cells.prefix(columns)) : cells + Array(repeating: filler, count: columns - cells.count)
        }
        var rows: [[String]] = []
        var index = start + 2
        while index < lines.endIndex {
            let row = lines[index].trimmingCharacters(in: .whitespaces)
            guard !row.isEmpty, row.contains("|"), !startsBlock(lines[index]) else { break }
            rows.append(fitted(tableCells(row), filler: ""))
            index += 1
        }
        return (.table(headers: headers, alignments: fitted(alignments, filler: .leading), rows: rows), index)
    }

    /// The `|---|:---:|` row under a table's header, as column alignments.
    static func tableDelimiter(_ line: String) -> [TableAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.contains("-") else { return nil }
        let cells = tableCells(trimmed)
        guard !cells.isEmpty else { return nil }
        var alignments: [TableAlignment] = []
        for cell in cells {
            let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
    }

    /// A row's cells: split on unescaped pipes (`\|` is a literal pipe),
    /// without the optional outer pipes.
    static func tableCells(_ row: String) -> [String] {
        var cells: [String] = []
        var cell = ""
        var characters = row[...]
        if characters.first == "|" { characters = characters.dropFirst() }
        var escaped = false
        for character in characters {
            if escaped {
                if character != "|" { cell.append("\\") }
                cell.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(cell)
                cell = ""
            } else {
                cell.append(character)
            }
        }
        if escaped { cell.append("\\") }
        // A trailing pipe closes the last cell rather than opening an empty one.
        if !cell.trimmingCharacters(in: .whitespaces).isEmpty || !row.trimmingCharacters(in: .whitespaces).hasSuffix("|") {
            cells.append(cell)
        }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Fences, breaks, headings

    struct Fence: Equatable {
        var marker: Character
        var length: Int
        var language: String?
    }

    static func openingFence(_ trimmed: String) -> Fence? {
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let length = trimmed.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        let info = trimmed.dropFirst(length).trimmingCharacters(in: .whitespaces)
        if marker == "`", info.contains("`") { return nil }  // inline code, not a fence
        let language = info.split(separator: " ").first.map(String.init)
        return Fence(marker: marker, length: length, language: language)
    }

    private static func closesFence(_ line: String, _ fence: Fence) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= fence.length && trimmed.allSatisfy { $0 == fence.marker }
    }

    static func isThematicBreak(_ trimmed: String) -> Bool {
        guard let marker = trimmed.first, "-*_".contains(marker) else { return false }
        var count = 0
        for character in trimmed {
            if character == marker { count += 1 } else if character != " " { return false }
        }
        return count >= 3
    }

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        let level = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // An optional closing sequence: "## Title ##".
        if let hashes = text.range(of: #"(^|\s)#+$"#, options: .regularExpression) {
            text = String(text[..<hashes.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return .heading(level: level, text: text)
    }

    // MARK: - Whitespace

    private static func leadingSpaces(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private static func removingIndent(_ line: String, upTo count: Int) -> String {
        String(line.dropFirst(min(count, leadingSpaces(line))))
    }

    private static func expandingLeadingTabs(_ line: String) -> String {
        guard line.hasPrefix("\t") || line.hasPrefix(" ") else { return line }
        var result = ""
        var column = 0
        var rest = line[...]
        while let character = rest.first, character == "\t" || character == " " {
            let width = character == "\t" ? 4 - column % 4 : 1
            result += String(repeating: " ", count: width)
            column += width
            rest = rest.dropFirst()
        }
        return result + rest
    }
}
