import Foundation

/// Inline Markdown (emphasis, code, links, strikethrough) as Gian renders it.
///
/// Foundation's parser applies CommonMark's emphasis rules, which leave the
/// asterisks of `**注意：**这里` or `说明**（重要）**内容` on screen: a closing
/// `**` after punctuation must be followed by a space or punctuation, and an
/// opening one before punctuation must follow one. Gian's chat parses with
/// remark-cjk-friendly instead, where CJK punctuation counts as an ordinary
/// character and a CJK neighbour lets a run open or close. Emphasis (`*`, `_`)
/// is matched here by those rules and handed to Foundation as private-use
/// markers that become the emphasis afterwards; code, links and the rest stay
/// Foundation's.
enum InlineMarkdown {
    static func attributed(_ text: String) -> AttributedString? {
        var options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        options.allowsExtendedAttributes = true
        let marked = EmphasisMarkers.mark(text)
        guard var attributed = try? AttributedString(markdown: marked ?? text, options: options) else { return nil }
        if marked != nil { EmphasisMarkers.apply(to: &attributed) }
        return attributed
    }
}

enum EmphasisMarkers {
    private enum Kind {
        case strong, emphasis

        var intent: InlinePresentationIntent { self == .strong ? .stronglyEmphasized : .emphasized }
        var open: Unicode.Scalar { self == .strong ? "\u{E000}" : "\u{E002}" }
        var close: Unicode.Scalar { self == .strong ? "\u{E001}" : "\u{E003}" }

        init?(marker: Unicode.Scalar) {
            switch marker.value {
            case 0xE000, 0xE001: self = .strong
            case 0xE002, 0xE003: self = .emphasis
            default: return nil
            }
        }
    }

    private static let markerRange: ClosedRange<UInt32> = 0xE000...0xE003

    private struct Run {
        let start: Int
        let length: Int
        let marker: Unicode.Scalar
        let canOpen: Bool
        let canClose: Bool
        var remaining: Int
        /// False once inside a matched pair: what is left of it stays literal.
        var active = true
        /// Pairs this run closed, from its start, in the order they matched.
        var closes: [Kind] = []
        /// Pairs this run opened, from its end, in the order they matched.
        var opens: [Kind] = []
    }

    /// The source with matched emphasis delimiters replaced by markers, or nil
    /// when nothing matches (Foundation's own reading then stands).
    static func mark(_ text: String) -> String? {
        guard text.unicodeScalars.contains(where: { $0 == "*" || $0 == "_" }),
              !text.unicodeScalars.contains(where: { markerRange.contains($0.value) }) else { return nil }
        let scalars = Array(text.unicodeScalars)
        var runs = delimiterRuns(scalars)
        match(&runs)
        guard runs.contains(where: { !$0.opens.isEmpty }) else { return nil }
        var result = String.UnicodeScalarView()
        var index = 0
        var nextRun = 0
        while index < scalars.count {
            if nextRun < runs.count, runs[nextRun].start == index {
                let run = runs[nextRun]
                for kind in run.closes { result.append(kind.close) }
                for _ in 0..<run.remaining { result.append(run.marker) }
                for kind in run.opens.reversed() { result.append(kind.open) }
                index += run.length
                nextRun += 1
            } else {
                result.append(scalars[index])
                index += 1
            }
        }
        return String(result)
    }

    /// Turns the markers Foundation passed through into emphasis.
    static func apply(to attributed: inout AttributedString) {
        let scalars = Array(attributed.unicodeScalars)
        var open: [(kind: Kind, offset: Int)] = []
        var spans: [(kind: Kind, range: Range<Int>)] = []
        var markers: [Int] = []
        for (offset, scalar) in scalars.enumerated() {
            guard let kind = Kind(marker: scalar) else { continue }
            markers.append(offset)
            if scalar == kind.open {
                open.append((kind, offset))
            } else if let last = open.lastIndex(where: { $0.kind == kind }) {
                spans.append((kind, open[last].offset + 1..<offset))
                open.remove(at: last)
            }
        }
        func index(_ offset: Int) -> AttributedString.Index {
            attributed.unicodeScalars.index(attributed.startIndex, offsetBy: offset)
        }
        for span in spans where !span.range.isEmpty {
            let bounds = index(span.range.lowerBound)..<index(span.range.upperBound)
            let runs = attributed[bounds].runs.map { ($0.range, $0.inlinePresentationIntent ?? []) }
            for (range, intent) in runs {
                attributed[range].inlinePresentationIntent = intent.union(span.kind.intent)
            }
        }
        for offset in markers.reversed() {
            let start = index(offset)
            attributed.removeSubrange(start..<attributed.unicodeScalars.index(after: start))
        }
        // A marker right after a bare URL is read as part of its link.
        for (link, range) in attributed.runs[\.link].reversed() {
            guard let link else { continue }
            let cleaned = ["%EE%80%80", "%EE%80%81", "%EE%80%82", "%EE%80%83"]
                .reduce(link.absoluteString) { $0.replacingOccurrences(of: $1, with: "") }
            if cleaned != link.absoluteString { attributed[range].link = URL(string: cleaned) }
        }
    }

