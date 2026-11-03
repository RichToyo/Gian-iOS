import Foundation
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
        case .invalidCode: "That isn't a pairing link or QR code for this server."
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
            lastActivity: summary.lastActivityAt
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
        let taskGroups = showsTasks ? state.directory.tasks.map { section in
            TaskGroupItem(
                id: section.id,
                title: section.title,
                conversations: section.conversations.map(conversationRow)
            )
        } : []

        let repoGroups = showsRepos ? state.directory.repositories.map { section in
            RepoGroupItem(
                id: section.id,
                repoName: section.title,
                conversations: section.conversations.map(conversationRow).sorted(by: activityDescending)
            )
        }
        .sorted { lhs, rhs in
            let lhsDate = lhs.conversations.first?.lastActivity ?? .distantPast
            let rhsDate = rhs.conversations.first?.lastActivity ?? .distantPast
            return lhsDate == rhsDate ? lhs.id.rawValue < rhs.id.rawValue : lhsDate > rhsDate
        } : []

        return DirectoryPresentation(
            view: state.navigation.directoryView,
            tasks: taskGroups,
            repos: repoGroups,
            reposAvailability: availability(of: state.directory.reposSupport, in: state.directory.legacyLimitations),
            searchQuery: state.directory.searchQuery,
            searchResults: showsSearch ? state.directory.searchResults.map(conversationRow) : [],
            searchAvailability: availability(of: state.directory.searchSupport, in: state.directory.legacyLimitations),
            tasksPage: state.directory.tasksPage,
            reposPage: state.directory.reposPage,
            searchPage: state.directory.searchPage
        )
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

    /// Latest transient cross-conversation banner. Same-conversation and
    /// background events never banner — the store's BannerReducer owns that.
    static func banner(_ state: GianClientState) -> BannerPresentation? {
        guard let latest = state.banners.max(by: { $0.latestAt < $1.latestAt }) else { return nil }
        let summaries = state.directory.tasks.flatMap(\.conversations)
            + state.directory.repos
            + state.directory.searchResults
        let match = summaries.first { $0.id == latest.sessionID }
        let agent = match.map { AgentLogo(pluginID: $0.pluginID, agentName: $0.agentName) } ?? .other
        return BannerPresentation(
            id: latest.id,
            sessionID: latest.sessionID,
            agent: agent,
            title: latest.title,
            summary: latest.eventCount > 1 ? "\(latest.summary) · \(latest.eventCount) events" : latest.summary,
            eventCount: latest.eventCount
        )
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
                rows.append(.assistant(AssistantRow(
                    id: item.id,
                    agent: agent,
                    agentName: agentName,
                    markdown: text,
                    reading: readingPresentation(sourceID: item.id.rawValue, translation: translation)
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
                flushWork(); pendingWorkTurn = nil
                rows.append(.notice(id: item.id, severity: severity, code: code))
            case .classifierDenied(let consecutive, let total):
                flushWork(); pendingWorkTurn = nil
                rows.append(.notice(
                    id: item.id, severity: .warning,
                    code: "Denied by classifier (\(consecutive) consecutive, \(total) total)"
                ))
            case .circuitBreaker(let trigger, let consecutive, let total):
                flushWork(); pendingWorkTurn = nil
                rows.append(.notice(
                    id: item.id, severity: .error,
                    code: "Circuit breaker (\(trigger.rawValue)): \(consecutive) consecutive, \(total) total"
                ))
            }
            lastRowIndexByTurn[item.turnID] = rows.count - 1
        }
        flushWork()

        // Place each interaction directly after the last row of its turn.
        for interaction in interactions.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            if let index = lastRowIndexByTurn[interaction.turnID] {
                rows.insert(.interaction(interaction), at: index + 1)
                lastRowIndexByTurn = lastRowIndexByTurn.mapValues { $0 >= index + 1 ? $0 + 1 : $0 }
            } else {
                rows.append(.interaction(interaction))
            }
        }
        return rows
    }

    static func readingPresentation(
        sourceID: String,
        translation: TranslationSessionState?
    ) -> ReadingTranslationPresentation {
        guard let translation else { return .none }
        if let record = translation.records.first(where: { $0.sourceID == sourceID }) {
            switch record.integrity {
            case .inlineVerified, .pagedVerified:
                if record.presentableText != nil { return .translated(record) }
                return .needsPaging(record)
            case .descriptorPending:
                return .needsPaging(record)
            case .hashMismatch, .lengthMismatch:
                return .failed("Translation failed integrity checks.")
            }
        }
        if let reading = translation.reading[sourceID] {
            if reading.uncertain { return .uncertain }
            if reading.pending { return .translating }
            if let error = reading.error { return .failed(error) }
        }
        if let automatic = translation.automatic[sourceID] {
            if automatic.pending { return .translating }
            if let error = automatic.error { return .failed(error) }
        }
        return .none
    }

    // MARK: - Active conversation

    static func activeConversation(_ state: GianClientState) -> ActiveConversationPresentation? {
        guard let conversation = state.conversation,
              case .conversation(let sessionID) = state.navigation.destination,
              conversation.session.id == sessionID
        else { return nil }
        let session = conversation.session
        let translationState = state.translations[sessionID]
        let translationPresentation = sessionTranslation(state, sessionID: sessionID)
        let interactions = state.interactions.filter { $0.sessionID == sessionID }
        let agent = AgentLogo(pluginID: session.pluginID, agentName: session.agentName)
        let isTurnActive = session.status == .running || session.status == .pending

        return ActiveConversationPresentation(
            id: sessionID,
            title: session.title,
            hostName: state.hosts.first { $0.id == session.hostID }?.name ?? "Host",
            rows: transcriptRows(
                items: conversation.items,
                interactions: interactions,
                translation: translationState,
                agent: agent,
                agentName: session.agentName,
                now: Date()
            ),
            hasOlderPages: conversation.hasOlder,
            connectivity: ConnectivityPresentation(state.connection),
            banner: banner(state),
            translation: translationPresentation,
            isTurnActive: isTurnActive
        )
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
        case .retryingLogin(let error, let retryAt, let expiresAt):
            return .retryingLogin(message: error.safeDescription, retryAt: retryAt, expiresAt: expiresAt)
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
