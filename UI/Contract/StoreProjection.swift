import Foundation
import CryptoKit
import GianCore

/// Pure projections from `GianClientState` into presentation values. Every
/// function is deterministic given its inputs, so mapper tests need no store,
/// clock or service. Views dispatch `GianClientAction` — they never read the
/// store directly.
enum StoreProjection {

    // MARK: - Conversation settings

    /// Settings of the open conversation as the Host reports them, with the
    /// Agent's choices (`catalog.read` models, `catalog.agent` options).
    static func conversationSettings(_ state: GianClientState, mutationsReady: Bool) -> ConversationSettingsPresentation? {
        guard let session = state.conversation?.session else { return nil }
        return settings(
            agentID: session.agentID,
            model: session.model,
            thinking: session.thinking,
            fast: session.serviceTier == "fast",
            approval: session.approvalMode,
            state: state,
            isEnabled: mutationsReady && !state.settingsUpdatePending
        )
    }

    /// The same options for a new chat, from the composer selection.
    static func newChatSettings(_ state: GianClientState, mutationsReady: Bool) -> ConversationSettingsPresentation? {
        let selection = state.composer.selection
        guard let agentID = selection.agentID else { return nil }
        return settings(
            agentID: agentID,
            model: selection.model,
            thinking: selection.thinking,
            fast: selection.fast == true,
            approval: selection.approvalMode,
            state: state,
            isEnabled: mutationsReady
        )
    }

    private static func settings(
        agentID: AgentID,
        model: String?,
        thinking: String?,
        fast: Bool,
        approval: String?,
        state: GianClientState,
        isEnabled: Bool
    ) -> ConversationSettingsPresentation {
        let agent = state.agents.first { $0.id == agentID }
        let options = state.agentOptions[agentID]
        let models = agent?.models ?? []
        let effectiveModel = model ?? models.first(where: \.isDefault)?.id ?? agent?.defaultModel
        var presentation = ConversationSettingsPresentation(isEnabled: isEnabled, notice: state.settingsNotice)
        if let agent {
            presentation.agent = AgentLogo(pluginID: agent.pluginID, agentName: agent.name)
            presentation.agentName = agent.name
        }
        presentation.models = models.map { AgentOptionChoice(value: $0.id, label: $0.label) }
        presentation.model = effectiveModel
        if let thinking = options?.thinking, !thinking.isEmpty {
            presentation.thinking = thinking.map { choice in
                choice.label == choice.value ? AgentOptionChoice(value: choice.value, label: thinkingLabel(choice.value)) : choice
            }
        } else if let supported = models.first(where: { $0.id == effectiveModel })?.supportedThinking {
            presentation.thinking = supported.map { AgentOptionChoice(value: $0, label: thinkingLabel($0)) }
        }
        presentation.currentThinking = thinking
        if let options, options.supportsFast {
            presentation.fast = options.fastAvailable(forModel: effectiveModel) ? .available(isOn: fast) : .unsupportedModel
        }
        presentation.approval = options?.approval ?? []
        presentation.currentApproval = approval ?? options?.approvalDefault
        return presentation
    }

    /// The desktop composer's names for raw effort values the Host passes
    /// through unlabeled (e.g. Codex's `xhigh`).
    static func thinkingLabel(_ value: String) -> String {
        switch value {
        case "minimal": "Minimal"
        case "low": "Light"
        case "medium": "Medium"
        case "high": "High"
        case "xhigh": "Extra High"
        case "max": "Max"
        case "ultra": "Ultra"
        default: value.capitalized
        }
    }

    // MARK: - Hosts

    /// Why the last pairing failed, for setup and Add Host.
    static func pairingNotice(_ outcome: HostPairingOutcome?) -> String? {
        switch outcome {
        case nil, .paired: nil
        case .invalidCode: "That isn't a valid pairing code or QR code for this server."
        case .rejected: "The Host declined this device."
        case .expired: "That pairing link has expired. Make a new one on the Host."
        case .failed(let message): message
        }
    }

    static func hosts(_ state: GianClientState) -> [HostItem] {
        state.hosts.map { host in
            HostItem(
                id: host.id,
                name: host.name,
                isReachable: host.online,
                isCurrent: host.id == state.currentHostID
            )
        }
    }

    // MARK: - Directory

    /// A pending interaction (approval, input) the Host reported for the
    /// session shows as Waiting even when the session's own attention flag
    /// has not caught up, so Home surfaces what needs the user.
    static func conversationRow(
        _ summary: ConversationSummary,
        awaitingUser: Set<SessionID> = []
    ) -> ConversationRowItem {
        var badge = StatusBadge(status: summary.status, attention: summary.attention)
        if awaitingUser.contains(summary.id), badge != .failed { badge = .waiting }
        return ConversationRowItem(
            id: summary.id,
            title: summary.title,
            agent: AgentLogo(pluginID: summary.pluginID, agentName: summary.agentName),
            agentName: summary.agentName,
            repoName: summary.repositoryName,
            badge: badge,
            lastActivity: summary.lastActivityAt,
            unread: summary.unread
        )
    }