    // MARK: - Delimiter runs

    private static func delimiterRuns(_ s: [Unicode.Scalar]) -> [Run] {
        var runs: [Run] = []
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == "\\" {
                i += i + 1 < s.count && isASCIIPunctuation(s[i + 1]) ? 2 : 1
            } else if c == "`" {
                i = afterCodeSpan(s, from: i)
            } else if c == "]", i + 1 < s.count, s[i + 1] == "(", let end = closingParenthesis(s, from: i + 1) {
                i = end + 1
            } else if c == "<", let end = autolinkEnd(s, from: i) {
                i = end + 1
            } else if let end = bareURLEnd(s, from: i) {
                i = end
            } else if c == "*" || c == "_" {
                var end = i
                while end < s.count, s[end] == c { end += 1 }
                let (open, close) = flanking(s, start: i, end: end, marker: c)
                runs.append(Run(start: i, length: end - i, marker: c, canOpen: open, canClose: close, remaining: end - i))
                i = end
            } else {
                i += 1
            }
        }
        return runs
    }

    /// micromark's emphasis resolution (which Gian's parser uses): each closer,
    /// in order, takes the nearest open run of its marker, two at a time when
    /// both have two; runs between a matched pair stay literal.
    private static func match(_ runs: inout [Run]) {
        for closer in runs.indices where runs[closer].canClose {
            while runs[closer].remaining > 0 {
                var found: Int?
                var candidate = closer - 1
                while candidate >= 0 {
                    let opener = runs[candidate]
                    if opener.active, opener.canOpen, opener.remaining > 0, opener.marker == runs[closer].marker {
                        let lengths = opener.remaining + runs[closer].remaining
                        let ruleOfThree = (opener.canClose || runs[closer].canOpen)
                            && runs[closer].remaining % 3 != 0 && lengths % 3 == 0
                        if !ruleOfThree { found = candidate; break }
                    }
                    candidate -= 1
                }
                guard let opener = found else { break }
                let kind: Kind = runs[opener].remaining > 1 && runs[closer].remaining > 1 ? .strong : .emphasis
                let used = kind == .strong ? 2 : 1
                runs[opener].remaining -= used
                runs[opener].opens.append(kind)
                runs[closer].remaining -= used
                runs[closer].closes.append(kind)
                for inner in (opener + 1)..<closer { runs[inner].active = false }
            }
        }
    }

    /// remark-cjk-friendly's flanking rules.
    private static func flanking(_ s: [Unicode.Scalar], start: Int, end: Int, marker: Unicode.Scalar) -> (open: Bool, close: Bool) {
        let previous = start > 0 ? s[start - 1] : nil
        let next = end < s.count ? s[end] : nil
        let before = precedingClass(s, before: start)
        let after = CharacterClass(next)
        let beforeCoreMarker = previous == "*" || previous == "_"
        let afterCoreMarker = next == "*" || next == "_"
        let beforeSpaceOrNonCJKPunctuation = before.isNonCJKPunctuation || before.whitespace || beforeCoreMarker
        let afterSpaceOrNonCJKPunctuation = after.isNonCJKPunctuation || after.whitespace || afterCoreMarker
        let open = !afterSpaceOrNonCJKPunctuation
            || (after.isNonCJKPunctuation && (beforeSpaceOrNonCJKPunctuation || before.cjk || before.ideographicVariation))
            || next == "~"
        let close = !beforeSpaceOrNonCJKPunctuation
            || (before.isNonCJKPunctuation && (afterSpaceOrNonCJKPunctuation || after.cjk))
            || previous == "~"
        if marker == "*" { return (open, close) }
        return (open && (before.isSpaceOrPunctuation || !close), close && (after.isSpaceOrPunctuation || !open))
    }

    private struct CharacterClass {
        var whitespace = false
        var punctuation = false
        var cjk = false
        var ideographicVariation = false
        /// A text-presentation variation selector, classified by what it follows.
        var variationSelector = false

        var isNonCJKPunctuation: Bool { punctuation && !cjk }
        var isSpaceOrPunctuation: Bool { whitespace || punctuation }

        init(whitespace: Bool = false, punctuation: Bool = false, cjk: Bool = false) {
            self.whitespace = whitespace
            self.punctuation = punctuation
            self.cjk = cjk
        }

        init(_ scalar: Unicode.Scalar?) {
            guard let scalar else { whitespace = true; return }
            let value = scalar.value
            if scalar.properties.isWhitespace || value == 0xFEFF { whitespace = true; return }
            if value >= 0x1100 {
                if (0xFE00...0xFE0E).contains(value) { variationSelector = true; return }
                if (0xE0100...0xE01EF).contains(value) { ideographicVariation = true; return }
                cjk = EmphasisMarkers.isWide(value) && !scalar.properties.isEmojiPresentation
            }
            punctuation = EmphasisMarkers.isPunctuation(scalar)
        }
    }

    /// The character before a run; a variation selector reads as the character
    /// it modifies (a curly quote with U+FE01 is CJK punctuation).
    private static func precedingClass(_ s: [Unicode.Scalar], before start: Int) -> CharacterClass {
        let previous = start > 0 ? s[start - 1] : nil
        let before = CharacterClass(previous)
        guard before.variationSelector, let selector = previous else { return before }
        let twoPrevious = start > 1 ? s[start - 2] : nil
        let twoBefore = CharacterClass(twoPrevious)
        guard let twoPrevious, !twoBefore.whitespace else { return before }
        if selector.value == 0xFE01, [0x2018, 0x2019, 0x201C, 0x201D].contains(twoPrevious.value) {
            return CharacterClass(punctuation: true, cjk: true)
        }
        var stripped = twoBefore
        stripped.ideographicVariation = false
        return stripped
    }

    /// East Asian Width Fullwidth, Halfwidth or Wide, or Hangul.
    fileprivate static func isWide(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x11FF, 0x2329...0x232A, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
             0x4DC0...0x9FFF, 0xA000...0xA4CF, 0xA960...0xA97F, 0xAC00...0xD7FF, 0xF900...0xFAFF,
             0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFFEE, 0x16FE0...0x18D8F, 0x1AFF0...0x1B2FF,
             0x1F200...0x1F2FF, 0x20000...0x2FFFD, 0x30000...0x3FFFD:
            true
        default:
            false
        }
    }

    fileprivate static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            true
        default:
            false
        }
    }

    private static func isASCIIPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && isPunctuation(scalar)
    }

    // MARK: - Spans emphasis doesn't reach into

    /// After a code span opened at `start`, or after its backticks when nothing
    /// closes it (they are then literal).
    private static func afterCodeSpan(_ s: [Unicode.Scalar], from start: Int) -> Int {
        var end = start
        while end < s.count, s[end] == "`" { end += 1 }
        let length = end - start
        var cursor = end
        while cursor < s.count {
            guard s[cursor] == "`" else { cursor += 1; continue }
            var closing = cursor
            while closing < s.count, s[closing] == "`" { closing += 1 }
            if closing - cursor == length { return closing }
            cursor = closing
        }
        return end
    }

    /// The `)` closing a link destination that opens at `open`.
    private static func closingParenthesis(_ s: [Unicode.Scalar], from open: Int) -> Int? {
        var depth = 0
        var cursor = open
        while cursor < s.count {
            let c = s[cursor]
            if c == "\\" { cursor += 2; continue }
            if c == "\n" { return nil }
            if c == "(" { depth += 1 }
            if c == ")" { depth -= 1; if depth == 0 { return cursor } }
            cursor += 1
        }
        return nil
    }

    /// The `>` of `<scheme:…>` or `<name@host>`.
    private static func autolinkEnd(_ s: [Unicode.Scalar], from open: Int) -> Int? {
        var cursor = open + 1
        var looksLikeLink = false
        while cursor < s.count {
            let c = s[cursor]
            if c == ">" { return looksLikeLink ? cursor : nil }
            if c == "<" || c.properties.isWhitespace { return nil }
            if c == ":" || c == "@" { looksLikeLink = true }
            cursor += 1
        }
        return nil
    }

    /// The end of a bare URL Foundation will link, without the trailing
    /// punctuation it leaves out.
    private static func bareURLEnd(_ s: [Unicode.Scalar], from start: Int) -> Int? {
        guard s[start] == "h" || s[start] == "w" else { return nil }
        if start > 0, s[start - 1].properties.isAlphabetic || ("0"..."9").contains(s[start - 1]) { return nil }
        for prefix in ["https://", "http://", "www."] {
            let scalars = Array(prefix.unicodeScalars)
            guard start + scalars.count <= s.count, Array(s[start..<start + scalars.count]) == scalars else { continue }
            var end = start + scalars.count
            while end < s.count, !s[end].properties.isWhitespace, s[end] != "<" { end += 1 }
            while end > start + scalars.count, "?!.,:*_~".unicodeScalars.contains(s[end - 1]) { end -= 1 }
            return end
        }
        return nil
    }
}
