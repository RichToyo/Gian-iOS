import Foundation
import GianCore

/// What the transcript shows of a conversation's items while new ones arrive.
///
/// The store applies every streamed chunk as it comes. Showing each one would
/// re-render the transcript dozens of times a second, and a burst would land
/// as one jump. Instead, new items at the end are revealed in steps
/// (`advance`, about eight a second): text a clause or a line at a time, work
/// as it comes. A step takes more when more is waiting, so the transcript is
/// never more than about a second behind. History shows at once — the items
/// there when the chat opens, older pages, anything arriving above what is
/// shown — and so does everything waiting when a question or approval arrives,
/// the user's own message lands, or a burst (a catch-up after a reconnect)
/// brings many items: once the burst stops arriving, in one frame, rather than
/// as a run of jumps while it lands.
struct TranscriptPacing {
    static let interval: Duration = .milliseconds(120)
    /// Steps a backlog of text takes to clear, however large.
    static let catchUpSteps = 8
    /// Characters a step reveals at least.
    static let minimumStep = 24
    /// Steps to wait for the end of a sentence still being written.
    static let patience = 2
    /// Items waiting at once that make a burst, shown together.
    static let burst = 8
    /// Steps a burst may keep arriving before it is shown anyway.
    static let burstPatience = 8

    private var session: SessionID?
    /// Shown items: for text, how much of it (UTF-8 length); `Int.max` otherwise.
    private var shown: [TranscriptItemID: Int] = [:]
    private var pendingInteractions: Set<InteractionID> = []
    private var waited = 0
    /// Everything waiting shows at the next step (a question, the user's own message).
    private var showsAllNext = false
    /// Steps a burst has been held while it kept arriving.
    private var held = 0
    private var countAtLastStep = 0
    /// Characters a step reveals: set by the largest backlog since the
    /// transcript last caught up, so a burst clears in about `catchUpSteps`.
    private var rate = minimumStep

    /// The items to show now, and whether more is waiting to be revealed.
    mutating func visible(_ items: [TranscriptItem], session: SessionID,
                          interactions: [InteractionRecord]) -> (items: [TranscriptItem], waiting: Bool) {
        let pending = Set(interactions.lazy.filter { $0.phase == .pending }.map(\.id))
        let newQuestion = !pending.isSubset(of: pendingInteractions)
        pendingInteractions = pending
        if session != self.session {
            self.session = session
            shown = [:]
            waited = 0
            return (revealAll(items), false)
        }
        guard let last = items.lastIndex(where: { shown[$0.id] != nil }) else { return (revealAll(items), false) }
        let hiddenTail = last + 1 < items.count
        // At the next step, with whatever else lands meanwhile, not one by one.
        if newQuestion || items[(last + 1)...].contains(where: \.isUserMessage) { showsAllNext = true }
        var capped: [Int] = []
        for index in 0...last {
            let item = items[index]
            guard let limit = shown[item.id] else {
                // Arrived above what is shown (an older page, a late item).
                shown[item.id] = Self.length(of: item)
                continue
            }
            if let text = item.text, text.utf8.count > limit { capped.append(index) }
        }
        guard hiddenTail || !capped.isEmpty else {
            showsAllNext = false
            return (items, false)
        }
        var visible = Array(items[0...last])
        for index in capped {
            guard case .assistant(let text, let delta) = visible[index].body, let limit = shown[visible[index].id] else { continue }
            visible[index].body = .assistant(text: Self.closingOpenSpans(Self.prefix(text, utf8: limit)), delta: delta)
        }
        return (visible, true)
    }

    /// What a step showed, which decides how it animates.
    enum Step: Equatable {
        /// Nothing new (waiting for a sentence, or a burst still arriving).
        case none
        /// More of a message: glides, as the message grows.
        case grew
        /// A new row: settles in.
        case newRow
        /// Everything waiting at once (a burst, a question): as it is.
        case all
    }

    /// Reveals the next step of what is waiting: more of the text being
    /// shown, else the next text, else the work up to it.
    @discardableResult
    mutating func advance(_ items: [TranscriptItem]) -> Step {
        guard session != nil else { return .none }
        let arriving = items.count != countAtLastStep
        countAtLastStep = items.count
        let first = (items.lastIndex(where: { shown[$0.id] != nil }) ?? -1) + 1
        let waiting = items[min(first, items.count)...]
        if showsAllNext || waiting.count >= Self.burst || waiting.contains(where: \.isUserMessage) {
            // Held while it keeps arriving, then shown in one frame.
            if arriving, held < Self.burstPatience {
                held += 1
                return .none
            }
            _ = revealAll(items)
            return .all
        }
        held = 0
        let backlog = items.reduce(0) { total, item in
            guard let text = item.text else { return total }
            return total + max(0, text.utf8.count - min(shown[item.id] ?? 0, text.utf8.count))
        }
        rate = backlog == 0 ? Self.minimumStep : max(rate, backlog / Self.catchUpSteps)
        let budget = rate
        for (index, item) in items.enumerated() {
            guard let limit = shown[item.id], let text = item.text, text.utf8.count > limit else { continue }
            reveal(text, of: item.id, from: limit, budget: budget, complete: index + 1 < items.count)
            return shown[item.id] ?? 0 > limit ? .grew : .none
        }
        var index = first
        guard index < items.count else { return .none }
        if let text = items[index].text {
            reveal(text, of: items[index].id, from: 0, budget: budget, complete: index + 1 < items.count)
            return shown[items[index].id] != nil ? .newRow : .none
        }
        // Work and other items without text come together, up to the next text.
        while index < items.count, items[index].text == nil {
            shown[items[index].id] = .max
            index += 1
        }
        return .newRow
    }

