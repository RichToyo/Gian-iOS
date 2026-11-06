import Foundation

extension GianClientStore {
    func storedTranscriptCursor(cursor: String?, hasOlder: Bool, session: SessionID, scope: ClientScope) -> StoredTranscriptCursor {
        var saved = StoredTranscriptCursor(cursor: cursor, hasOlder: hasOlder)
        saved.hostGeneration = state.sync.cursor?.hostGeneration
        saved.catchUp = memory.bundle(for: scope).transcriptCursors[session]?.catchUp
        return saved
    }

    /// Live transcript frames are not canonical replay occupants. Re-subscribe
    /// and page to an old stable-ID anchor before considering cached history
    /// reconciled. The anchor survives a process interruption of these reads.
    func reconcileActiveTranscript() async -> GianDispatchResult {
        guard let scope = readyScope(), let session = currentSessionID,
              state.conversation?.session.id == session else { return reject(.notFound) }
        let sync = beginTranscriptSync(session: session)
        var succeeded = false
        defer { finishTranscriptSync(sync, session: session, state: succeeded ? .idle : .failed) }
        let token = epoch
        let navigation = navigationEpoch
        let baseline = memory.bundle(for: scope).transcripts[session] ?? []
        let saved = memory.bundle(for: scope).transcriptCursors[session]
        let anchors = Set(saved?.catchUp?.anchorIDs ?? Array(baseline.suffix(256).map(\.id)))
        var pending: [TranscriptItem] = []
        var before: String?
        var seen: Set<String> = []
        var latest: TranscriptPageResponse?
        var temporaryBytes = 0
        for _ in 0..<64 {
            let page = await service.pageTranscript(scope: scope, sessionID: session, cursor: before)
            guard responseIsCurrent(token), navigation == navigationEpoch, currentSessionID == session, !Task.isCancelled else {
                return reject(.staleOperation)
            }
            guard !page.failed else { return reject(.notFound) }
            if latest == nil { latest = page }
            for item in page.items {
                switch item.body {
                case .assistant(let text, _), .user(let text, _, _, _): temporaryBytes += text.utf8.count + 2_048
                default: temporaryBytes += 16_384
                }
            }
            guard temporaryBytes <= 16 * 1024 * 1024, pending.count + page.items.count <= 2_048 else {
                return reject(.mutationsDisabled)
            }
            pending = TranscriptLog.merge(existing: page.items, incoming: pending)
            if anchors.isEmpty || !page.hasOlder || !anchors.isDisjoint(with: page.items.map(\.id)) {
                let current = memory.bundle(for: scope).transcripts[session] ?? []
                // No canonical cursor orders live chunks relative to a page.
                // Keep streaming that provably continues the page; re-read
                // rather than declaring any other raced partial body reconciled.
                guard TranscriptLog.liveChangesExtend(baseline: baseline, current: current, page: pending) else {
                    return reject(.staleOperation)
                }
                let merged = TranscriptLog.mergePage(baseline: baseline, current: current, page: pending)
                var cursor = storedTranscriptCursor(cursor: page.cursor, hasOlder: page.hasOlder, session: session, scope: scope)
                if let saved, saved.hostGeneration != nil, saved.hostGeneration == state.sync.cursor?.hostGeneration {
                    cursor.cursor = saved.cursor
                    cursor.hasOlder = saved.hasOlder
                } else if baseline.isEmpty, let latest {
                    cursor.cursor = latest.cursor
                    cursor.hasOlder = latest.hasOlder
                }
                cursor.catchUp = nil
                memory.update(scope) { $0.transcripts[session] = merged; $0.transcriptCursors[session] = cursor }
                if let tail = memory.retentionTailIDs(scope, session: session) {
                    let connected = tail.isEmpty || !page.hasOlder || !tail.isDisjoint(with: pending.map(\.id))
                    memory.noteRetentionItems(pending, session: session, scope: scope, hydrated: connected)
                }
                state.conversation?.items = merged
                state.conversation?.cursor = cursor.cursor
                state.conversation?.hasOlder = cursor.hasOlder
                state.conversation?.hydratedFromCache = false
                let result = persistenceResult()
                succeeded = result.isApplied
                return result
            }
            guard let next = page.cursor, seen.insert(next).inserted else { return reject(.notFound) }
            before = next
        }
        return reject(.mutationsDisabled)
    }

    func refresh() async -> GianDispatchResult {
        guard let scope = readyScope() else { return reject(.notAuthorized) }
        if storageWritesBlocked || storageLoadFailed {
            guard recoverLocalStorage().isApplied else { return reject(.mutationsDisabled) }
        }
        activeDirectoryReads += 1
        defer { activeDirectoryReads -= 1 }
        let token = epoch
        refreshSequence += 1
        let request = refreshSequence
        let response = await service.refreshDirectory(scope: scope)
        guard responseIsCurrent(token), request == refreshSequence, state.currentHostID == scope.host else { return reject(.staleOperation) }
        switch response {
        case .snapshot(let payload):
            let applied = applySnapshot(payload, scope: scope)
            guard applied.isApplied, negotiatedDirectory else { return applied }
            switch await refreshLoadedDirectoryViews() {
            case .complete, .incomplete: return .applied
            case .stale: return reject(.staleOperation)
            case .failed: return reject(.notFound)
            case .blocked: return reject(.mutationsDisabled)
            }
        case .unknownOutcome:
            // This is an idempotent directory read, not an uncertain mutation.
            // The coordinator may retry a superseded read within its fixed bound.
            return reject(.staleOperation)
        case .failed:
            return reject(.notFound)
        }
    }

