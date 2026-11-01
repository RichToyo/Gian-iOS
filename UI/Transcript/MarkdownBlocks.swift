import Foundation

/// Deterministic block-level Markdown splitter for transcript rendering.
///
/// Presentation-only: inline emphasis/links are delegated to
/// `AttributedString(markdown:)`; this parser handles block structure
/// (headings, fenced code, tables, lists, quotes) so each block maps to a
/// native view. Remote payloads are untrusted — parsing never evaluates
/// content and unknown structures degrade to plain paragraphs.
enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, code: String)
    case table(headers: [String], rows: [[String]])
    case list(ordered: Bool, items: [String])
    case blockquote(String)
    case thematicBreak
}

enum MarkdownBlockParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var index = 0

        func flushParagraph(_ buffer: inout [String]) {
            let text = buffer.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(.paragraph(text))
            }
            buffer.removeAll()
        }

        var paragraph: [String] = []

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if trimmed.hasPrefix("```") {
                flushParagraph(&paragraph)
                let language = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                index += 1 // consume closing fence
                blocks.append(.code(
                    language: language.isEmpty ? nil : language,
                    code: code.joined(separator: "\n")
                ))
                continue
            }

            // Blank line ends a paragraph
            if trimmed.isEmpty {
                flushParagraph(&paragraph)
                index += 1
                continue
            }

            // Thematic break
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph(&paragraph)
                blocks.append(.thematicBreak)
                index += 1
                continue
            }

            // Heading
            if let heading = parseHeading(trimmed) {
                flushParagraph(&paragraph)
                blocks.append(heading)
                index += 1
                continue
            }

            // Table: header row followed by a delimiter row
            if trimmed.hasPrefix("|"), index + 1 < lines.count,
               isTableDelimiter(lines[index + 1]) {
                flushParagraph(&paragraph)
                let headers = splitTableRow(trimmed)
                index += 2
                var rows: [[String]] = []
                while index < lines.count,
                      lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(splitTableRow(lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                flushParagraph(&paragraph)
                var quote: [String] = []
                while index < lines.count,
                      lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(
                        String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst())
                            .trimmingCharacters(in: .whitespaces)
                    )
                    index += 1
                }
                blocks.append(.blockquote(quote.joined(separator: "\n")))
                continue
            }

            // List item
            if let listItem = parseListItem(trimmed) {
                flushParagraph(&paragraph)
                let ordered = listItem.ordered
                var items = [listItem.text]
                index += 1
                while index < lines.count,
                      let next = parseListItem(lines[index].trimmingCharacters(in: .whitespaces)),
                      next.ordered == ordered {
                    items.append(next.text)
                    index += 1
                }
                blocks.append(.list(ordered: ordered, items: items))
                continue
            }

            paragraph.append(line)
            index += 1
        }
        flushParagraph(&paragraph)
        return blocks
    }

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        var level = 0
        for character in line {
            if character == "#" { level += 1 } else { break }
        }
        guard level > 0, level <= 6,
              line.count > level,
              line[line.index(line.startIndex, offsetBy: level)] == " "
        else { return nil }
        return .heading(
            level: level,
            text: String(line.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
        )
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return false }
        return splitTableRow(trimmed).allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var row = line
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseListItem(_ line: String) -> (ordered: Bool, text: String)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return (false, String(line.dropFirst(2)))
        }
        // Ordered: "1. text"
        var digits = ""
        var cursor = line.startIndex
        while cursor < line.endIndex, line[cursor].isNumber {
            digits.append(line[cursor])
            cursor = line.index(after: cursor)
        }
        guard !digits.isEmpty, cursor < line.endIndex, line[cursor] == "." else { return nil }
        let afterDot = line.index(after: cursor)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        return (true, String(line[line.index(after: afterDot)...]))
    }
}