    private mutating func revealAll(_ items: [TranscriptItem]) -> [TranscriptItem] {
        for item in items { shown[item.id] = Self.length(of: item) }
        waited = 0
        rate = Self.minimumStep
        showsAllNext = false
        held = 0
        countAtLastStep = items.count
        return items
    }

    private mutating func reveal(_ text: String, of id: TranscriptItemID, from start: Int, budget: Int, complete: Bool) {
        let cut = Self.cut(text, from: start, budget: budget, complete: complete || waited >= Self.patience)
        if cut > start {
            shown[id] = cut
            waited = 0
        } else {
            // Nothing yet: a message isn't shown before its first words.
            if start > 0 { shown[id] = start }
            waited += 1
        }
    }

    /// Where the next step of `text` ends (a UTF-8 offset): at the strongest
    /// break (line, sentence, clause, word) near `budget` characters on. With
    /// less than that left, up to its last break — the rest is likely still
    /// being written — or all of it once `complete`.
    static func cut(_ text: String, from start: Int, budget: Int, complete: Bool) -> Int {
        let utf8 = text.utf8
        guard start < utf8.count else { return utf8.count }
        var begin = utf8.index(utf8.startIndex, offsetBy: start)
        while begin > text.startIndex, String.Index(begin, within: text) == nil { begin = utf8.index(before: begin) }
        let rest = text[begin...]
        // The strongest (then latest) break in each half of the budget, and the first one past it.
        var early: (rank: Int, index: String.Index)?
        var late: (rank: Int, index: String.Index)?
        var after: String.Index?
        var count = 0
        var index = rest.startIndex
        while index < rest.endIndex {
            let rank = breakRank(rest[index])
            index = rest.index(after: index)
            count += 1
            guard rank > 0 else {
                if count > budget + 40 { break }
                continue
            }
            if count <= budget / 2 {
                if rank >= (early?.rank ?? 0) { early = (rank, index) }
            } else if count <= budget {
                if rank >= (late?.rank ?? 0) { late = (rank, index) }
            } else {
                after = index
                break
            }
        }
        let end: String.Index
        if index == rest.endIndex, count <= budget {
            // All that has arrived fits.
            if complete { end = rest.endIndex } else if let best = late ?? early { end = best.index } else { return start }
        } else if let late {
            end = late.index
        } else if let after {
            end = after
        } else if let early {
            end = early.index
        } else {
            end = rest.index(rest.startIndex, offsetBy: budget, limitedBy: rest.endIndex) ?? rest.endIndex
        }
        return utf8.distance(from: utf8.startIndex, to: end)
    }

    /// A step can end inside `**bold**` (often right after its "：") or inline
    /// code; the part shown closes them, so the markers never flash on screen
    /// before the rest arrives. Inside an open code block, the block shows as
    /// it is.
    static func closingOpenSpans(_ text: String) -> String {
        let fences = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }.count
        guard fences.isMultiple(of: 2) else { return text }
        let paragraph = text.range(of: "\n\n", options: .backwards)?.upperBound ?? text.startIndex
        let scalars = Array(text[paragraph...].unicodeScalars)
        var strong = 0
        var inCode = false
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            var run = 1
            while index + run < scalars.count, scalars[index + run] == scalar { run += 1 }
            if scalar == "\\" {
                index += 2
                continue
            }
            if scalar == "`", run == 1 { inCode.toggle() }
            if scalar == "*", run >= 2, !inCode { strong += 1 }
            index += run
        }
        var closed = text
        if inCode { closed += "`" }
        if !strong.isMultiple(of: 2) { closed += "**" }
        return closed
    }

    /// 4 a line, 3 a sentence, 2 a clause, 1 a word; 0 no break.
    private static func breakRank(_ character: Character) -> Int {
        switch character {
        case "\n": 4
        case "。", "！", "？", ".", "!", "?": 3
        case "，", "、", "；", "：", ",", ";", ":": 2
        case " ": 1
        default: 0
        }
    }

    private static func length(of item: TranscriptItem) -> Int {
        item.text?.utf8.count ?? .max
    }

    /// The first `length` UTF-8 bytes of `text`, ending on a whole character.
    private static func prefix(_ text: String, utf8 length: Int) -> String {
        var end = text.utf8.index(text.startIndex, offsetBy: min(length, text.utf8.count))
        while end > text.startIndex, String.Index(end, within: text) == nil {
            end = text.utf8.index(before: end)
        }
        return String(text[..<end])
    }
}

private extension TranscriptItem {
    /// The Agent's text, which is revealed a step at a time.
    var text: String? {
        if case .assistant(let text, _) = body { text } else { nil }
    }

    var isUserMessage: Bool {
        if case .user = body { true } else { false }
    }
}