    func search(_ query: String) async -> GianDispatchResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scope = readyScope() else { return reject(.notAuthorized) }
        state.directory.searchQuery = trimmed
        searchSequence += 1
        let request = searchSequence
        if trimmed.isEmpty {
            directoryRequests[.search] = nil
            directoryViews[.search] = nil
            searchHits = []
            reproject()
            return persistenceResult()
        }
        if negotiatedDirectory {
            if trimmed.utf16.count > 256 {
                directoryRequests[.search] = nil
                var saved = StoredDirectoryView()
                saved.status = DirectoryPageStatus(phase: .failed, error: "The search query is too long.")
                directoryViews[.search] = saved
                reproject()
                _ = persist()
                return reject(.notFound)
            }
            return await loadDirectory(.search, reset: true)
        }
        if state.directory.authority == .legacyOpenDoingTasksOnly {
            searchHits = []
            reproject()
            return reject(.legacySearchUnsupported)
        }
        let token = epoch
        let response = await service.searchSessions(scope: scope, query: trimmed)
        guard responseIsCurrent(token), request == searchSequence, state.directory.searchQuery == trimmed else { return reject(.staleOperation) }
        guard response.supported else {
            searchHits = []
            reproject()
            return reject(.legacySearchUnsupported)
        }
        searchHits = response.sessions.filter { $0.hostID == scope.host }
        reproject()
        persist()
        return .applied
    }

    func pageOlder() async -> GianDispatchResult {
        guard let scope = readyScope(), let sessionID = currentSessionID else { return reject(.notFound) }
        let token = epoch
        let navigation = navigationEpoch
        let savedCursor = memory.bundle(for: scope).transcriptCursors[sessionID]
        let cursor = savedCursor?.hostGeneration != nil && savedCursor?.hostGeneration == state.sync.cursor?.hostGeneration ? state.conversation?.cursor : nil
        let baseline = memory.bundle(for: scope).transcripts[sessionID] ?? []
        let page = await service.pageTranscript(scope: scope, sessionID: sessionID, cursor: cursor)
        guard responseIsCurrent(token) else { return reject(.staleOperation) }
        guard !page.failed else { return reject(.notFound) }
        let saved = memory.bundle(for: scope)
        // Older pages must not replace a newer live item with the same stable ID.
        let merged = TranscriptLog.mergePage(baseline: baseline, current: saved.transcripts[sessionID] ?? [], page: page.items)
        if navigation == navigationEpoch, currentSessionID == sessionID, state.conversation?.cursor == cursor {
            state.conversation?.items = merged
            state.conversation?.cursor = page.cursor
            state.conversation?.hasOlder = page.hasOlder
            let savedCursor = storedTranscriptCursor(cursor: page.cursor, hasOlder: page.hasOlder, session: sessionID, scope: scope)
            memory.update(scope) { $0.transcriptCursors[sessionID] = savedCursor }
        }
        memory.update(scope) { $0.transcripts[sessionID] = merged }
        if navigation == navigationEpoch, currentSessionID == sessionID,
           (sessions + searchHits).contains(where: { $0.id == sessionID && $0.authorized && !$0.archived }) {
            memory.noteRetentionItems(page.items, session: sessionID, scope: scope)
        }
        return persistenceResult()
    }

    func applySnapshot(_ payload: DirectorySnapshotPayload, scope: ClientScope) -> GianDispatchResult {
        guard payload.host.id == scope.host else { return reject(.scopeMismatch) }
        if let producer = service as? any DirectoryReadinessReporting,
           producer.acceptedDirectory?.accepts(payload, scope: scope) != true {
            return reject(.staleOperation)
        }
        if service is any GianClientEventSource, eventCoordinator?.isRunning != true {
            markConnectionNotReady(.offline, reason: .cryptoResumed)
            return reject(.mutationsDisabled)
        }
        let generationChanged = state.sync.cursor?.hostGeneration != payload.cursor.hostGeneration
        if let cursor = state.sync.cursor, cursor.hostGeneration == payload.cursor.hostGeneration,
           payload.cursor.eventSequence < cursor.eventSequence { return reject(.staleOperation) }
        let expanded = payload.negotiatedFeatures.contains(.sessionDirectoryV1)
        if generationChanged { invalidateDirectoryViews() }
        if expanded {
            // Legacy snapshots are deliberately narrow, even on an opted-in connection.
            // Rows already published by directory.list stay until that directory page
            // replaces them. A replayed snapshot must not put its narrow sessions back on top.
            let published = publishedDirectorySessionIDs
            for session in payload.sessions.filter({ $0.hostID == scope.host }) where !published.contains(session.id) && !deniedSessionAccess.contains(session.id)
                && (!sessionAccessOverflow || sessions.contains(where: { $0.id == session.id && $0.authorized })) {
                if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                    let activity = sessions[index]
                    sessions[index] = session
                    sessions[index].lastActivityAt = activity.lastActivityAt
                    sessions[index].activityIsMessageOrExecution = activity.activityIsMessageOrExecution
                } else { sessions.append(session) }
            }
        } else {
            sessions = payload.sessions.filter { incoming in
                incoming.hostID == scope.host && !deniedSessionAccess.contains(incoming.id)
                    && (!sessionAccessOverflow || sessions.contains(where: { $0.id == incoming.id && $0.authorized }))
            }
            directoryViews = [:]
            searchHits = []
        }
        if let current = state.conversation {
            if let updated = sessions.first(where: { $0.id == current.session.id && $0.authorized && !$0.archived }) {
                state.conversation?.session = updated
            } else {
                state.conversation = nil
                state.navigation.destination = .home
                navigationEpoch += 1
            }
        }
        taskRecords = expanded ? taskRecords.filter { prior in !payload.tasks.contains(where: { $0.id == prior.id }) } + payload.tasks : payload.tasks
        state.workspaces = expanded ? state.workspaces.filter { prior in !payload.workspaces.contains(where: { $0.id == prior.id }) } + payload.workspaces : payload.workspaces
        state.agents = payload.agents
        state.catalogRevision = payload.catalogRevision
        state.capabilities = CapabilityProjection(
            grants: payload.capabilities,
            negotiatedFeatures: payload.negotiatedFeatures
        )
        let priorInteractions = state.interactions.reduce(into: [InteractionID: InteractionRecord]()) { $0[$1.id] = $1 }
        let retainedInteractions = expanded ? state.interactions.filter { prior in
            !payload.sessions.contains(where: { $0.id == prior.sessionID })
        } : []
        state.interactions = retainedInteractions + payload.interactions.filter { !deniedSessionAccess.contains($0.sessionID) }.map { incoming in
            var next = incoming
            if incoming.phase == .pending, let previous = priorInteractions[incoming.id],
               previous.phase == .responding || previous.phase == .uncertain {
                next.phase = .uncertain
            }
            return next
        }
        state.sync = SyncProjection(cursor: payload.cursor, needsSnapshot: false, reason: nil)
        requiresFreshSnapshot = false
        readyServiceEpoch = (service as? any GianClientEventSource)?.eventEpoch
        if let diagnostic = serviceDiagnostic,
           case .resyncRequired = diagnostic.status,
           diagnostic.epoch == readyServiceEpoch,
           diagnostic.server.map({ $0 == scope.server }) ?? true,
           diagnostic.account.map({ $0 == scope.account }) ?? true,
           diagnostic.host.map({ $0 == scope.host }) ?? true {
            serviceDiagnostic = nil
        }
        state.directory.authority = expanded ? .negotiatedDirectoryV1 : payload.authority
        if state.localConnectivity == .available { state.connection = .online }
        if let index = state.hosts.firstIndex(where: { $0.id == payload.host.id }) { state.hosts[index] = payload.host }
        else { state.hosts.append(payload.host) }
        if state.capabilities.translationNegotiated {
            for (sessionID, incoming) in payload.translations {
                var current = state.translations[sessionID] ?? .unsupported
                if generationChanged {
                    current.supported = false
                    current.revision = 0
                    current.configRevision = 0
                    current.automaticEpoch = ""
                    current.automatic = [:]
                    for source in current.reading.keys where current.reading[source]?.pending == true {
                        current.reading[source]?.uncertain = true
                    }
                }
                state.translations[sessionID] = TranslationReducer.applyState(
                    current: current,
                    incoming: incoming,
                    authoritative: true
                )
                if incoming.revision >= current.revision, incoming.configRevision >= current.configRevision {
                    memory.update(scope) { $0.autoTranslationCommands[sessionID] = nil }
                }
            }
        }
        reproject()
        return persistenceResult()
    }

    func applyCanonical(sequence: Int, generation: HostGenerationID, body: CanonicalBody) -> GianDispatchResult {
        if state.sync.needsSnapshot { return .applied }
        guard var cursor = state.sync.cursor else {
            state.sync.needsSnapshot = true
            state.sync.reason = .gapEvicted
            schedulePersistence()
            return .applied
        }
        if generation != cursor.hostGeneration {
            state.sync.needsSnapshot = true
            state.sync.reason = .generationChanged
            schedulePersistence()
            return .applied
        }
        switch CanonicalSequence.advance(last: cursor.eventSequence, incoming: sequence) {
        case .gap, .needsSnapshot:
            state.sync.needsSnapshot = true
            state.sync.reason = .gapEvicted
            schedulePersistence()
            return .applied
        case .next:
            switch body {
            case .session(let session):
                guard session.hostID == state.currentHostID else { return reject(.scopeMismatch) }
                upsertSession(session)
                if state.conversation?.session.id == session.id {
                    if session.authorized, !session.archived { state.conversation?.session = session }
                    else {
                        state.conversation = nil
                        state.navigation.destination = .home
                        navigationEpoch += 1
                    }
                }
            case .interaction(let interaction):
                if deniedSessionAccess.contains(interaction.sessionID) { break }
                if let index = state.interactions.firstIndex(where: { $0.id == interaction.id }) {
                    let phase = state.interactions[index].phase
                    state.interactions[index] = interaction
                    if interaction.phase == .pending && (phase == .responding || phase == .uncertain) {
                        state.interactions[index].phase = phase
                    }
                } else {
                    state.interactions.append(interaction)
                }
            case .attention(let sessionID, let kind):
                guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return reject(.notFound) }
                sessions[index].attention = kind
            case .attentions(let values):
                for index in sessions.indices { sessions[index].attention = values[sessions[index].id] }
            }
            cursor.eventSequence = sequence
            state.sync.cursor = cursor
            reproject()
            schedulePersistence()
            return .applied
        }
    }

    func applyStatePatch(sequence: Int, generation: HostGenerationID, baseRevision: String,
                         revision: String, patch: CanonicalStatePatch) -> GianDispatchResult {
        guard !state.sync.needsSnapshot else { return .applied }
        guard var cursor = state.sync.cursor, cursor.hostGeneration == generation,
              cursor.eventSequence < Int.max, sequence == cursor.eventSequence + 1,
              !revision.isEmpty, baseRevision == cursor.revision,
              patch.sessions.allSatisfy({ $0.hostID == state.currentHostID }) else {
            markTranscriptCatchUp()
            state.sync.needsSnapshot = true
            state.sync.reason = .revisionMismatch
            if state.connection == .online { state.connection = .resyncing }
            schedulePersistence()
            return .applied
        }
        let legacyRemoved = negotiatedDirectory ? [] : patch.removedSessions
        let removedTasks = Set(patch.removedTasks)
        if negotiatedDirectory {
            var phases = [state.composer.send]
            if let scope = readyScope() { phases.append(contentsOf: memory.bundle(for: scope).operations.values) }
            let creating = phases.contains { phase in
                switch phase {
                case .creating(let intent), .uncertain(let intent): return intent.stage == .create
                default: return false
                }
            }
            for id in patch.removedSessions {
                let session = (sessions + searchHits).first { $0.id == id && $0.authorized && !$0.archived }
                let taskIsRemoved = session.flatMap { $0.taskID }.map { removedTasks.contains($0) } ?? false
                guard !deniedSessionAccess.contains(id), session != nil || creating,
                      !taskIsRemoved else { continue }
                guard pendingSessionAccess[id] != nil || pendingSessionAccess.count < 4_096 else {
                    sessionAccessOverflow = true
                    continue
                }
                sessionAccessSequence += 1
                pendingSessionAccess[id] = sessionAccessSequence
            }
        }
        if !patch.removedSessions.isEmpty || !patch.removedTasks.isEmpty {
            invalidateDirectoryViews()
            directoryRefreshPending = negotiatedDirectory
            let sessionsRemoved = Set(legacyRemoved)
            for collection in directoryViews.keys {
                directoryViews[collection]?.entries.removeAll { entry in
                    sessionsRemoved.contains(entry.session.id) || entry.task.map { removedTasks.contains($0.id) } == true
                }
            }
        }
        for session in patch.sessions {
            upsertSession(session)
            if state.conversation?.session.id == session.id,
               let updated = sessions.first(where: { $0.id == session.id && $0.authorized }),
               !deniedSessionAccess.contains(session.id) {
                state.conversation?.session = updated
            }
        }
        for (id, queue) in patch.queues {
            guard !sessionAccessOverflow, pendingSessionAccess[id] == nil, !deniedSessionAccess.contains(id),
                  let index = sessions.firstIndex(where: { $0.id == id && $0.authorized && !$0.archived }) else { continue }
            sessions[index].queue = queue
            if state.conversation?.session.id == id { state.conversation?.session = sessions[index] }
        }
        for id in legacyRemoved {
            if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index].authorized = false }
            if let index = searchHits.firstIndex(where: { $0.id == id }) { searchHits[index].authorized = false }
            if let scope = readyScope() { memory.clearRetentionActivity(scope: scope, session: id) }
            if temporarySearchResultID == id { temporarySearchResultID = nil }
            locallyCreatedSessions.remove(id); locallyCreatedWithActivity.remove(id)
            state.interactions.removeAll { $0.sessionID == id }
            if currentSessionID == id {
                navigationEpoch += 1; state.conversation = nil; state.navigation.destination = .home
            }
        }
        for task in patch.tasks {
            if let index = taskRecords.firstIndex(where: { $0.id == task.id }) { taskRecords[index] = task }
            else { taskRecords.append(task) }
        }
        for id in patch.removedTasks {
            if let index = taskRecords.firstIndex(where: { $0.id == id }) { taskRecords[index].status = .completed }
            for index in sessions.indices where sessions[index].taskID == id {
                recordSessionDenial(sessions[index].id); pendingSessionAccess.removeValue(forKey: sessions[index].id)
                sessions[index].authorized = false
            }
            for index in searchHits.indices where searchHits[index].taskID == id {
                recordSessionDenial(searchHits[index].id); pendingSessionAccess.removeValue(forKey: searchHits[index].id)
                searchHits[index].authorized = false
            }
            if let selected = temporarySearchResultID,
               (sessions + searchHits).contains(where: { $0.id == selected && $0.taskID == id }) { temporarySearchResultID = nil }
            if let selected = state.conversation?.session, selected.taskID == id {
                navigationEpoch += 1; state.conversation = nil; state.navigation.destination = .home
            }
        }
        for incoming in patch.interactions where !deniedSessionAccess.contains(incoming.sessionID) {
            if let index = state.interactions.firstIndex(where: { $0.id == incoming.id }) {
                let phase = state.interactions[index].phase
                state.interactions[index] = incoming
                if incoming.phase == .pending && (phase == .responding || phase == .uncertain) { state.interactions[index].phase = phase }
            } else { state.interactions.append(incoming) }
        }
        let removed = Set(patch.removedInteractions)
        state.interactions.removeAll { removed.contains($0.id) && $0.phase != .uncertain && $0.phase != .responding }
        if let attention = patch.attention {
            for index in sessions.indices { sessions[index].attention = attention[sessions[index].id] }
        }
        cursor.eventSequence = sequence; cursor.revision = revision
        state.sync.cursor = cursor
        reproject()
        if negotiatedDirectory && !patch.removedSessions.isEmpty { return persistenceResult() }
        schedulePersistence()
        return .applied
    }

    func applyTranscript(sessionID: SessionID, item: TranscriptItem) -> GianDispatchResult {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return reject(.notFound) }
        guard session.authorized, !session.archived, let scope = readyScope() else { return reject(.notAuthorized) }
        let textBytes: Int
        switch item.body {
        case .user(let text, _, _, _), .assistant(let text, _): textBytes = text.utf8.count
        default: textBytes = 0
        }
        guard textBytes <= 2 * 1024 * 1024 else {
            state.storageError = "A transcript item exceeds local storage limits."
            state.sync.needsSnapshot = true
            schedulePersistence()
            return reject(.mutationsDisabled)
        }
        let existing = memory.bundle(for: scope).transcripts[sessionID] ?? []
        if let prior = existing.first(where: { $0.id == item.id }), prior.turnID != item.turnID {
            state.sync.needsSnapshot = true
            return reject(.scopeMismatch)
        }
        guard let merged = TranscriptLog.applyingLive(existing: existing, item: item) else {
            state.sync.needsSnapshot = true
            state.sync.reason = .revisionMismatch
            schedulePersistence()
            return reject(.scopeMismatch)
        }
        switch item.body {
        case .user, .assistant, .command, .fileChange, .fileRead, .fileSearch, .webSearch, .tool, .agent, .turnEnd:
            noteCreatedActivity(sessionID)
        default: break
        }
        if state.conversation?.session.id == sessionID {
            state.conversation?.items = merged
        }
        memory.update(scope) { $0.transcripts[sessionID] = merged }
        // An exact duplicate is already in the log. It must not raise another banner.
        if existing == merged { return .applied }
        memory.noteRetentionItems([item], session: sessionID, scope: scope)
        let isRealActivity: Bool
        switch item.body {
        case .user, .assistant, .command, .fileChange, .fileRead, .fileSearch, .webSearch, .tool, .agent, .turnEnd:
            isRealActivity = true
        default: isRealActivity = false
        }
        if isRealActivity, item.timestamp.timeIntervalSince1970.isFinite,
           (!session.activityIsMessageOrExecution || session.lastActivityAt.map({ item.timestamp > $0 }) != false) {
            var active = session
            active.lastActivityAt = item.timestamp
            active.activityIsMessageOrExecution = true
            upsertSession(active)
            if state.conversation?.session.id == sessionID { state.conversation?.session = active }
            reproject()
        }
        let summary: String
        switch item.body {
        case .user(let text, _, _, _): summary = text
        case .assistant(let text, _): summary = text
        default: summary = "Activity"
        }
        state.banners = BannerReducer.reduce(
            existing: state.banners,
            signal: BannerReducer.Signal(sessionID: sessionID, title: session.title, summary: summary),
            currentSessionID: currentSessionID,
            foreground: state.foreground == .foreground,
            now: clock.now(),
            mint: { self.mint() }
        )
        schedulePersistence()
        return .applied
    }

    func applyTranslationEvent(sessionID: SessionID, update: TranslationInbound) -> GianDispatchResult {
        guard !deniedSessionAccess.contains(sessionID) else { return reject(.notAuthorized) }
        guard state.capabilities.translationNegotiated else { return reject(.translationUnavailable) }
        var current = state.translations[sessionID] ?? .unsupported
        switch update {
        case .state(let incoming, let authoritative):
            if authoritative, incoming.revision >= current.revision, incoming.configRevision >= current.configRevision,
               let scope = readyScope() {
                memory.update(scope) { $0.autoTranslationCommands[sessionID] = nil }
            }
            current = TranslationReducer.applyState(current: current, incoming: incoming, authoritative: authoritative)
        case .automatic(let sourceID, let pending, let error, let revision, let epoch):
            current = TranslationReducer.applyAutomatic(
                current: current,
                sourceID: sourceID,
                pending: pending,
                error: error,
                revision: revision,
                epoch: epoch
            )
        case .upsert(let record):
            let verified = TranslationReducer.verifiedRecord(
                id: record.id,
                sourceID: record.sourceID,
                targetLanguage: record.targetLanguage,
                text: record.presentableText,
                textLength: record.textLength,
                textSHA256: record.textSHA256,
                sourceSHA256: record.sourceSHA256,
                paged: false
            )
            if let prior = current.records.first(where: { $0.id == verified.id }),
               prior.textSHA256 == verified.textSHA256, verified.presentableText == nil,
               prior.presentableText != nil {
                break
            }
            if let index = current.records.firstIndex(where: { $0.id == verified.id }) { current.records[index] = verified }
            else { current.records.append(verified) }
        }
        state.translations[sessionID] = current
        schedulePersistence()
        return .applied
    }

    func setAuto(_ enabled: Bool) async -> GianDispatchResult {
        guard let scope = readyScope(), let sessionID = currentSessionID else { return reject(.notFound) }
        guard state.capabilities.translationNegotiated else { return reject(.translationUnavailable) }
        let current = state.translations[sessionID] ?? .unsupported
        guard current.configured else { return reject(.translationNotConfigured) }
        if !mutationsAllowed() { return reject(.mutationsDisabled) }
        if let code = requireCapability(.sessionUpdate) { return reject(code) }
        if memory.bundle(for: scope).autoTranslationCommands[sessionID] != nil { return reject(.uncertainOutcome) }
        let commandID: CommandID = mint()
        memory.update(scope) { $0.autoTranslationCommands[sessionID] = commandID }
        guard persist() else { return reject(.mutationsDisabled) }
        let token = epoch
        let response = await service.setAutoTranslation(
            scope: scope,
            request: TranslationAutoRequest(
                commandID: commandID,
                sessionID: sessionID,
                enabled: enabled,
                expectedEnabled: current.enabled,
                expectedRevision: current.revision
            )
        )
        guard responseIsCurrent(token) else { return reject(.staleOperation) }
        if case .state(let incoming) = response {
            memory.update(scope) { $0.autoTranslationCommands[sessionID] = nil }
            state.translations[sessionID] = TranslationReducer.applyState(
                current: state.translations[sessionID] ?? current,
                incoming: incoming,
                authoritative: false
            )
            persist()
            return .applied
        }
        state.translations[sessionID]?.notice = "Automatic translation state is unconfirmed."
        persist()
        return reject(.translationUnavailable)
    }

    func requestReading(sourceID: String, text: String) async -> GianDispatchResult {
        guard let scope = readyScope(), let sessionID = currentSessionID else { return reject(.notFound) }
        guard state.capabilities.translationNegotiated else { return reject(.translationUnavailable) }
        var current = state.translations[sessionID] ?? .unsupported
        if let existing = current.reading[sourceID] {
            if existing.uncertain { return reject(.uncertainOutcome) }
            if existing.pending { return reject(.operationInFlight) }
        }
        if current.automatic[sourceID]?.pending == true { return reject(.operationInFlight) }
        guard !sourceID.isEmpty, sourceID.utf8.count <= 1_024, text.utf8.count <= 2 * 1024 * 1024,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return reject(.translationUnavailable)
        }
        if sourceID.hasPrefix("turn:") {
            guard let turn = Int(sourceID.dropFirst(5)), turn >= 0, sourceID == "turn:\(turn)",
                  let currentText = state.conversation?.items.reversed().compactMap({ item -> String? in
                      guard item.turn == turn, case .assistant(let value, _) = item.body,
                            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                      return value
                  }).first, currentText == text else { return reject(.staleOperation) }
        }
        let sourceHash = SHA256Hex.digest(Data(text.utf8))
        if current.records.contains(where: {
            $0.sourceID == sourceID && $0.sourceSHA256.lowercased() == sourceHash
                && !$0.targetLanguage.isEmpty && !current.readingLanguage.isEmpty
                && $0.targetLanguage.caseInsensitiveCompare(current.readingLanguage) == .orderedSame
                && ($0.integrity == .inlineVerified || $0.integrity == .pagedVerified || $0.integrity == .descriptorPending)
        }) { return .applied }
        if !mutationsAllowed() { return reject(.mutationsDisabled) }
        if let code = requireCapability(.sessionSend) { return reject(code) }
        let requestID: TranslationRequestID = mint()
        current.reading[sourceID] = ReadingRequestState(requestID: requestID, pending: true, uncertain: false,
                                                         sourceSHA256: sourceHash, targetLanguage: current.readingLanguage)
        state.translations[sessionID] = current
        memory.update(scope) { $0.readingIntents[sessionID, default: [:]][sourceID] = StoredReadingIntent(requestID: requestID, sourceText: text) }
        guard persist() else {
            state.translations[sessionID]?.reading[sourceID]?.pending = false
            return reject(.mutationsDisabled)
        }
        let token = epoch
        let response = await service.requestTranslation(
            scope: scope,
            request: TranslationRequest(
                requestID: requestID,
                sessionID: sessionID,
                purpose: .read,
                text: text,
                sourceID: sourceID
            )
        )
        guard responseIsCurrent(token), state.translations[sessionID]?.reading[sourceID]?.requestID == requestID else { return reject(.staleOperation) }
        applyReadingResponse(response, sessionID: sessionID, sourceID: sourceID, requestID: requestID)
        return .applied
    }

    func cancelReading(_ sourceID: String) async -> GianDispatchResult {
        guard let scope = readyScope(), let sessionID = currentSessionID else { return reject(.notFound) }
        guard let request = state.translations[sessionID]?.reading[sourceID] else { return reject(.notFound) }
        if request.uncertain { return reject(.uncertainOutcome) }
        let token = epoch
        let response = await service.cancelTranslation(
            scope: scope,
            request: TranslationCancelRequest(sessionID: sessionID, requestID: request.requestID)
        )
        guard responseIsCurrent(token), state.translations[sessionID]?.reading[sourceID]?.requestID == request.requestID else { return reject(.staleOperation) }
        if case .cancelled(let id) = response, id == request.requestID {
            state.translations[sessionID]?.reading[sourceID] = nil
            persist()
            return .applied
        }
        if case .unknown = response {
            state.translations[sessionID]?.reading[sourceID]?.uncertain = true
            state.translations[sessionID]?.reading[sourceID]?.pending = true
            return persistenceResult()
        }
        return reject(.translationUnavailable)
    }

    func recoverReading(_ sourceID: String) async -> GianDispatchResult {
        guard let scope = readyScope(), let sessionID = currentSessionID,
              let request = state.translations[sessionID]?.reading[sourceID], request.uncertain || request.pending else { return reject(.notFound) }
        guard translationStatusRequests.insert(request.requestID).inserted else { return reject(.operationInFlight) }
        defer { translationStatusRequests.remove(request.requestID) }
        let token = epoch
        let navigation = navigationEpoch
        let status = await service.translationRequestStatus(scope: scope,
            request: TranslationStatusRequest(sessionID: sessionID, requestID: request.requestID))
        guard responseIsCurrent(token), navigation == navigationEpoch, currentSessionID == sessionID,
              state.translations[sessionID]?.reading[sourceID]?.requestID == request.requestID else { return reject(.staleOperation) }
        applyReadingResponse(status, sessionID: sessionID, sourceID: sourceID, requestID: request.requestID)
        return persistenceResult()
    }

    func pageTranslation(_ id: TranslationRecordID) async -> GianDispatchResult {
        guard let scope = readyScope(), let sessionID = currentSessionID,
              let record = state.translations[sessionID]?.records.first(where: { $0.id == id })
        else { return reject(.notFound) }
        guard translationPageRequests.insert(id).inserted else { return reject(.operationInFlight) }
        defer { translationPageRequests.remove(id) }
        var assembled = ""
        var offset: Int?
        var pages = 0
        while pages < 64 {
            pages += 1
            let token = epoch
            let response = await service.pageTranslationText(
                scope: scope,
                request: TranslationTextPageRequest(sessionID: sessionID, recordID: id, offset: offset)
            )
            guard responseIsCurrent(token),
                  state.translations[sessionID]?.records.first(where: { $0.id == id })?.textSHA256 == record.textSHA256 else {
                return reject(.staleOperation)
            }
            switch response {
            case .page(let text, let next):
                guard assembled.utf16.count + text.utf16.count <= record.textLength else { return reject(.translationUnavailable) }
                assembled += text
                if let next {
                    guard next > (offset ?? 0), next == assembled.utf16.count else { return reject(.translationUnavailable) }
                    offset = next
                } else {
                    let verified = TranslationReducer.verifiedRecord(
                        id: record.id,
                        sourceID: record.sourceID,
                        targetLanguage: record.targetLanguage,
                        text: assembled,
                        textLength: record.textLength,
                        textSHA256: record.textSHA256,
                        sourceSHA256: record.sourceSHA256,
                        paged: true
                    )
                    replaceRecord(verified, sessionID: sessionID)
                    return .applied
                }
            case .notFound, .failed, .unknown:
                state.translations[sessionID]?.notice = "Translation text could not be loaded."
                persist()
                return reject(.translationUnavailable)
            }
        }
        state.translations[sessionID]?.notice = "Translation exceeds local paging limits."
        return reject(.translationUnavailable)
    }

    func reclaim() async -> GianDispatchResult {
        guard case .awaitingTranslation(var intent) = state.composer.send,
              let scope = readyScope(),
              let sessionID = intent.sessionID,
              let requestID = intent.translationRequestID
        else { return reject(.uncertainOutcome) }
        intent.userRequestedSend = false
        state.composer.send = .awaitingTranslation(intent)
        guard persist() else { return reject(.mutationsDisabled) }
        let token = epoch
        let navigation = navigationEpoch
        let response = await service.cancelTranslation(
            scope: scope,
            request: TranslationCancelRequest(sessionID: sessionID, requestID: requestID)
        )
        guard responseIsCurrent(token), navigation == navigationEpoch,
              state.composer.draft.id == intent.draftID,
              state.composer.send.intent?.translationRequestID == requestID else { return reject(.staleOperation) }
        switch response {
        case .cancelled(let id) where id == requestID:
            state.composer.send = .idle
            state.composer.notice = .none
            persist()
            return .applied
        case .unknown:
            state.composer.send = .uncertain(intent)
            state.composer.notice = .keptAfterUncertainOutcome
            persist()
            return .applied
        default:
            return reject(.translationUnavailable)
        }
    }

    func applyReadingResponse(
        _ response: TranslationCommandResponse,
        sessionID: SessionID,
        sourceID: String,
        requestID: TranslationRequestID
    ) {
        let previous = state.translations[sessionID]?.reading[sourceID]
        switch response {
        case .settled(let settledID, let record, let error):
            guard settledID == requestID else { return }
            if let record {
                guard (record.sourceID == nil || record.sourceID == sourceID),
                      let scope = readyScope(), let original = memory.bundle(for: scope).readingIntents[sessionID]?[sourceID],
                      original.requestID == requestID,
                      record.sourceSHA256.lowercased() == SHA256Hex.digest(Data(original.sourceText.utf8)) else {
                    state.translations[sessionID]?.reading[sourceID] = ReadingRequestState(
                        requestID: requestID, pending: true, uncertain: true,
                        sourceSHA256: previous?.sourceSHA256, targetLanguage: previous?.targetLanguage)
                    persist()
                    return
                }
                state.translations[sessionID]?.reading[sourceID] = nil
                let verified = TranslationReducer.verifiedRecord(
                    id: record.id,
                    sourceID: record.sourceID ?? sourceID,
                    targetLanguage: record.targetLanguage,
                    text: record.presentableText,
                    textLength: record.textLength,
                    textSHA256: record.textSHA256,
                    sourceSHA256: record.sourceSHA256,
                    paged: false
                )
                replaceRecord(verified, sessionID: sessionID)
            } else if let error {
                state.translations[sessionID]?.reading[sourceID] = ReadingRequestState(
                    requestID: requestID,
                    pending: false,
                    uncertain: false,
                    error: error,
                    sourceSHA256: previous?.sourceSHA256, targetLanguage: previous?.targetLanguage
                )
            } else {
                state.translations[sessionID]?.reading[sourceID] = ReadingRequestState(
                    requestID: requestID, pending: true, uncertain: true,
                    sourceSHA256: previous?.sourceSHA256, targetLanguage: previous?.targetLanguage)
            }
        case .unknown:
            state.translations[sessionID]?.reading[sourceID] = ReadingRequestState(
                requestID: requestID,
                pending: true,
                uncertain: true, sourceSHA256: previous?.sourceSHA256, targetLanguage: previous?.targetLanguage
            )
        case .failed(let message):
            state.translations[sessionID]?.reading[sourceID] = ReadingRequestState(
                requestID: requestID,
                pending: false,
                uncertain: false,
                error: message,
                sourceSHA256: previous?.sourceSHA256, targetLanguage: previous?.targetLanguage
            )
        case .cancelled(let id) where id == requestID:
            state.translations[sessionID]?.reading[sourceID]?.pending = false
        case .cancelled:
            state.translations[sessionID]?.reading[sourceID]?.uncertain = true
        case .unavailable:
            state.translations[sessionID]?.reading[sourceID]?.pending = false
        case .state:
            state.translations[sessionID]?.reading[sourceID]?.uncertain = true
        }
        persist()
    }

    private func replaceRecord(_ record: ReadingTranslation, sessionID: SessionID) {
        if state.translations[sessionID] == nil { state.translations[sessionID] = .unsupported }
        if let index = state.translations[sessionID]?.records.firstIndex(where: { $0.id == record.id }) {
            state.translations[sessionID]?.records[index] = record
        } else {
            state.translations[sessionID]?.records.append(record)
        }
        persist()
    }
}
