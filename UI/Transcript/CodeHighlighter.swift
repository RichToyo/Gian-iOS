import SwiftUI

/// Light syntax colouring for code blocks: comments, strings, numbers and the
/// common languages' keywords. One linear pass, no grammar; an unknown
/// language still gets strings, numbers and comments. Results are cached by
/// source, and very long blocks stay plain.
enum CodeHighlighter {
    static let limit = 30_000

    @MainActor private static var cache = RecentCache<AttributedString>(entries: 256, bytes: 2 * 1024 * 1024)

    @MainActor
    static func highlighted(_ code: String, language: String?) -> AttributedString {
        let key = (language ?? "") + "\u{0}" + code
        if let cached = cache[key] { return cached }
        let result = highlight(code, language: language)
        cache.insert(result, for: key)
        return result
    }

    enum Token: Equatable { case plain, keyword, string, comment, number, type }

    static func highlight(_ code: String, language: String?) -> AttributedString {
        guard code.utf16.count <= limit else { return AttributedString(code) }
        var result = AttributedString()
        for (text, token) in tokens(code, language: language) {
            var run = AttributedString(text)
            if let color = color(token) { run.foregroundColor = color }
            result.append(run)
        }
        return result
    }

    static func tokens(_ code: String, language: String?) -> [(String, Token)] {
        let family = Family(language)
        let characters = Array(code)
        var tokens: [(String, Token)] = []
        var plain = ""
        var index = 0

        func flushPlain() {
            if !plain.isEmpty { tokens.append((plain, .plain)); plain = "" }
        }
        func take(_ count: Int, as token: Token) {
            flushPlain()
            let end = min(characters.count, index + count)
            tokens.append((String(characters[index..<end]), token))
            index = end
        }
        func starts(_ prefix: String) -> Bool {
            var position = index
            for character in prefix {
                guard position < characters.count, characters[position] == character else { return false }
                position += 1
            }
            return true
        }

        while index < characters.count {
            let character = characters[index]
            // Comments.
            if family.lineComments.contains(where: starts) {
                var end = index
                while end < characters.count, characters[end] != "\n" { end += 1 }
                take(end - index, as: .comment)
                continue
            }
            if family.blockComments, starts("/*") {
                var end = index + 2
                while end < characters.count, !(characters[end] == "*" && end + 1 < characters.count && characters[end + 1] == "/") { end += 1 }
                take(min(characters.count, end + 2) - index, as: .comment)
                continue
            }
            // Strings (single line, with escapes; backticks span lines).
            if family.quotes.contains(character) {
                var end = index + 1
                while end < characters.count, characters[end] != character {
                    if characters[end] == "\\" { end += 1 } else if characters[end] == "\n", character != "`" { break }
                    end += 1
                }
                take(min(characters.count, end + 1) - index, as: .string)
                continue
            }
            // Numbers (not inside identifiers).
            // (Digits inside identifiers are taken with the word below.)
            if character.isNumber, character.isASCII {
                var end = index + 1
                while end < characters.count, characters[end].isHexDigit || characters[end] == "." || characters[end] == "_" || characters[end] == "x" { end += 1 }
                take(end - index, as: .number)
                continue
            }
            // Words: keywords and type names.
            if character.isLetter || character == "_" || character == "$" || (character == "@" && family.attributes) || (character == "#" && family.directives) {
                var end = index + 1
                while end < characters.count, characters[end].isLetter || characters[end].isNumber || characters[end] == "_" || characters[end] == "$" { end += 1 }
                let word = String(characters[index..<end])
                if (plain.last == "." && family != .shell) {
                    plain += word; index = end
                } else if family.keywords.contains(word) || character == "@" || character == "#" {
                    take(end - index, as: .keyword)
                } else if family.typesCapitalized, character.isUppercase, word.count > 1 {
                    take(end - index, as: .type)
                } else {
                    plain += word; index = end
                }
                continue
            }
            plain.append(character)
            index += 1
        }
        flushPlain()
        return tokens
    }

    private static func color(_ token: Token) -> Color? {
        switch token {
        case .plain: nil
        case .keyword: Color(light: 0xAD3DA4, dark: 0xFF7AB2)
        case .string: Color(light: 0xC41A16, dark: 0xFC6A5D)
        case .comment: Color(light: 0x707F8C, dark: 0x7F8C98)
        case .number: Color(light: 0x1C00CF, dark: 0xD9C97C)
        case .type: Color(light: 0x0B4F79, dark: 0x5DD8FF)
        }
    }