    static func directory(_ state: GianClientState) -> DirectoryPresentation {
        let awaitingUser = Set(state.interactions.filter { $0.phase == .pending }.map(\.sessionID))
        let conversationRow = { (summary: ConversationSummary) in
            Self.conversationRow(summary, awaitingUser: awaitingUser)
        }
        let showsTasks = showsRows(for: state.directory.tasksPage)
        let showsRepos = showsRows(for: state.directory.reposPage)
        let showsSearch = showsRows(for: state.directory.searchPage)
        let temporaryID = state.directory.temporarySearchResult?.id
        let created = state.directory.temporaryCreatedResults.filter { $0.id != temporaryID }
        let temporaryIDs = Set(created.map(\.id)).union(temporaryID.map { [$0] } ?? [])
        // Rows show their time to the minute, and carry it so: a streaming
        // reply moves the exact time with every chunk, which would otherwise
        // re-render the list each time. Repos sort by the exact time first.
        let shownRow = { (summary: ConversationSummary) in Self.toTheMinute(conversationRow(summary)) }
        let taskGroups = showsTasks ? state.directory.tasks.map { section in
            TaskGroupItem(
                id: section.id,
                title: section.title,
                conversations: section.conversations.filter { !temporaryIDs.contains($0.id) }.map(shownRow)
            )
        }.filter { !$0.conversations.isEmpty } : []

        let repoGroups: [RepoGroupItem] = showsRepos ? state.directory.repositories.map { section in
            RepoGroupItem(
                id: section.id,
                repoName: section.title,
                conversations: section.conversations.filter { !temporaryIDs.contains($0.id) }.map(conversationRow).sorted(by: activityDescending)
            )
        }
        .filter { !$0.conversations.isEmpty }.sorted { lhs, rhs in
            let lhsDate = lhs.conversations.first?.lastActivity ?? .distantPast
            let rhsDate = rhs.conversations.first?.lastActivity ?? .distantPast
            return lhsDate == rhsDate ? lhs.id.rawValue < rhs.id.rawValue : lhsDate > rhsDate
        }.map { (group: RepoGroupItem) -> RepoGroupItem in
            var group = group
            group.conversations = group.conversations.map(Self.toTheMinute)
            return group
        } : []

        return DirectoryPresentation(
            view: state.navigation.directoryView,
            tasks: taskGroups,
            repos: repoGroups,
            reposAvailability: availability(of: state.directory.reposSupport, in: state.directory.legacyLimitations),
            searchQuery: state.directory.searchQuery,
            searchResults: showsSearch ? state.directory.searchResults.map(shownRow) : [],
            searchAvailability: availability(of: state.directory.searchSupport, in: state.directory.legacyLimitations),
            tasksPage: state.directory.tasksPage,
            reposPage: state.directory.reposPage,
            searchPage: state.directory.searchPage,
            timeFilter: state.navigation.directoryView == .tasks ? state.directory.tasksTimeFilter : state.directory.reposTimeFilter,
            temporarySearchResult: state.directory.temporarySearchResult.map(shownRow),
            temporarySearchGeneration: state.directory.temporarySearchGeneration,
            temporaryCreatedResults: created.map(shownRow)
        )
    }

