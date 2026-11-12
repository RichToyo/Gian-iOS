import Foundation
import GianCore

/// Preview only (`-previewDestination chatAgent`): replays agent turns the way
/// a live Host streams them — text in small deltas, tool calls that start and
/// finish, a burst of work arriving at once, a final answer and the turn's end
/// — so transcript pacing and scrolling can be checked without a live agent.
@MainActor
enum PreviewAgentTurn {
    static func play(_ store: GianClientStore, turns: Int = 3) async {
        guard let server = ServerAddress(parsing: PreviewFixtures.server) else { return }
        let scope = ClientScope(server: server, account: PreviewFixtures.account, host: PreviewFixtures.hostID)
        let session = PreviewFixtures.sessionID
        var player = Player(store: store, scope: scope, session: session)
        for turn in 0..<turns {
            guard await player.playTurn(number: 50 + turn) else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    /// A catch-up: after a moment, many turns' items land at once, as a
    /// transcript page read after a reconnect delivers them, item by item.
    static func catchUp(_ store: GianClientStore, turns: Int = 8) async {
        guard let server = ServerAddress(parsing: PreviewFixtures.server) else { return }
        let scope = ClientScope(server: server, account: PreviewFixtures.account, host: PreviewFixtures.hostID)
        var player = Player(store: store, scope: scope, session: PreviewFixtures.sessionID)
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
        for number in 0..<turns { await player.landTurn(number: 60 + number) }
    }

    @MainActor
    private struct Player {
        let store: GianClientStore
        let scope: ClientScope
        let session: SessionID
        private var sequence = 0

        init(store: GianClientStore, scope: ClientScope, session: SessionID) {
            self.store = store
            self.scope = scope
            self.session = session
        }

        mutating func playTurn(number: Int) async -> Bool {
            let turnID = TurnID(rawValue: "preview-agent-turn-\(number)")!
            setStatus(.running)
            emit(turn: number, turnID: turnID, id: "user-\(number)", body: .user(
                text: "整理一下系泊日志，检查缆绳告警，然后给我一个结论。", deliveryID: nil, attachmentIDs: [], translation: nil))
            do {
                try await pause(0.6)
                try await stream(Self.opening, turn: number, turnID: turnID, id: "text-a-\(number)")
                try await tool(.command(status: .running, exitCode: nil), done: .command(status: .success, exitCode: 0),
                               turn: number, turnID: turnID, id: "ls-\(number)")
                try await tool(.fileRead, done: nil, turn: number, turnID: turnID, id: "read-1-\(number)")
                try await stream(Self.finding, turn: number, turnID: turnID, id: "text-b-\(number)")
                try await tool(.fileSearch(kind: .grep, matchCount: nil), done: .fileSearch(kind: .grep, matchCount: 14),
                               turn: number, turnID: turnID, id: "grep-\(number)")
                // A burst: several tool calls land in one go, as after a reconnect.
                for index in 0..<8 {
                    emit(turn: number, turnID: turnID, id: "burst-\(index)-\(number)",
                         body: index.isMultiple(of: 3) ? .fileRead : .command(status: .success, exitCode: 0))
                }
                try await pause(0.4)
                try await stream(Self.progress, turn: number, turnID: turnID, id: "text-c-\(number)")
                try await tool(.fileChange(fileCount: 2), done: nil, turn: number, turnID: turnID, id: "edit-\(number)")
                try await tool(.command(status: .running, exitCode: nil), done: .command(status: .success, exitCode: 0),
                               turn: number, turnID: turnID, id: "test-\(number)")
                try await stream(Self.answer, turn: number, turnID: turnID, id: "text-d-\(number)")
                try await pause(0.3)
            } catch {
                return false
            }
            emit(turn: number, turnID: turnID, id: "end-\(number)", body: .turnEnd(outcome: .worked))
            setStatus(.done)
            return true
        }

        /// A finished turn, item by item as fast as a page arrives: each in
        /// its own main-actor turn, as the live connection delivers them.
        mutating func landTurn(number: Int) async {
            let turnID = TurnID(rawValue: "preview-agent-turn-\(number)")!
            var bodies: [(String, TranscriptBody)] = [
                ("user-\(number)", .user(text: "整理一下系泊日志，检查缆绳告警，然后给我一个结论。",
                                         deliveryID: nil, attachmentIDs: [], translation: nil)),
                ("text-a-\(number)", .assistant(text: Self.opening, delta: false)),
            ]
            for index in 0..<6 {
                bodies.append(("tool-\(index)-\(number)",
                               index.isMultiple(of: 2) ? .fileRead : .command(status: .success, exitCode: 0)))
            }
            bodies += [
                ("text-b-\(number)", .assistant(text: Self.finding, delta: false)),
                ("text-c-\(number)", .assistant(text: Self.progress, delta: false)),
                ("text-d-\(number)", .assistant(text: Self.answer, delta: false)),
                ("end-\(number)", .turnEnd(outcome: .worked)),
            ]
            for (id, body) in bodies {
                emit(turn: number, turnID: turnID, id: id, body: body)
                try? await Task.sleep(for: .milliseconds(4))
            }
        }

        private mutating func stream(_ text: String, turn: Int, turnID: TurnID, id: String) async throws {
            var rest = Substring(text)
            var chunk = 0
            while !rest.isEmpty {
                // Providers stream a few characters to a few words at a time.
                let size = [3, 5, 8, 12, 6, 4][chunk % 6]
                let piece = rest.prefix(size)
                rest = rest.dropFirst(piece.count)
                emit(turn: turn, turnID: turnID, id: id, body: .assistant(text: String(piece), delta: true))
                chunk += 1
                try await pause(0.035)
            }
        }

        private mutating func tool(_ running: TranscriptBody, done: TranscriptBody?, turn: Int, turnID: TurnID, id: String) async throws {
            emit(turn: turn, turnID: turnID, id: id, body: running)
            try await pause(0.5)
            if let done { emit(turn: turn, turnID: turnID, id: id, body: done) }
        }

        private func pause(_ seconds: Double) async throws {
            try await Task.sleep(for: .seconds(seconds))
        }

        private mutating func emit(turn: Int, turnID: TurnID, id: String, body: TranscriptBody) {
            sequence += 1
            guard let itemID = TranscriptItemID(rawValue: "preview-agent-\(id)") else { return }
            let item = TranscriptItem(id: itemID, turnID: turnID, turn: turn,
                                      timestamp: Date().addingTimeInterval(Double(sequence) * 0.001), body: body)
            _ = store.ingest(InboundEnvelope(scope: scope, event: .transcript(sessionID: session, item: item)))
        }

        private func setStatus(_ status: SessionStatus) {
            guard var record = store.state.conversation?.session, record.id == session else { return }
            record.status = status
            // As the Host announces it: the next canonical event.
            guard let cursor = store.state.sync.cursor else { return }
            _ = store.ingest(InboundEnvelope(scope: scope, event: .canonical(
                sequence: cursor.eventSequence + 1, generation: cursor.hostGeneration, body: .session(record))))
        }

        static let opening = "我先看一下系泊日志的结构，再检查**缆绳告警**的记录。"
        static let finding = """
        找到了两个日志文件：

        - **主日志：**`mooring.log`，记录每次靠泊和离泊
        - **告警日志：**`alerts.log`，记录张力超限

        接下来搜索最近一周的张力告警。
        """
        static let progress = """
        **结果：**最近一周共有 14 条告警，其中 3 条是**真实超限**，其余是传感器抖动造成的误报。

        我会给告警加一个去抖窗口，并补上测试。
        """
        static let answer = """
        ## 结论

        **缆绳状态：**正常。3 条真实超限都发生在大潮期间，峰值张力 *38.2 kN*，低于断裂负荷的 40%。

        **改动：**

        1. 告警加了 **5 秒去抖窗口**（`alerts/debounce.swift`）
        2. 新增 `testDebounceDropsSensorJitter`，覆盖传感器抖动

        | 类型 | 数量 | 处理 |
        |---|---|---|
        | **真实超限** | 3 | 保留 |
        | 传感器抖动 | 11 | 去抖后不再告警 |

        ```swift
        let window: Duration = .seconds(5)
        ```

        如果需要，我可以把去抖窗口做成可配置的。
        """
    }
}
