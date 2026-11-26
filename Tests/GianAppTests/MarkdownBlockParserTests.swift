import XCTest
@testable import Gian

/// Block structure as Agents write it: lists were numbered by position and
/// split by every blank line ("1. 1. 1."), nesting was flattened, and tables
/// needed a leading pipe.
final class MarkdownBlockParserTests: XCTestCase {
    private func list(_ blocks: [MarkdownBlock], _ index: Int = 0) -> MarkdownList? {
        guard index < blocks.count, case .list(let list) = blocks[index] else { return nil }
        return list
    }

    func testLooseOrderedListStaysOneList() {
        let blocks = MarkdownBlockParser.parse("1. **First**\n\n   Why it matters.\n\n2. Second\n\n3. Third")
        XCTAssertEqual(blocks.count, 1)
        let parsed = list(blocks)
        XCTAssertEqual(parsed?.items.count, 3)
        XCTAssertEqual(parsed?.items[0].blocks, [.paragraph("**First**"), .paragraph("Why it matters.")])
    }

    func testOrderedListKeepsItsStartNumber() {
        let blocks = MarkdownBlockParser.parse("Intro\n\n3. Third\n4. Fourth")
        XCTAssertEqual(list(blocks, 1)?.start, 3)
        XCTAssertEqual(list(blocks, 1)?.items.count, 2)
    }

    func testNestedListsNest() {
        let blocks = MarkdownBlockParser.parse("- Parent\n  - Child one\n  - Child two\n- Sibling")
        let parsed = list(blocks)
        XCTAssertEqual(parsed?.items.count, 2)
        guard let first = parsed?.items[0].blocks, first.count == 2, case .list(let child) = first[1] else {
            return XCTFail("expected a nested list, got \(String(describing: parsed))")
        }
        XCTAssertEqual(child.items.count, 2)
        XCTAssertFalse(child.ordered)
    }

    func testFourSpaceNestingUnderANumberedItem() {
        let blocks = MarkdownBlockParser.parse("1. Step\n    - detail\n2. Next")
        XCTAssertEqual(list(blocks)?.items.count, 2)
        guard let first = list(blocks)?.items[0].blocks, case .list = first.last else { return XCTFail("nested bullets lost") }
    }

    func testLazyContinuationAndCodeInsideAnItem() {
        let blocks = MarkdownBlockParser.parse("- Run this\nnext line\n\n  ```sh\n  make test\n  ```\n- Done")
        let items = list(blocks)?.items
        XCTAssertEqual(items?.count, 2)
        XCTAssertEqual(items?[0].blocks, [.paragraph("Run this\nnext line"), .code(language: "sh", code: "make test")])
    }

    func testListUnderAParagraphWithoutABlankLine() {
        let blocks = MarkdownBlockParser.parse("Steps:\n1. One\n2. Two")
        XCTAssertEqual(blocks.first, .paragraph("Steps:"))
        XCTAssertEqual(list(blocks, 1)?.items.count, 2)
    }

    func testTaskListItems() {
        let items = list(MarkdownBlockParser.parse("- [x] Shipped\n- [ ] Pending"))?.items
        XCTAssertEqual(items?.map(\.checked), [true, false])
        XCTAssertEqual(items?[0].blocks, [.paragraph("Shipped")])
    }

    func testBulletsAndNumbersAreSeparateLists() {
        let blocks = MarkdownBlockParser.parse("- a\n- b\n1. c")
        XCTAssertEqual(blocks.count, 2)
    }

    func testTableWithoutOuterPipesAlignmentsAndEscapes() {
        let blocks = MarkdownBlockParser.parse("Name | Count | Note\n:--- | ---: | :---:\nA \\| B | 3 | ok\nshort | 1")
        XCTAssertEqual(blocks, [.table(headers: ["Name", "Count", "Note"], alignments: [.leading, .trailing, .center],
                                       rows: [["A | B", "3", "ok"], ["short", "1", ""]])])
    }

    func testTableRightUnderAParagraph() {
        let blocks = MarkdownBlockParser.parse("Results:\n| A | B |\n|---|---|\n| 1 | 2 |")
        XCTAssertEqual(blocks.count, 2)
        guard case .table(let headers, _, let rows) = blocks[1] else { return XCTFail() }
        XCTAssertEqual(headers, ["A", "B"])
        XCTAssertEqual(rows, [["1", "2"]])
    }

    func testFencesTildesAndInnerBackticks() {
        XCTAssertEqual(MarkdownBlockParser.parse("~~~python\nprint(1)\n~~~"), [.code(language: "python", code: "print(1)")])
        XCTAssertEqual(MarkdownBlockParser.parse("````md\n```js\nx\n```\n````"), [.code(language: "md", code: "```js\nx\n```")])
        // A line that only starts with backticks doesn't close the block.
        XCTAssertEqual(MarkdownBlockParser.parse("```\na\n```not a fence\nb\n```"), [.code(language: nil, code: "a\n```not a fence\nb")])
    }

    func testUnclosedFenceRunsToTheEnd() {
        XCTAssertEqual(MarkdownBlockParser.parse("```swift\nlet a = 1"), [.code(language: "swift", code: "let a = 1")])
    }

    func testThematicBreakForms() {
        for source in ["---", "----", "- - -", "***", "_ _ _"] {
            XCTAssertEqual(MarkdownBlockParser.parse(source), [.thematicBreak], source)
        }
        XCTAssertEqual(MarkdownBlockParser.parse("***bold***"), [.paragraph("***bold***")])
    }

    func testHeadingsAndQuotes() {
        XCTAssertEqual(MarkdownBlockParser.parse("## Title ##"), [.heading(level: 2, text: "Title")])
        XCTAssertEqual(MarkdownBlockParser.parse("#hashtag"), [.paragraph("#hashtag")])
        XCTAssertEqual(MarkdownBlockParser.parse("> quoted\n> - item"),
                       [.blockquote([.paragraph("quoted"), .list(MarkdownList(ordered: false, start: 0,
                                                                              items: [.init(blocks: [.paragraph("item")])]))])])
    }

    func testDeepNestingIsBounded() {
        let source = String(repeating: ">", count: 200) + " deep"
        XCTAssertFalse(MarkdownBlockParser.parse(source).isEmpty)
    }
}