    private static func toTheMinute(_ row: ConversationRowItem) -> ConversationRowItem {
        var row = row
        row.lastActivity = row.lastActivity.map { Date(timeIntervalSinceReferenceDate: ($0.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60) }
        return row
    }

    private static func showsRows(for page: DirectoryPageStatus) -> Bool {
        page.phase != .denied && page.phase != .unsupported
    }

    private static func activityDescending(_ lhs: ConversationRowItem, _ rhs: ConversationRowItem) -> Bool {
        let lhsDate = lhs.lastActivity ?? .distantPast
        let rhsDate = rhs.lastActivity ?? .distantPast
        return lhsDate == rhsDate ? lhs.id.rawValue < rhs.id.rawValue : lhsDate > rhsDate
    }

    private static func availability(
        of support: SurfaceSupport,
        in limitations: [LegacyLimitation]
    ) -> SurfaceAvailability {
        switch support {
        case .supported:
            return .ready
        case .unsupported(let surface):
            let detail = limitations.first { $0.surface == surface }?.detail
                ?? "This surface is not supported by the connected Host."
            return .unsupported(message: detail)
        }
    }

    static func newChatRemoteReady(
        taskID: TaskID?,
        directoryNegotiated: Bool,
        mutationsReady: Bool
    ) -> Bool {
        mutationsReady && (taskID != nil || directoryNegotiated)
    }

    static func canRetryUncertainCreate(_ state: GianClientState, mutationsReady: Bool) -> Bool {
        guard mutationsReady, state.capabilities.directoryNegotiated,
              case .uncertain(let intent) = state.composer.send,
              intent.stage == .create, intent.draftID == state.composer.draft.id,
              let request = intent.createRequest, request.commandID == intent.creationID
        else { return false }
        return true
    }

    // MARK: - Banner

    /// The in-app notification to show: the oldest still queued (they show
    /// one at a time, in the order they arrived). The store owns which
    /// changes notify (see `ConversationAlerts`).
    static func banner(_ state: GianClientState) -> BannerPresentation? {
        guard let next = state.banners.first else { return nil }
        let summaries = state.directory.tasks.flatMap(\.conversations)
            + state.directory.repos
            + state.directory.searchResults
        let match = summaries.first { $0.id == next.sessionID }
        let agent = match.map { AgentLogo(pluginID: $0.pluginID, agentName: $0.agentName) } ?? .other
        return BannerPresentation(id: next.id, sessionID: next.sessionID, agent: agent,
                                  title: next.title, kind: next.kind, summary: next.summary)
    }

    // MARK: - Translation (session level)

    static func sessionTranslation(_ state: GianClientState, sessionID: SessionID) -> SessionTranslationPresentation {
        let negotiated = state.capabilities.translationNegotiated
        let session = state.translations[sessionID]
        let capability: TranslationCapabilityPresentation
        if !negotiated || session?.supported == false {
            capability = .unsupported
        } else if session?.configured == true {
            capability = .configured
        } else {
            capability = .unconfigured
        }
        return SessionTranslationPresentation(
            capability: capability,
            isAutomatic: session?.enabled ?? false,
            sendingLanguage: session?.sendingLanguage ?? "",
            readingLanguage: session?.readingLanguage ?? "",
            notice: session?.notice ?? ""
        )
    }

    // MARK: - Transcript

    /// Builds ordered display rows: day markers, user/assistant messages,
    /// per-turn work cards, interaction cards placed after their turn, and
    /// terminal outcomes. `now` anchors relative day labels.
    static func transcriptRows(
        items: [TranscriptItem],
        interactions: [InteractionRecord],
        translation: TranslationSessionState?,
        agent: AgentLogo,
        agentName: String,
        now: Date,
        isTurnActive: Bool = false,
        calendar: Calendar = .current
    ) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var lastDay: Date?
        var pendingWork: [WorkEventItem] = []
        var pendingWorkTurn: TurnID?
        /// Last row index belonging to each turn, for interaction placement.
        var lastRowIndexByTurn: [TurnID: Int] = [:]
        /// Index of each turn's emitted work card, so a terminal turn outcome
        /// can correct the card phase (Failed/Stopped) after flush.
        var workCardIndexByTurn: [TurnID: Int] = [:]
        var finalAssistantByNumber: [Int: TranscriptItemID] = [:]
        // Each message looks up its own translation records, once grouped.
        let recordsBySource: [String?: [ReadingTranslation]] = Dictionary(
            grouping: translation?.records ?? [], by: { (record: ReadingTranslation) in record.sourceID })
        var terminalOutcomes: [Int: TurnOutcome] = [:]
        var failedTurns = Set<Int>()
        for item in items {
            if case .assistant(let text, _) = item.body, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finalAssistantByNumber[item.turn] = item.id
            }
            if case .turnEnd(let outcome) = item.body, terminalOutcomes[item.turn] == nil { terminalOutcomes[item.turn] = outcome }
            if case .error = item.body { failedTurns.insert(item.turn) }
        }

        func flushWork() {
            guard let turnID = pendingWorkTurn, !pendingWork.isEmpty else {
                pendingWork = []
                return
            }
            let phase: WorkCard.Phase
            if pendingWork.contains(where: { $0.outcome == .failed }) {
                phase = .failed
            } else if pendingWork.contains(where: { $0.outcome == .running }) {
                phase = .working
            } else if pendingWork.contains(where: { $0.outcome == .unknown }) {
                phase = .unknown
            } else {
                phase = .worked
            }
            rows.append(.work(WorkCard(id: turnID, phase: phase, events: pendingWork)))
            lastRowIndexByTurn[turnID] = rows.count - 1
            workCardIndexByTurn[turnID] = rows.count - 1
            pendingWork = []
        }

