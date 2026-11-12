import XCTest
@testable import GianCore
@testable import Gian

final class TranscriptPacingTests: XCTestCase {
    private let session = SessionID(rawValue: "session-1")!
    private let other = SessionID(rawValue: "session-2")!
    private var clock = 0

    func testOpeningAConversationShowsEverythingAtOnce() {
        var pacing = TranscriptPacing()
        let items = [user("u1"), assistant("a1", "Done.", turn: 1)]
        let shown = pacing.visible(items, session: session, interactions: [])
        XCTAssertEqual(shown.items, items)
        XCTAssertFalse(shown.waiting)
    }

    func testNewTextIsRevealedInBreaksUntilAllOfItShows() {
        var pacing = TranscriptPacing()
        let opening = [user("u1")]
        _ = pacing.visible(opening, session: session, interactions: [])
        let text = "我先看一下系泊日志的结构，再检查缆绳告警的记录。找到了两个日志文件，主日志和告警日志。接下来搜索最近一周的张力告警，然后给出结论！"
        let items = opening + [assistant("a1", text, turn: 1), turnEnd("end", turn: 1)]
        var shown = pacing.visible(items, session: session, interactions: [])
        XCTAssertEqual(shown.items.count, 1, "new text waits for its first step")
        XCTAssertTrue(shown.waiting)
        var revealed: [String] = []
        var steps = 0
        while shown.waiting, steps < 40 {
            pacing.advance(items)
            steps += 1
            shown = pacing.visible(items, session: session, interactions: [])
            if let last = shown.items.compactMap(\.assistantText).last, last != revealed.last { revealed.append(last) }
        }
        XCTAssertFalse(shown.waiting)
        XCTAssertEqual(shown.items, items)
        XCTAssertGreaterThan(revealed.count, 2, "revealed in several steps")
        for (earlier, later) in zip(revealed, revealed.dropFirst()) { XCTAssertTrue(later.hasPrefix(earlier)) }
        for step in revealed.dropLast() {
            XCTAssertTrue("，。！".contains(step.last!), "a step ends at a break: \(step)")
        }
        XCTAssertLessThanOrEqual(steps, TranscriptPacing.catchUpSteps + 4)
    }

    func testALargeBacklogClearsInAboutASecond() {
        var pacing = TranscriptPacing()
        _ = pacing.visible([user("u1")], session: session, interactions: [])
        let text = String(repeating: "A sentence of moderate length, with a clause. ", count: 80)
        let items = [user("u1"), assistant("a1", text, turn: 1), turnEnd("end", turn: 1)]
        var steps = 0
        while pacing.visible(items, session: session, interactions: []).waiting, steps < 100 {
            pacing.advance(items)
            steps += 1
        }
        XCTAssertLessThanOrEqual(steps, TranscriptPacing.catchUpSteps + 4)
    }

    func testWorkInARowAppearsTogetherBeforeTheNextText() {
        var pacing = TranscriptPacing()
        _ = pacing.visible([user("u1")], session: session, interactions: [])
        let items = [user("u1"), command("c1"), command("c2"), command("c3"), assistant("a1", "Found it.", turn: 1)]
        _ = pacing.visible(items, session: session, interactions: [])
        pacing.advance(items)
        let shown = pacing.visible(items, session: session, interactions: [])
        XCTAssertEqual(shown.items.map(\.id.rawValue), ["u1", "c1", "c2", "c3"])
        XCTAssertTrue(shown.waiting)
    }

    func testStreamingTextWaitsBrieflyForABreak() {
        var pacing = TranscriptPacing()
        _ = pacing.visible([user("u1")], session: session, interactions: [])
        let items = [user("u1"), assistant("a1", "系泊日志正在整理", turn: 1)]
        for _ in 0..<TranscriptPacing.patience {
            pacing.advance(items)
            XCTAssertEqual(pacing.visible(items, session: session, interactions: []).items.count, 1)
        }
        pacing.advance(items)
        XCTAssertEqual(pacing.visible(items, session: session, interactions: []).items, items)
    }