    enum Family: Equatable {
        case cLike, python, shell, ruby, sql, data, markup, unknown

        init(_ language: String?) {
            switch language?.lowercased() ?? "" {
            case "swift", "js", "javascript", "jsx", "ts", "typescript", "tsx", "go", "golang", "rust", "rs", "java",
                 "kotlin", "kt", "c", "h", "cpp", "c++", "cc", "hpp", "objc", "objective-c", "cs", "csharp", "dart", "scala", "php":
                self = .cLike
            case "python", "py": self = .python
            case "sh", "bash", "zsh", "shell", "console", "fish", "ps1", "powershell", "dockerfile", "make", "makefile": self = .shell
            case "ruby", "rb": self = .ruby
            case "sql", "postgresql", "mysql", "sqlite": self = .sql
            case "json", "jsonc", "yaml", "yml", "toml", "ini": self = .data
            case "html", "xml", "svg", "css", "scss", "md", "markdown": self = .markup
            default: self = .unknown
            }
        }

        var lineComments: [String] {
            switch self {
            case .cLike: ["//"]
            case .python, .shell, .ruby: ["#"]
            case .sql: ["--"]
            case .data: ["#", "//"]
            case .markup: []
            case .unknown: ["//", "# "]
            }
        }

        var blockComments: Bool { self == .cLike || self == .sql || self == .markup || self == .unknown }
        var quotes: Set<Character> {
            switch self {
            case .cLike: ["\"", "'", "`"]
            case .shell, .python, .ruby, .sql, .data, .unknown: ["\"", "'"]
            case .markup: ["\""]
            }
        }
        var attributes: Bool { self == .cLike || self == .python }
        var directives: Bool { self == .cLike }
        var typesCapitalized: Bool { self == .cLike || self == .python || self == .ruby }

        var keywords: Set<String> {
            switch self {
            case .cLike: Self.cLikeKeywords
            case .python: ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "None", "True",
                           "False", "import", "from", "as", "with", "try", "except", "finally", "raise", "lambda", "yield", "async",
                           "await", "pass", "break", "continue", "global", "nonlocal", "assert", "del", "self", "match", "case"]
            case .shell: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac", "function",
                          "return", "export", "local", "readonly", "set", "unset", "echo", "cd", "exit", "source", "sudo"]
            case .ruby: ["def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "until", "for", "in", "do", "return",
                         "yield", "self", "nil", "true", "false", "require", "include", "attr_accessor", "begin", "rescue", "ensure"]
            case .sql: Set(["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete",
                            "create", "table", "index", "drop", "alter", "join", "left", "right", "inner", "outer", "on", "as",
                            "group", "by", "order", "limit", "having", "null", "is", "in", "primary", "key", "references",
                            "distinct", "union", "all", "case", "when", "then", "else", "end", "with"].flatMap { [$0, $0.uppercased()] })
            case .data: ["true", "false", "null", "yes", "no"]
            case .markup, .unknown: Self.cLikeKeywords.intersection(["true", "false", "null", "nil", "return", "if", "else", "for", "function", "let", "var", "const"])
            }
        }

        private static let cLikeKeywords: Set<String> = [
            "func", "let", "var", "if", "else", "guard", "return", "for", "while", "in", "switch", "case", "default", "break", "continue",
            "struct", "class", "enum", "protocol", "extension", "import", "public", "private", "internal", "fileprivate", "static",
            "final", "init", "deinit", "self", "Self", "super", "nil", "true", "false", "throw", "throws", "try", "catch", "async",
            "await", "some", "any", "where", "do", "repeat", "defer", "inout", "mutating", "override", "weak", "lazy", "typealias",
            "function", "const", "new", "this", "null", "undefined", "typeof", "instanceof", "export", "from", "as", "interface",
            "type", "implements", "extends", "package", "void", "int", "long", "double", "float", "bool", "boolean", "char",
            "string", "fn", "mut", "impl", "trait", "pub", "use", "mod", "match", "loop", "go", "chan", "select", "defer",
            "map", "range", "val", "fun", "object", "when", "is", "abstract", "yield", "delete", "of", "readonly", "declare",
            "namespace", "unsafe", "crate", "dyn", "move", "ref", "where", "goto", "sizeof", "union", "unsigned", "signed",
        ]
    }
}