        for item in items {
            if pendingWorkTurn != nil, pendingWorkTurn != item.turnID {
                flushWork()
                pendingWorkTurn = nil
            }

            let day = calendar.startOfDay(for: item.timestamp)
            if day != lastDay {
                lastDay = day
                rows.append(.timeMarker(
                    id: "day-\(day.timeIntervalSince1970)-\(item.turn)",
                    label: dayLabel(for: item.timestamp, now: now, calendar: calendar)
                ))
            }

            switch item.body {
            case .user(let text, _, let attachmentIDs, let sent):
                flushWork(); pendingWorkTurn = nil
                rows.append(.user(UserRow(
                    id: item.id, text: text, attachmentIDs: attachmentIDs, sentTranslation: sent
                )))
            case .assistant(let text, _):
                flushWork(); pendingWorkTurn = nil
                let canonicalID = finalAssistantByNumber[item.turn] == item.id ? "turn:\(item.turn)" : item.id.rawValue
                let canonical = readingPresentation(sourceID: canonicalID, translation: translation, sourceText: text,
                                                    recordsBySource: recordsBySource)
                let legacy: ReadingTranslationPresentation = canonicalID == item.id.rawValue ? .none
                    : readingPresentation(sourceID: item.id.rawValue, translation: translation, sourceText: text,
                                          recordsBySource: recordsBySource)
                let canonicalUnavailable: Bool = if case .unavailable = canonical { true } else { false }
                let usesLegacy = (canonical == .none || canonicalUnavailable) && legacy != .none
                let sourceID = usesLegacy ? item.id.rawValue : canonicalID
                rows.append(.assistant(AssistantRow(
                    id: item.id,
                    agent: agent,
                    agentName: agentName,
                    markdown: text,
                    reading: usesLegacy ? legacy : canonical,
                    translationSourceID: sourceID,
                    translationExpandedByDefault: translation?.enabled ?? false,
                    canCancelTranslation: translation?.reading[sourceID]?.pending == true && translation?.reading[sourceID]?.uncertain == false,
                    isFinalResult: terminalOutcomes[item.turn] == .worked && !failedTurns.contains(item.turn)
                        && finalAssistantByNumber[item.turn] == item.id
                )))
            case .command(let status, let exitCode):
                pendingWorkTurn = item.turnID
                pendingWork.append(commandEvent(item: item, status: status, exitCode: exitCode))
                continue
            case .fileChange(let count):
                pendingWorkTurn = item.turnID
                pendingWork.append(WorkEventItem(
                    id: item.id, kind: .fileChange,
                    title: "Changed \(count) file\(count == 1 ? "" : "s")",
                    outcome: .done, statusText: "Done"
                ))
                continue
            case .fileRead:
                pendingWorkTurn = item.turnID
                pendingWork.append(WorkEventItem(
                    id: item.id, kind: .fileRead, title: "Read file",
                    outcome: .done, statusText: "Done"
                ))
                continue
            case .fileSearch(let kind, let matchCount):
                pendingWorkTurn = item.turnID
                pendingWork.append(WorkEventItem(
                    id: item.id, kind: .fileSearch,
                    title: "File search · \(kind.rawValue)",
                    outcome: .done,
                    statusText: matchCount.map { "\($0) matches" } ?? "Done"
                ))
                continue
            case .webSearch(let resultCount):
                pendingWorkTurn = item.turnID
                pendingWork.append(WorkEventItem(
                    id: item.id, kind: .webSearch, title: "Web search",
                    outcome: .done,
                    statusText: resultCount.map { "\($0) results" } ?? "Done"
                ))
                continue
            case .tool(let name, let status):
                pendingWorkTurn = item.turnID
                pendingWork.append(WorkEventItem(
                    id: item.id, kind: .tool, title: name,
                    outcome: toolOutcome(status), statusText: toolStatusText(status)
                ))
                continue
            case .agent(let status, let agentType, _, _):
                pendingWorkTurn = item.turnID
                pendingWork.append(WorkEventItem(
                    id: item.id, kind: .subagent, title: agentType ?? "Subagent",
                    outcome: agentOutcome(status), statusText: agentStatusText(status)
                ))
                continue
            case .turnEnd(let outcome):
                flushWork(); pendingWorkTurn = nil
                if let cardIndex = workCardIndexByTurn[item.turnID],
                   case .work(var card) = rows[cardIndex] {
                    switch outcome {
                    case .worked: card.phase = .worked
                    case .failed: card.phase = .failed
                    case .stopped: card.phase = .stopped
                    }
                    rows[cardIndex] = .work(card)
                }
                if outcome != .worked {
                    rows.append(.turnOutcome(id: item.id, outcome: outcome))
                }
            case .error:
                flushWork(); pendingWorkTurn = nil
                rows.append(.severeError(id: item.id))
            case .notice(let severity, let code):
                if severity == .info, let kind = legacyRemoteActivityKind(code) {
                    pendingWorkTurn = item.turnID
                    pendingWork.append(WorkEventItem(
                        id: item.id, kind: kind,
                        title: kind == .subagent ? "Agent activity" : "Tool activity",
                        outcome: .unknown, statusText: "Details unavailable"
                    ))
                    continue
                }
                if code == "guardianWarning", severity == .warning {
                    pendingWorkTurn = item.turnID
                    pendingWork.append(WorkEventItem(
                        id: item.id, kind: .warning, title: "Guardian warning",
                        outcome: .done, statusText: "Details unavailable"
                    ))
                    continue
                }
                flushWork(); pendingWorkTurn = nil
                rows.append(.notice(id: item.id, severity: severity, code: code))
            case .classifierDenied(let consecutive, let total):
                pendingWorkTurn = item.turnID
                pendingWork.append(WorkEventItem(id: item.id, kind: .warning, title: "Denied by classifier",
                    outcome: .done, statusText: "\(consecutive) consecutive, \(total) total"))
                continue
            case .circuitBreaker(let trigger, let consecutive, let total):
                pendingWorkTurn = item.turnID
                pendingWork.append(WorkEventItem(id: item.id, kind: .warning, title: "Circuit breaker (\(trigger.rawValue))",
                    outcome: .failed, statusText: "\(consecutive) consecutive, \(total) total"))
                continue
            }
            lastRowIndexByTurn[item.turnID] = rows.count - 1
        }
        flushWork()