    func testItemsArrivingAboveWhatIsShownAppearAtOnce() {
        var pacing = TranscriptPacing()
        let later = [assistant("a2", "Later.", turn: 2)]
        _ = pacing.visible(later, session: session, interactions: [])
        let items = [assistant("a1", "Earlier page.", turn: 1)] + later
        let shown = pacing.visible(items, session: session, interactions: [])
        XCTAssertEqual(shown.items, items)
        XCTAssertFalse(shown.waiting)
    }

    func testAQuestionOrTheUsersOwnMessageShowsEverythingAtTheNextStep() {
        var pacing = TranscriptPacing()
        _ = pacing.visible([user("u1")], session: session, interactions: [])
        let waiting = [user("u1"), assistant("a1", "Let me check that for you.", turn: 1)]
        XCTAssertTrue(pacing.visible(waiting, session: session, interactions: []).waiting)
        let question = InteractionRecord(
            id: InteractionID(rawValue: "q1")!, revision: "1", sessionID: session, turnID: TurnID(rawValue: "turn-1")!,
            kind: .approval, title: "Approve?", detail: "", risk: .low, actions: [], phase: .pending)
        XCTAssertTrue(pacing.visible(waiting, session: session, interactions: [question]).waiting)
        settle(&pacing, waiting)
        XCTAssertEqual(pacing.visible(waiting, session: session, interactions: [question]).items, waiting)

        let more = waiting + [assistant("a2", "Another long reply that waits.", turn: 1)]
        XCTAssertTrue(pacing.visible(more, session: session, interactions: [question]).waiting)
        let sent = more + [user("u2", turn: 2)]
        _ = pacing.visible(sent, session: session, interactions: [question])
        settle(&pacing, sent)
        XCTAssertEqual(pacing.visible(sent, session: session, interactions: [question]).items, sent)
    }

    func testABurstShowsInOneStepOnceItStopsArriving() {
        var pacing = TranscriptPacing()
        var items = [user("u1")]
        _ = pacing.visible(items, session: session, interactions: [])
        // A catch-up lands over several steps: nothing of it shows meanwhile.
        for turn in 2...4 {
            items += [user("u\(turn)", turn: turn), assistant("a\(turn)", "Done.", turn: turn), command("c\(turn)", turn: turn)]
            XCTAssertTrue(pacing.visible(items, session: session, interactions: []).waiting)
            XCTAssertEqual(pacing.advance(items), .none)
            XCTAssertEqual(pacing.visible(items, session: session, interactions: []).items.count, 1)
        }
        // Then all of it at once, without an animated step.
        XCTAssertEqual(pacing.advance(items), .all)
        let shown = pacing.visible(items, session: session, interactions: [])
        XCTAssertEqual(shown.items, items)
        XCTAssertFalse(shown.waiting)
    }

    func testABurstThatKeepsArrivingStillShowsWithinAboutASecond() {
        var pacing = TranscriptPacing()
        var items = [user("u1")]
        _ = pacing.visible(items, session: session, interactions: [])
        var steps = 0
        while pacing.visible(items, session: session, interactions: []).items.count == 1, steps < 30 {
            items += [user("u\(steps + 2)", turn: steps + 2)]
            _ = pacing.visible(items, session: session, interactions: [])
            pacing.advance(items)
            steps += 1
        }
        XCTAssertLessThanOrEqual(steps, TranscriptPacing.burstPatience + 1)
    }

    func testEachStepSaysWhatItShowed() {
        var pacing = TranscriptPacing()
        _ = pacing.visible([user("u1")], session: session, interactions: [])
        let text = "First clause, second clause, third clause, fourth clause. And a second sentence follows here."
        let items = [user("u1"), assistant("a1", text, turn: 1), turnEnd("end", turn: 1)]
        _ = pacing.visible(items, session: session, interactions: [])
        XCTAssertEqual(pacing.advance(items), .newRow, "the reply's first words are a new row")
        XCTAssertEqual(pacing.advance(items), .grew, "more of it grows the row")
    }

