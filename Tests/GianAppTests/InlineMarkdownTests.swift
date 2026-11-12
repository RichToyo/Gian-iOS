import XCTest
@testable import Gian

/// Emphasis follows Gian's chat (remark-cjk-friendly): CJK punctuation inside
/// the asterisks or a CJK neighbour outside them no longer leaves `**` showing.
final class InlineMarkdownTests: XCTestCase {
    func testBoldEndingInCJKPunctuationBeforeText() {
        XCTAssertEqual(render("**注意：**这里是说明"), "[B:注意：]这里是说明")
        XCTAssertEqual(render("**“引用”**后面"), "[B:“引用”]后面")
        XCTAssertEqual(render("说明**（重要）**内容"), "说明[B:（重要）]内容")
        XCTAssertEqual(render("*斜体：*文字"), "[I:斜体：]文字")
    }

    func testSeveralBoldLabelsInOneParagraph() {
        XCTAssertEqual(render("**优点：**速度快，**缺点：**内存大"), "[B:优点：]速度快，[B:缺点：]内存大")
        XCTAssertEqual(render("**注意：**这里**重要**"), "[B:注意：]这里[B:重要]")
        XCTAssertEqual(render("**粗体\n跨行：**文字"), "[B:粗体\n跨行：]文字")
    }

    func testOrdinaryEmphasisIsUnchanged() {
        XCTAssertEqual(render("**bold** text"), "[B:bold] text")
        XCTAssertEqual(render("这是**粗体**文字"), "这是[B:粗体]文字")
        XCTAssertEqual(render("**加粗**，然后"), "[B:加粗]，然后")
        XCTAssertEqual(render("***both***"), "[B,I:both]")
        XCTAssertEqual(render("**_x_**"), "[B,I:x]")
        XCTAssertEqual(render("snake_case_name and __init__"), "snake_case_name and [B:init]")
        // As in Gian: without a CJK neighbour, CommonMark's rule stands.
        XCTAssertEqual(render("**Note:**text"), "**Note:**text")
    }

    func testEmphasisCombinesWithCodeLinksAndStrikethrough() {
        XCTAssertEqual(render("使用 **`code`** 包裹"), "使用 [B,C:code] 包裹")
        XCTAssertEqual(render("[**链接**](https://x.com)：说明"), "[B,L=https://x.com:链接]：说明")
        XCTAssertEqual(render("~~**x**~~ and **~~y~~**"), "[B,S:x] and [B,S:y]")
    }

    func testLiteralAsterisksStayLiteral() {
        XCTAssertEqual(render("`**not bold**` here"), "[C:**not bold**] here")
        XCTAssertEqual(render("a\\*\\*b\\*\\* c"), "a**b** c")
        XCTAssertEqual(render("func(**kwargs)"), "func(**kwargs)")
        XCTAssertEqual(render("**unfinished"), "**unfinished")
        XCTAssertEqual(render("2 * 3 * 4"), "2 * 3 * 4")
    }

    func testLinksKeepTheirAddresses() {
        XCTAssertEqual(render("see https://a.com/x_y_z ok"), "see [L=https://a.com/x_y_z:https://a.com/x_y_z] ok")
        XCTAssertEqual(render("<https://x.com/**a**> **b**"), "[L=https://x.com/**a**:https://x.com/**a**] [B:b]")
    }

    func testTableCellsRenderInlineMarkdown() {
        XCTAssertEqual(MarkdownBlockParser.parse("| A | B |\n|---|---|\n| **注意：**值 | `x` |"),
                       [.table(headers: ["A", "B"], rows: [["**注意：**值", "`x`"]])])
        XCTAssertEqual(render("**注意：**值"), "[B:注意：]值")
    }

    /// A full cache forgets what wasn't used lately, never everything at once
    /// (which re-parsed everything on screen in one frame).
    func testRecentCacheForgetsOnlyWhatWasNotUsedLately() {
        var cache = RecentCache<Int>(entries: 3, bytes: 1_000)
        cache.insert(1, for: "a"); cache.insert(2, for: "b"); cache.insert(3, for: "c")
        cache.insert(4, for: "d")
        XCTAssertEqual(cache["a"], 1, "still there after the cache filled")
        cache.insert(5, for: "e"); cache.insert(6, for: "f")
        XCTAssertNil(cache["b"])
        XCTAssertNil(cache["c"])
        XCTAssertEqual(cache["a"], 1)
        XCTAssertEqual(cache["d"], 4)
        XCTAssertEqual(cache["f"], 6)
        cache.remove("f")
        XCTAssertNil(cache["f"])
    }

    /// Runs as `[B,I,C,S,L=url:text]`, plain text as is.
    private func render(_ source: String) -> String {
        guard let attributed = InlineMarkdown.attributed(source) else { return "<unparsed>" }
        var output = ""
        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            var tags: [String] = []
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { tags.append("B") }
                if intent.contains(.emphasized) { tags.append("I") }
                if intent.contains(.code) { tags.append("C") }
                if intent.contains(.strikethrough) { tags.append("S") }
            }
            if let link = run.link { tags.append("L=\(link.absoluteString)") }
            output += tags.isEmpty ? text : "[\(tags.joined(separator: ",")):\(text)]"
        }
        return output
    }
}