        // Place each interaction directly after the last row of its turn. An
        // interaction carries the Agent's own turn id, which only the turn's
        // end shares; until that arrives it belongs to the latest turn.
        var numberByTurnID: [TurnID: Int] = [:]
        for item in items { numberByTurnID[item.turnID] = item.turn }
        let latestTurn = items.map(\.turn).max()
        var lastRowIndexByNumber: [Int: Int] = [:]
        for (turnID, index) in lastRowIndexByTurn {
            guard let number = numberByTurnID[turnID] else { continue }
            lastRowIndexByNumber[number] = max(lastRowIndexByNumber[number] ?? index, index)
        }
        for interaction in interactions.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            if let number = numberByTurnID[interaction.turnID] ?? latestTurn, let index = lastRowIndexByNumber[number] {
                rows.insert(.interaction(interaction), at: index + 1)
                lastRowIndexByNumber = lastRowIndexByNumber.mapValues { $0 >= index + 1 ? $0 + 1 : $0 }
            } else {
                rows.append(.interaction(interaction))
            }
        }
        return coalesceWorkCards(rows, items: items, isTurnActive: isTurnActive)
    }

    private static func coalesceWorkCards(_ rows: [TranscriptRow], items: [TranscriptItem], isTurnActive: Bool) -> [TranscriptRow] {
        var turnsByItem: [TranscriptItemID: Int] = [:]
        var turnsByID: [TurnID: Int] = [:]
        var endings: [Int: (TurnOutcome, Date)] = [:]
        var failedTurns = Set<Int>()
        var finalAssistants: [Int: TranscriptItemID] = [:]
        var times: [TranscriptItemID: Date] = [:]
        for item in items {
            turnsByItem[item.id] = item.turn
            turnsByID[item.turnID] = item.turn
            times[item.id] = item.timestamp
            if case .turnEnd(let outcome) = item.body, endings[item.turn] == nil { endings[item.turn] = (outcome, item.timestamp) }
            if case .error = item.body { failedTurns.insert(item.turn) }
            if case .assistant(let text, _) = item.body, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finalAssistants[item.turn] = item.id
            }
        }
        let latestTurn = items.map(\.turn).max()
        func turn(of row: TranscriptRow) -> Int? {
            switch row {
            case .user(let value): turnsByItem[value.id]
            case .assistant(let value): turnsByItem[value.id]
            case .work(let value): value.events.first.flatMap { turnsByItem[$0.id] }
            case .interaction(let value): turnsByID[value.turnID] ?? latestTurn
            case .turnOutcome(let id, _), .severeError(let id), .notice(let id, _, _): turnsByItem[id]
            case .timeMarker: nil
            }
        }
        var cards: [Int: WorkCard] = [:]
        var lastIndex: [Int: Int] = [:]
        var pendingInteractionIndex: [Int: Int] = [:]
        var firstWorkIndex: [Int: Int] = [:]
        var resultIndex: [Int: Int] = [:]
        var outcomeIndex: [Int: Int] = [:]
        for (index, row) in rows.enumerated() {
            guard let number = turn(of: row) else { continue }
            lastIndex[number] = index
            switch row {
            case .work(let card):
                if firstWorkIndex[number] == nil { firstWorkIndex[number] = index }
                if cards[number] == nil { cards[number] = card }
                else { cards[number]?.events.append(contentsOf: card.events) }
            case .assistant(let assistant) where finalAssistants[number] == assistant.id:
                resultIndex[number] = index
            case .turnOutcome:
                outcomeIndex[number] = index
            case .interaction(let interaction) where [.pending, .responding, .uncertain].contains(interaction.phase):
                if pendingInteractionIndex[number] == nil { pendingInteractionIndex[number] = index }
            default: break
            }
        }
        var insertions: [Int: [(Int, WorkCard)]] = [:]
        for (number, var card) in cards {
            let ending = endings[number]
            if let ending {
                switch ending.0 {
                case .worked: card.phase = failedTurns.contains(number) ? .failed : .worked
                case .failed: card.phase = .failed
                case .stopped: card.phase = .stopped
                }
                card.finishedAt = ending.1
            } else if isTurnActive && latestTurn == number {
                card.phase = .working
            } else if card.events.contains(where: { $0.outcome == .failed }) {
                card.phase = .failed
            } else if card.events.contains(where: { $0.outcome == .running }) {
                card.phase = .working
            } else if card.events.contains(where: { $0.outcome == .unknown }) {
                card.phase = .unknown
            } else {
                card.phase = .worked
            }
            card.startedAt = card.events.compactMap { times[$0.id] }.min()
            card.turn = number
            let anchor: Int
            if ending?.0 == .worked, !failedTurns.contains(number), let index = resultIndex[number] { anchor = index }
            else if let index = outcomeIndex[number] { anchor = index }
            else if let index = pendingInteractionIndex[number] { anchor = index }
            else if !isTurnActive, let index = firstWorkIndex[number] { anchor = index }
            // As in Gian, a running turn's card stays at the turn's end, below
            // its newest text: text arrives above it in order, and the card
            // moves once, above the final answer, when the turn ends.
            else { anchor = (lastIndex[number] ?? rows.count - 1) + 1 }
            insertions[anchor, default: []].append((number, card))
        }
        var movedInteractions = Set<Int>()
        var interactionsBefore: [Int: [TranscriptRow]] = [:]
        for (index, row) in rows.enumerated() {
            guard case .interaction(let interaction) = row,
                  [.pending, .responding, .uncertain].contains(interaction.phase),
                  let number = turn(of: row), let ending = endings[number] else { continue }
            let anchor = ending.0 == .worked && !failedTurns.contains(number) ? resultIndex[number] : outcomeIndex[number]
            guard let anchor, index > anchor else { continue }
            movedInteractions.insert(index)
            interactionsBefore[anchor, default: []].append(row)
        }
        var result: [TranscriptRow] = []
        for index in 0...rows.count {
            for (_, card) in (insertions[index] ?? []).sorted(by: { $0.0 < $1.0 }) { result.append(.work(card)) }
            result.append(contentsOf: interactionsBefore[index] ?? [])
            guard index < rows.count else { break }
            if movedInteractions.contains(index) { continue }
            if case .work = rows[index] { continue }
            result.append(rows[index])
        }
        return result
    }

    private static func legacyRemoteActivityKind(_ code: String) -> WorkEventItem.Kind? {
        switch code {
        case "command", "file-change", "file-read", "file-search", "web-search", "tool": .tool
        case "agent": .subagent
        default: nil
        }
    }

    static func readingPresentation(
        sourceID: String,
        translation: TranslationSessionState?,
        sourceText: String? = nil,
        recordsBySource: [String?: [ReadingTranslation]]? = nil
    ) -> ReadingTranslationPresentation {
        guard let translation else { return .none }
        let records = recordsBySource.map { $0[.some(sourceID)] ?? [] } ?? translation.records.filter { $0.sourceID == sourceID }
        let needsHash = translation.reading[sourceID] != nil || !records.isEmpty
        let sourceHash = needsHash ? sourceText.map(sha256Hex) : nil
        if let reading = translation.reading[sourceID] {
            let matches = sourceText == nil || (sourceHash != nil && reading.sourceSHA256?.lowercased() == sourceHash
                && !translation.readingLanguage.isEmpty && reading.targetLanguage?.caseInsensitiveCompare(translation.readingLanguage) == .orderedSame)
            if reading.uncertain || (!matches && reading.pending) { return .uncertain }
            if matches && reading.pending { return .translating }
            if matches, let error = reading.error { return .failed(error) }
        }
        let candidates = records.reversed().filter { record in
            record.sourceID == sourceID
                && ((sourceText == nil && translation.readingLanguage.isEmpty) ||
                    (!translation.readingLanguage.isEmpty && record.targetLanguage.caseInsensitiveCompare(translation.readingLanguage) == .orderedSame))
        }
        if let record = candidates.first(where: { record in sourceHash.map { record.sourceSHA256.lowercased() == $0 } ?? true }) {
            switch record.integrity {
            case .inlineVerified, .pagedVerified:
                if record.presentableText != nil { return .translated(record) }
                return .needsPaging(record)
            case .descriptorPending:
                return .needsPaging(record)
            case .hashMismatch, .lengthMismatch:
                return .needsPaging(record)
            }
        }
        if let automatic = translation.automatic[sourceID] {
            if automatic.pending { return .translating }
            if let error = automatic.error { return .failed(error) }
        }
        if !candidates.isEmpty, sourceHash != nil {
            return .unavailable("Translation does not match the displayed source.")
        }
        return .none
    }

    /// A text's SHA-256 in lowercase hex. Every reveal step re-projects the
    /// transcript, so each translated message's hash is kept, not recomputed.
    static func sha256Hex(_ text: String) -> String {
        let key = text as NSString
        if let cached = hashes.object(forKey: key) { return cached as String }
        var hex = [UInt8]()
        hex.reserveCapacity(64)
        for byte in SHA256.hash(data: Data(text.utf8)) {
            hex.append(hexDigits[Int(byte >> 4)])
            hex.append(hexDigits[Int(byte & 0x0F)])
        }
        let digest = String(decoding: hex, as: UTF8.self)
        hashes.setObject(digest as NSString, forKey: key)
        return digest
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)
    private nonisolated(unsafe) static let hashes: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 1_024
        return cache
    }()

    // MARK: - Active conversation

    /// Everything the transcript rows depend on, so callers can reuse rows
    /// while it is unchanged. `day` keeps relative day labels current.
    struct TranscriptRowsInput: Equatable {
        let items: [TranscriptItem]
        let interactions: [InteractionRecord]
        let translation: TranslationSessionState?
        let agent: AgentLogo
        let agentName: String
        let isTurnActive: Bool
        let day: Date

        /// The same input showing `items` instead (what pacing has revealed).
        func showing(_ items: [TranscriptItem]) -> TranscriptRowsInput {
            TranscriptRowsInput(items: items, interactions: interactions, translation: translation, agent: agent,
                                agentName: agentName, isTurnActive: isTurnActive, day: day)
        }
    }

    static func transcriptRows(_ input: TranscriptRowsInput, now: Date = Date()) -> [TranscriptRow] {
        transcriptRows(
            items: input.items,
            interactions: input.interactions,
            translation: input.translation,
            agent: input.agent,
            agentName: input.agentName,
            now: now,
            isTurnActive: input.isTurnActive
        )
    }

    static func activeConversation(
        _ state: GianClientState,
        now: Date = Date(),
        rows: (TranscriptRowsInput) -> [TranscriptRow] = { StoreProjection.transcriptRows($0) }
    ) -> ActiveConversationPresentation? {
        guard let conversation = state.conversation,
              case .conversation(let sessionID) = state.navigation.destination,
              conversation.session.id == sessionID
        else { return nil }
        let session = conversation.session
        let translationPresentation = sessionTranslation(state, sessionID: sessionID)
        let isTurnActive = session.status == .running || session.status == .pending
        let input = TranscriptRowsInput(
            items: conversation.items,
            interactions: state.interactions.filter { $0.sessionID == sessionID },
            translation: state.translations[sessionID],
            agent: AgentLogo(pluginID: session.pluginID, agentName: session.agentName),
            agentName: session.agentName,
            isTurnActive: isTurnActive,
            day: Calendar.current.startOfDay(for: now)
        )

        let transcriptRows = rows(input)
        return ActiveConversationPresentation(
            id: sessionID,
            title: session.title,
            hostName: state.hosts.first { $0.id == session.hostID }?.name ?? "Host",
            rows: transcriptRows,
            hasOlderPages: conversation.hasOlder,
            connectivity: ConnectivityPresentation(state.connection),
            translation: translationPresentation,
            isTurnActive: isTurnActive,
            transcriptSync: conversation.transcriptSync,
            queue: state.capabilities.state(of: .queueRead) == .supported ? session.queue : nil,
            queueCommand: state.queueCommands[sessionID],
            canUpdateQueue: state.capabilities.state(of: .queueUpdate) == .supported,
            canRemoveQueue: state.capabilities.state(of: .queueRemove) == .supported,
            canClearQueue: state.capabilities.state(of: .queueClear) == .supported,
            canSendQueueNow: state.capabilities.state(of: .queueSendNow) == .supported
                && (!isTurnActive || state.capabilities.state(of: .turnSteer) == .supported),
            pendingSend: pendingSend(state, sessionID: sessionID, rows: transcriptRows),
            holdsDraft: holdsDraft(state, sessionID: sessionID)
        )
    }

    /// The composer's message while it is on its way to this conversation, as
    /// the desktop shows it: translating, then sending, or a failed
    /// translation awaiting the user's choice. Nil once the transcript has it.
    static func pendingSend(_ state: GianClientState, sessionID: SessionID, rows: [TranscriptRow]) -> PendingSendRow? {
        let draft = state.composer.draft
        guard let phase = pendingPhase(state, sessionID: sessionID),
              !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty
        else { return nil }
        if case .sending = phase {
            let lastUser = rows.reversed().lazy.compactMap { row -> UserRow? in
                if case .user(let user) = row { return user }
                return nil
            }.first
            if lastUser?.text == draft.text { return nil }
        }
        return PendingSendRow(text: draft.text, attachmentCount: draft.attachments.count, phase: phase)
    }

    /// The composer holds its draft back (shown as the pending message) from
    /// Send until the message is sent or the user takes the text back.
    static func holdsDraft(_ state: GianClientState, sessionID: SessionID) -> Bool {
        pendingPhase(state, sessionID: sessionID) != nil
    }

    private static func pendingPhase(_ state: GianClientState, sessionID: SessionID) -> PendingSendRow.Phase? {
        guard let intent = state.composer.send.intent, intent.sessionID == sessionID,
              intent.draftID == state.composer.draft.id else { return nil }
        switch state.composer.send {
        case .awaitingTranslation: return .translating
        case .sending(let intent): return .sending(showsStatus: intent.translationReceiptID != nil || intent.explicitOriginal)
        case .failed(let intent, let message) where intent.stage == .translation: return .failed(message)
        default: return nil
        }
    }

    // MARK: - Private helpers

    private static func dayLabel(for date: Date, now: Date, calendar: Calendar) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return "\(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())), \(time)"
        }
        let day = date.formatted(date: .abbreviated, time: .omitted)
        return "\(day), \(time)"
    }

    private static func commandEvent(
        item: TranscriptItem,
        status: ToolStatus,
        exitCode: Int?
    ) -> WorkEventItem {
        let statusText: String
        let outcome: WorkEventItem.Outcome
        switch status {
        case .pending, .running:
            statusText = "Running"; outcome = .running
        case .success:
            statusText = exitCode.map { "exit \($0)" } ?? "Done"; outcome = .done
        case .error:
            statusText = exitCode.map { "exit \($0)" } ?? "Failed"; outcome = .failed
        }
        return WorkEventItem(id: item.id, kind: .command, title: "Command", outcome: outcome, statusText: statusText)
    }

    private static func toolOutcome(_ status: ToolStatus) -> WorkEventItem.Outcome {
        switch status {
        case .pending, .running: .running
        case .success: .done
        case .error: .failed
        }
    }

    private static func toolStatusText(_ status: ToolStatus) -> String {
        switch status {
        case .pending, .running: "Running"
        case .success: "Done"
        case .error: "Failed"
        }
    }

    private static func agentOutcome(_ status: AgentRunStatus) -> WorkEventItem.Outcome {
        switch status {
        case .running: .running
        case .done: .done
        case .error: .failed
        }
    }

    private static func agentStatusText(_ status: AgentRunStatus) -> String {
        switch status {
        case .running: "Running"
        case .done: "Done"
        case .error: "Failed"
        }
    }

    // MARK: - Diagnostics

    /// Maps the sanitized service diagnostic. `cleared` means "no diagnostic".
    static func diagnostic(_ diagnostic: RemoteServiceDiagnostic?) -> DiagnosticPresentation {
        guard let diagnostic else { return .none }
        switch diagnostic.status {
        case .connectionClosed(let error):
            return .connectionClosed(message: error.safeDescription)
        case .resyncRequired(let reason):
            return .resyncRequired(reason: reason.rawValue)
        case .cleared:
            return .none
        }
    }

    // MARK: - Transcript files

    static func attachmentPresentation(
        descriptor: RemoteFileDescriptor?,
        state: AttachmentBodyState?,
        now: Date = Date()
    ) -> AttachmentFilePresentation {
        guard let descriptor else { return .unknown }
        switch state {
        case .downloading:
            return .downloading(name: descriptor.name)
        case .cached:
            return .cached(name: descriptor.name, previewable: descriptor.previewable)
        case .expired:
            return .expired(name: descriptor.name)
        case .unavailable:
            return .unavailable(name: descriptor.name)
        case .hashMismatch:
            return .failed(name: descriptor.name, message: "Integrity check failed.")
        case .failed(let message):
            return .failed(name: descriptor.name, message: message)
        case .localOnly, .uploading, .uploaded, .none:
            if descriptor.expiresAt <= now { return .expired(name: descriptor.name) }
            guard descriptor.downloadable else { return .unavailable(name: descriptor.name) }
            return .readyToDownload(
                name: descriptor.name,
                byteCount: descriptor.byteCount,
                previewable: descriptor.previewable
            )
        }
    }
}