    func testAnotherConversationShowsAtOnce() {
        var pacing = TranscriptPacing()
        _ = pacing.visible([user("u1")], session: session, interactions: [])
        let items = [user("u9"), assistant("a9", "Already here.", turn: 1)]
        let shown = pacing.visible(items, session: other, interactions: [])
        XCTAssertEqual(shown.items, items)
        XCTAssertFalse(shown.waiting)
    }

    func testCutPrefersTheStrongestBreakNearTheBudget() {
        let text = "One. Two three four five six seven, eight nine ten eleven twelve thirteen fourteen."
        let cut = TranscriptPacing.cut(text, from: 0, budget: 40, complete: false)
        XCTAssertEqual(String(text.utf8.prefix(cut))!, "One. Two three four five six seven,")
        XCTAssertEqual(TranscriptPacing.cut("Short.", from: 0, budget: 40, complete: true), "Short.".utf8.count)
        XCTAssertEqual(TranscriptPacing.cut("No break yet", from: 0, budget: 40, complete: false), "No break ".utf8.count)
    }

    func testPartlyShownBoldAndCodeAreClosed() {
        XCTAssertEqual(TranscriptPacing.closingOpenSpans("**注意："), "**注意：**")
        XCTAssertEqual(TranscriptPacing.closingOpenSpans("**注意：**这里，"), "**注意：**这里，")
        XCTAssertEqual(TranscriptPacing.closingOpenSpans("运行 `swift"), "运行 `swift`")
        XCTAssertEqual(TranscriptPacing.closingOpenSpans("`a**b` 和 **粗"), "`a**b` 和 **粗**")
        XCTAssertEqual(TranscriptPacing.closingOpenSpans("**旧段落**\n\n新的 **开始"), "**旧段落**\n\n新的 **开始**")
        XCTAssertEqual(TranscriptPacing.closingOpenSpans("```swift\nlet a = **b"), "```swift\nlet a = **b")
        XCTAssertEqual(TranscriptPacing.closingOpenSpans("2 \\** 3"), "2 \\** 3")
    }

    /// Steps until nothing more arrives and what waits is shown.
    private func settle(_ pacing: inout TranscriptPacing, _ items: [TranscriptItem]) {
        for _ in 0..<3 { pacing.advance(items) }
    }

    // MARK: - Items

    private func next() -> Date {
        clock += 1
        return Date(timeIntervalSince1970: 1_800_000_000 + Double(clock))
    }

    private func user(_ id: String, turn: Int = 1) -> TranscriptItem {
        TranscriptItem(id: TranscriptItemID(rawValue: id)!, turnID: TurnID(rawValue: "turn-\(turn)")!, turn: turn,
                       timestamp: next(), body: .user(text: "Hi", deliveryID: nil, attachmentIDs: [], translation: nil))
    }

    private func assistant(_ id: String, _ text: String, turn: Int) -> TranscriptItem {
        TranscriptItem(id: TranscriptItemID(rawValue: id)!, turnID: TurnID(rawValue: "turn-\(turn)")!, turn: turn,
                       timestamp: next(), body: .assistant(text: text, delta: false))
    }

    private func command(_ id: String, turn: Int = 1) -> TranscriptItem {
        TranscriptItem(id: TranscriptItemID(rawValue: id)!, turnID: TurnID(rawValue: "turn-\(turn)")!, turn: turn,
                       timestamp: next(), body: .command(status: .success, exitCode: 0))
    }

    private func turnEnd(_ id: String, turn: Int) -> TranscriptItem {
        TranscriptItem(id: TranscriptItemID(rawValue: id)!, turnID: TurnID(rawValue: "turn-\(turn)")!, turn: turn,
                       timestamp: next(), body: .turnEnd(outcome: .worked))
    }
}

private extension TranscriptItem {
    var assistantText: String? {
        if case .assistant(let text, _) = body { text } else { nil }
    }
}
