import Foundation
import Observation

/// Main-actor client state. `service` is the only backend: a failure never
/// substitutes `PreviewGianClientService`.
@MainActor
@Observable
public final class GianClientStore {
    public internal(set) var state: GianClientState
    public internal(set) var serviceDiagnostic: RemoteServiceDiagnostic?
    /// Local hiding is complete even when the latest server outcome is unconfirmed.
    public internal(set) var serverOutcomeUnconfirmed = false
    /// Local data is hidden, but durable logout could not be confirmed. If all
    /// barrier stores fail, restart safety cannot be promised by this process.
    public internal(set) var authorizationInvalidationUnconfirmed = false

    public var mutationsReady: Bool { mutationsAllowed() }
    public internal(set) var transcriptFileStates: [AttachmentID: AttachmentBodyState] = [:]

    @ObservationIgnored let service: any GianClientServicing
    @ObservationIgnored let clock: any GianClock
    @ObservationIgnored let ids: any GianIDGenerating
    @ObservationIgnored let memory: ScopedMemory
    @ObservationIgnored var storageLoadFailed = false
    @ObservationIgnored var storageWritesBlocked = false
    @ObservationIgnored var navigationEpoch = 0
    @ObservationIgnored var refreshSequence = 0
    @ObservationIgnored var searchSequence = 0
    @ObservationIgnored var directorySequence = 0
    @ObservationIgnored var directoryRequestSequence = 0
    @ObservationIgnored var transcriptSyncSequence = 0
    @ObservationIgnored var directoryRequests: [DirectoryCollection: Int] = [:]
    @ObservationIgnored var manualDirectoryRecoveries: [DirectoryCollection: Set<Int>] = [:]
    @ObservationIgnored var manualDirectoryRecoverySequence = 0
    @ObservationIgnored var directoryViews: [DirectoryCollection: StoredDirectoryView] = [:]
    @ObservationIgnored var tasksTimeFilter: DirectoryTimeFilter = .last7Days
    @ObservationIgnored var reposTimeFilter: DirectoryTimeFilter = .last7Days
    @ObservationIgnored var temporarySearchResultID: SessionID?
    @ObservationIgnored var temporarySearchGeneration = 0
    @ObservationIgnored var locallyCreatedSessions: Set<SessionID> = []
    @ObservationIgnored var locallyCreatedWithActivity: Set<SessionID> = []
    @ObservationIgnored var pendingSessionAccess: [SessionID: Int] = [:]
    @ObservationIgnored var deniedSessionAccess: Set<SessionID> = []
    @ObservationIgnored var sessionAccessOverflow = false
    @ObservationIgnored var sessionAccessSequence = 0
    @ObservationIgnored var directoryExpiryTask: Task<Void, Never>?
    @ObservationIgnored var retentionRecoveryTasks: [ClientScope: Task<Void, Never>] = [:]
    @ObservationIgnored var retentionExpiryTask: Task<Void, Never>?
    @ObservationIgnored var retentionExpiryDeadline: Date?
    @ObservationIgnored var retentionExpiryScope: ClientScope?
    @ObservationIgnored var retentionExpiryEpoch: Int?
    @ObservationIgnored var retentionExpiryGeneration: UInt64 = 0
    @ObservationIgnored var retentionExpirySleep: (UInt64) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
    }
    @ObservationIgnored var retentionRecoverySleep: (UInt64) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
    }
    @ObservationIgnored var retentionRecoveryYield: () async -> Void = { await Task.yield() }
    @ObservationIgnored var translationPageRequests: Set<TranslationRecordID> = []
    @ObservationIgnored var translationStatusRequests: Set<TranslationRequestID> = []
    @ObservationIgnored var directoryRefreshPending = false
    @ObservationIgnored var invalidatedAuthorizations: [DataScope: Date] = [:]
    @ObservationIgnored var serverPins: [ServerAddress: String] = [:]
    @ObservationIgnored var requiresFreshSnapshot = true
    @ObservationIgnored var pendingPersistence: Task<Void, Never>?
    @ObservationIgnored var pendingEventCount = 0
    @ObservationIgnored var epoch = 0
    @ObservationIgnored var expectedServiceEpoch: Int?
    @ObservationIgnored var readyServiceEpoch: Int?
    @ObservationIgnored weak var eventCoordinator: GianClientCoordinator?
    @ObservationIgnored var pendingRemoteLogout: DataScope?
    @ObservationIgnored var remoteLogoutTask: Task<Void, Never>?
    @ObservationIgnored var remoteLogoutID = 0
    @ObservationIgnored var activeDirectoryReads = 0
    @ObservationIgnored var lifecycleOutcomeSequence = 0
    @ObservationIgnored var invalidatedHosts: [ClientScope: Date] = [:]
    @ObservationIgnored var sessions: [SessionRecord] = []
    @ObservationIgnored var taskRecords: [TaskRecord] = []
    @ObservationIgnored var searchHits: [SessionRecord] = []
    @ObservationIgnored var verifiedTranscriptDownloads: [AttachmentID: VerifiedTranscriptDownload] = [:]
    @ObservationIgnored var transcriptDownloadRequests: [AttachmentID: Int] = [:]
    @ObservationIgnored var transcriptDownloadSequence = 0
    /// Bumped by Cancel so a late pairing reply is dropped.
    @ObservationIgnored var pairingSequence = 0
    /// Logo reads in flight or answered "none" per Host, plugin and variant.
    @ObservationIgnored var agentLogoSkips: Set<String> = []
    @ObservationIgnored var agentLogoUnsupportedHosts: Set<HostID> = []

    /// Compatibility only. Production composition explicitly injects SQLite.
    public convenience init(
        service: any GianClientServicing,
        clock: any GianClock = SystemGianClock(),
        ids: any GianIDGenerating = UUIDv7IDGenerator()
    ) {
        self.init(service: service, clock: clock, ids: ids, storage: InMemoryGianStorage())
    }

    public init(
        service: any GianClientServicing,
        clock: any GianClock = SystemGianClock(),
        ids: any GianIDGenerating = UUIDv7IDGenerator(),
        storage: any GianStorage
    ) {
        self.service = service
        self.clock = clock
        self.ids = ids
        self.memory = ScopedMemory(storage: storage, retentionClock: clock)
        self.state = .signedOut()
    }

    @discardableResult
    public func dispatch(_ action: GianClientAction) async -> GianDispatchResult {
        await finishPendingRemoteLogout()
        synchronizeServiceEpoch()
        eventCoordinator?.willDispatch(action)
        let result = await reduceAction(action)
        synchronizeServiceEpoch()
        eventCoordinator?.didDispatch(action, result: result)
        return result
    }

    private func reduceAction(_ action: GianClientAction) async -> GianDispatchResult {
        switch action {
        case .setServerAddress(let raw, let enrollmentToken):
            let previous = state.server
            let result = setServer(raw)
            guard result.isApplied else { return result }
            if previous != state.server, let lifecycle = service as? any GianClientLifecycle { await lifecycle.disconnect() }
            return await connectServer(enrollmentToken: enrollmentToken)
        case .forgetServerIdentity(let enrollmentToken):
            guard state.phase == .serverEntered, state.account.status == .serverIdentityChanged, let server = state.server else {
                return reject(.notAuthorized)
            }
            if let lifecycle = service as? any GianClientLifecycle {
                do { try await lifecycle.forgetServer(server) }
                catch {
                    state.account = AccountAuthorization(status: .error, failure: (error as? RemoteClientError)?.safeDescription)
                    return reject(.notAuthorized)
                }
            }
            return await connectServer(enrollmentToken: enrollmentToken)
        case .logout:
            let result = logout()
            await finishPendingRemoteLogout()
            return result
        case .beginHostPairingFromQR(let payload): return await beginQR(payload)
        case .beginHostPairingWithCode(let code): return await beginCode(code)
        case .refreshHostPairing: return await refreshPairing()
        case .cancelHostPairing: return cancelPairing()
        case .selectHost(let id): return await selectHost(id)
        case .selectDirectoryView(let view):
            state.navigation.directoryView = view
            reproject()
            if negotiatedDirectory { return await loadDirectory(view == .tasks ? .tasks : .repos, reset: false) }
            return .applied
        case .setDirectoryTimeFilter(let view, let filter):
            guard readyScope() != nil else { return reject(.notAuthorized) }
            if view == .tasks { tasksTimeFilter = filter } else { reposTimeFilter = filter }
            reproject()
            return persistenceResult()
        case .selectConversation(let id): return await selectConversation(id)
        case .selectSearchResult(let id):
            guard state.directory.searchResults.contains(where: { $0.id == id }) else { return reject(.notFound) }
            guard let session = (sessions + searchHits).first(where: { $0.id == id && $0.authorized && !$0.archived }),
                  !taskRecords.contains(where: { $0.id == session.taskID && $0.status != .open }) else { return reject(.notFound) }
            temporarySearchResultID = id
            temporarySearchGeneration += 1
            directoryRequests[.search] = nil
            directoryViews[.search] = nil
            state.directory.searchQuery = ""
            reproject()
            return await selectConversation(id)
        case .openNewChat:
            temporarySearchResultID = nil
            navigationEpoch += 1
            state.navigation.destination = .newChat
            reproject()
            loadDraft(for: .newConversation)
            return .applied
        case .returnHome:
            guard readyScope() != nil else { return reject(.notAuthorized) }
            navigationEpoch += 1
            state.navigation.destination = .home
            state.navigation.settingsOpen = false
            reproject()
            return persistenceResult()
        case .openSettings:
            state.navigation.settingsOpen = true
            return .applied
        case .closeSettings:
            state.navigation.settingsOpen = false
            return .applied
        case .search(let query): return await search(query)
        case .loadMoreDirectory(let view): return await loadDirectory(view, reset: false)
        case .refreshDirectoryView(let view):
            return await manualRefreshDirectory(view)
        case .clearSearch:
            directoryRequests[.search] = nil
            directoryViews[.search] = nil
            state.directory.searchQuery = ""
            state.directory.searchResults = []
            searchHits = []
            reproject()
            return readyScope() == nil ? .applied : persistenceResult()
        case .pageOlderTranscript: return await pageOlder()
        case .retryTranscriptSync:
            guard let session = currentSessionID else { return reject(.notFound) }
            return await selectConversation(session)
        case .editDraftText(let text): return editDraft(text)
        case .addDraftAttachment(let input): return await addAttachment(input)
        case .removeDraftAttachment(let id): return removeAttachment(id)
        case .retryAttachmentUpload(let id): return await upload(id)
        case .downloadAttachment(let id): return await download(id)
        case .selectAgent(let id): return selectAgentForNewChat(id)
        case .selectModel(let model): return selectModelForNewChat(model)
        case .selectThinking(let thinking):
            state.composer.selection.thinking = thinking
            return persistenceResult()
        case .selectFast(let enabled):
            state.composer.selection.fast = enabled ? true : nil
            return persistenceResult()
        case .selectApprovalMode(let mode):
            state.composer.selection.approvalMode = mode
            return persistenceResult()
        case .loadAgentOptions(let id): return await loadAgentOptions(id)
        case .loadAgentLogos: return await loadAgentLogos()
        case .setConversationModel(let model): return await updateConversation(.model(model))
        case .setConversationThinking(let thinking): return await updateConversation(.thinking(thinking))
        case .setConversationFast(let enabled): return await updateConversation(.fast(enabled))
        case .setConversationApprovalMode(let mode): return await updateConversation(.approvalMode(mode))
        case .selectWorkspace(let id):
            state.composer.selection.workspaceID = id
            return persistenceResult()
        case .selectTask(let id):
            state.composer.selection.taskID = id
            return persistenceResult()
        case .send: return await performSend(explicitOriginal: false, reusedRequestID: nil)
        case .stop: return await stop()
        case .mutateQueue(let mutation): return await mutateQueue(mutation)
        case .recoverQueueCommand: return await recoverQueueCommand()
        case .recoverUncertainOperation: return await recover()
        case .retryUncertainCreate: return await retryCreate()
        case .respondToInteraction(let id, let actionID, let values):
            return await respond(id, actionID: actionID, values: values)
        case .setAutoTranslation(let enabled): return await setAuto(enabled)
        case .requestReadingTranslation(let sourceID, let text):
            return await requestReading(sourceID: sourceID, text: text)
        case .recoverReadingTranslation(let sourceID): return await recoverReading(sourceID)
        case .cancelReadingTranslation(let sourceID): return await cancelReading(sourceID)
        case .retryTranslationText(let id): return await pageTranslation(id)
        case .retryTranslationSend: return await retryTranslation()
        case .sendOriginal: return await sendOriginal()
        case .reclaimTranslationDraft: return await reclaim()
        case .dismissBanner(let id):
            state.banners.removeAll { $0.id == id }
            return .applied
        case .openBanner(let id): return await openBanner(id)
        case .noteLocalConnectivity(let connectivity):
            if connectivity == .unavailable, state.phase == .serverEntered, state.account.status == .pending {
                epoch += 1
                state.account.status = .error
            }
            let result = noteConnectivity(connectivity)
            if connectivity == .unavailable, let lifecycle = service as? any GianClientLifecycle { await lifecycle.disconnect() }
            return result
        case .setForeground(let presence):
            state.foreground = presence
            if presence == .background { cancelRetentionExpiry() }
            if readyScope() != nil { reproject() }
            if presence == .background {
                if state.phase == .serverEntered, state.account.status == .pending {
                    epoch += 1
                    state.account.status = .error
                }
                let result = readyScope() != nil ? persistenceResult() : .applied
                if let lifecycle = service as? any GianClientLifecycle { await lifecycle.disconnect() }
                return result
            }
            return recoverLocalStorage()
        case .refreshDirectory: return await refresh()
        case .retrySynchronization:
            guard let eventCoordinator else { return reject(.capabilityUnsupported) }
            return await eventCoordinator.refreshConnection()
        case .clearAttachmentCache: return clearCache()
        }
    }

    @discardableResult
    public func ingest(_ envelope: InboundEnvelope) -> GianDispatchResult {
        synchronizeServiceEpoch()
        guard let scope = readyScope(), scope == envelope.scope else { return reject(.scopeMismatch) }
        guard envelope.serviceEpoch == expectedServiceEpoch else { return reject(.staleOperation) }
        if storageWritesBlocked {
            if case .commandStatus = envelope.event {} else { return reject(.mutationsDisabled) }
        }
        switch envelope.event {
        case .directory(let snapshot):
            return applySnapshot(snapshot, scope: scope)
        case .directoryChanged(let generation, _):
            guard negotiatedDirectory, generation == state.sync.cursor?.hostGeneration else { return reject(.staleOperation) }
            invalidateDirectoryViews()
            directoryRefreshPending = true
            schedulePersistence()
            return .applied
        case .sessionMetadata(let session, let interactions):
            guard negotiatedDirectory, session.hostID == scope.host, session.id == currentSessionID,
                  interactions.allSatisfy({ $0.sessionID == session.id }) else { return reject(.staleOperation) }
            guard !deniedSessionAccess.contains(session.id), pendingSessionAccess[session.id] == nil else { return .applied }
            upsertSession(session)
            state.conversation?.session = sessions.first { $0.id == session.id } ?? session
            let prior = state.interactions
            state.interactions = prior.filter { $0.sessionID != session.id } + interactions.map { incoming in
                var next = incoming
                if let old = prior.first(where: { $0.id == incoming.id }), old.phase == .uncertain || old.phase == .responding { next.phase = .uncertain }
                return next
            }
            reproject()
            return persistenceResult()
        case .sessionUnavailable(let session):
            guard negotiatedDirectory else { return reject(.staleOperation) }
            return applySessionUnavailable(session)
        case .canonical(let sequence, let generation, let body):
            return applyCanonical(sequence: sequence, generation: generation, body: body)
        case .statePatch(let sequence, let generation, let base, let revision, let patch):
            return applyStatePatch(sequence: sequence, generation: generation, baseRevision: base, revision: revision, patch: patch)
        case .transcript(let sessionID, let item):
            guard !state.sync.needsSnapshot else { return .applied }
            return applyTranscript(sessionID: sessionID, item: item)
        case .translation(let sessionID, let update):
            guard !state.sync.needsSnapshot else { return .applied }
            return applyTranslationEvent(sessionID: sessionID, update: update)
        case .snapshotRequired(let reason):
            if let producer = service as? any DirectoryReadinessReporting, producer.acceptedDirectory != nil {
                // Do not let an old stream signal undo the producer's fresh
                // snapshot, or clear an independent local resync requirement.
                return .applied
            }
            markTranscriptCatchUp()
            state.sync.needsSnapshot = true
            state.sync.reason = reason
            if state.connection == .online { state.connection = .resyncing }
            schedulePersistence()
            return .applied
        case .commandStatus(let status):
            if case .uncertain = state.composer.send { resolveCommand(status) }
            else if state.composer.send.isInFlight, state.composer.send.intent?.stage == .send {
                resolveCommand(status)
            }
            _ = resolveAuxiliaryCommand(status)
            return persistenceResult()
        }
    }

    func reject(_ code: RejectionCode) -> GianDispatchResult { .rejected(code) }

    func readyScope() -> ClientScope? {
        guard state.phase == .ready,
              state.account.status == .signedIn,
              let server = state.server,
              let account = state.account.accountID,
              let host = state.currentHostID
        else { return nil }
        return ClientScope(server: server, account: account, host: host)
    }

    func accountScope() -> DataScope? {
        guard let server = state.server, let account = state.account.accountID else { return nil }
        return DataScope(server: server, account: account)
    }

    func mint<Kind>() -> ScopedID<Kind> {
        let raw = ids.next(at: clock.now())
        if let id = ScopedID<Kind>(rawValue: raw) { return id }
        return ScopedID(trusted: raw)
    }

    func requireCapability(_ capability: BusinessCapability) -> RejectionCode? {
        switch state.capabilities.state(of: capability) {
        case .supported: return nil
        case .denied: return .capabilityDenied
        case .unsupported, .offline, .versionMismatch: return .capabilityUnsupported
        }
    }

    func mutationsAllowed() -> Bool {
        guard directoryReadyForRecovery(), !sessionAccessOverflow, let scope = readyScope() else { return false }
        if let bound = state.composer.draft.boundSessionID,
           pendingSessionAccess[bound] != nil || deniedSessionAccess.contains(bound) { return false }
        if case .conversation(let draftSession) = state.composer.draft.target,
           pendingSessionAccess[draftSession] != nil || deniedSessionAccess.contains(draftSession) { return false }
        if let session = currentSessionID {
            return state.conversation?.session.id == session
                && pendingSessionAccess[session] == nil && !deniedSessionAccess.contains(session)
                && state.conversation?.hydratedFromCache == false
                && state.conversation?.transcriptSync == .idle
                && memory.bundle(for: scope).transcriptCursors[session]?.catchUp == nil
        }
        return true
    }

    func directoryReadyForRecovery() -> Bool {
        guard let scope = readyScope(), !storageLoadFailed, !storageWritesBlocked, !requiresFreshSnapshot, !state.sync.needsSnapshot,
              state.localConnectivity == .available, state.foreground == .foreground, state.connection == .online else { return false }
        if let source = service as? any GianClientEventSource {
            guard expectedServiceEpoch == source.eventEpoch, readyServiceEpoch == source.eventEpoch else { return false }
        }
        if let producer = service as? any DirectoryReadinessReporting {
            guard let accepted = producer.acceptedDirectory, accepted.scope == scope,
                  accepted.cursor == state.sync.cursor, accepted.catalogRevision == state.catalogRevision else { return false }
        }
        return true
            && ((service as? any GianClientEventSource).map({ $0.eventEpoch == expectedServiceEpoch }) ?? true)
            && (!(service is any GianClientEventSource) || eventCoordinator?.isRunning == true)
    }

    var currentSessionID: SessionID? {
        if case .conversation(let id) = state.navigation.destination { return id }
        return nil
    }

    func rememberDraft() {
        guard state.composer.draft.hostID != nil else { return }
        // Read the ID before mutating: reading `state` inside the closure while
        // `removeAll` holds write access to it is an exclusivity violation.
        let draftID = state.composer.draft.id
        state.drafts.removeAll { $0.id == draftID }
        state.drafts.append(state.composer.draft)
    }

    func noteDraftEdited() {
        state.composer.draft.localRevision += 1
        state.composer.draft.updatedAt = clock.now()
        switch state.composer.send {
        case .succeeded, .failed:
            if let scope = readyScope() { memory.update(scope) { $0.submittedDrafts[state.composer.draft.id] = nil } }
            state.composer.send = .idle
            state.composer.notice = .none
        case .idle, .uncertain, .creating, .awaitingTranslation, .sending: break
        }
    }

    func loadDraft(for target: DraftTarget) {
        if state.composer.draft.hostID == state.currentHostID { persist() }
        if let existing = state.drafts.first(where: { $0.hostID == state.currentHostID && $0.target == target }) {
            state.composer.draft = existing
            restoreComposerOperation()
            return
        }
        state.composer.draft = DraftDocument(
            id: mint(),
            hostID: state.currentHostID,
            target: target,
            text: "",
            attachments: [],
            updatedAt: clock.now()
        )
        restoreComposerOperation()
    }

    func restoreComposerOperation() {
        let bundle = readyScope().map { memory.bundle(for: $0) }
        state.composer.send = bundle?.operations[state.composer.draft.id] ?? .idle
        state.composer.selection = bundle?.selections[state.composer.draft.id] ?? ComposerSelection()
        if case .uncertain = state.composer.send { state.composer.notice = .keptAfterUncertainOutcome }
        else { state.composer.notice = .none }
    }

    func reproject() {
        let query = state.directory.searchQuery
        let projection = DirectoryFilter.project(
            now: clock.now(),
            authority: state.directory.authority,
            tasks: taskRecords,
            sessions: sessions,
            workspaces: state.workspaces,
            query: query.isEmpty ? nil : query,
            searchCandidates: searchHits
        )
        let evaluated = clock.now()
        state.directory = DirectoryProjection(
            authority: state.directory.authority,
            tasks: projection.tasks,
            repos: projection.repos,
            reposSupport: projection.reposSupport,
            searchSupport: projection.searchSupport,
            searchQuery: query,
            searchResults: projection.searchResults,
            evaluatedAt: evaluated,
            legacyLimitations: projection.limitations
        )
        state.directory.tasksTimeFilter = tasksTimeFilter
        state.directory.reposTimeFilter = reposTimeFilter
        state.directory.temporarySearchGeneration = temporarySearchGeneration
        if state.directory.authority == .negotiatedDirectoryV1 {
            projectDirectoryMembership(now: evaluated)
        } else {
            state.directory.tasks = state.directory.tasks.filter { section in
                section.conversations.contains { summary in
                    sessions.contains { $0.id == summary.id && tasksTimeFilter.includes($0, now: evaluated) }
                }
            }
        }
        if let id = temporarySearchResultID,
           let session = (sessions + searchHits).first(where: { $0.id == id && $0.authorized && !$0.archived }),
           directoryViews[.tasks]?.status.phase != .denied,
           !taskRecords.contains(where: { $0.id == session.taskID && $0.status != .open }) {
            let names = state.workspaces.reduce(into: [WorkspaceID: String]()) { $0[$1.id] = $1.name }
            state.directory.temporarySearchResult = DirectoryFilter.summary(session, names: names)
        }
        projectDirectoryStatus()
        state.openTasks = taskRecords.filter { $0.status == .open }.sorted { $0.id.rawValue < $1.id.rawValue }
        scheduleDirectoryExpiry(now: evaluated)
    }

    @discardableResult
    func persist() -> Bool {
        pendingPersistence?.cancel()
        pendingPersistence = nil
        pendingEventCount = 0
        guard let scope = readyScope(), !storageLoadFailed else { return false }
        let host = scope.host
        rememberDraft()
        memory.update(scope) { bundle in
            // Reopened on restore, so only where the user actually was: from
            // Home, switching Hosts (or relaunching) must not land in New chat.
            bundle.activeDraftID = state.navigation.destination == .home ? nil : state.composer.draft.id
            bundle.drafts = state.drafts.filter { $0.hostID == host }
            for draft in bundle.drafts + Array(bundle.submittedDrafts.values) {
                let owner: SessionID?
                if case .conversation(let id) = draft.target { owner = id }
                else { owner = draft.boundSessionID }
                if let owner {
                    for attachment in draft.attachments { bundle.noteDownloadOwner(attachment.id, session: owner) }
                }
            }
            bundle.sessions = sessions
            bundle.tasks = taskRecords
            bundle.workspaces = state.workspaces
            bundle.agents = state.agents
            bundle.interactions = state.interactions
            bundle.cursor = state.sync.cursor
            bundle.needsSnapshot = state.sync.needsSnapshot
            bundle.translations = state.translations
            bundle.catalogRevision = state.catalogRevision
            bundle.capabilities = state.capabilities
            bundle.authority = state.directory.authority
            bundle.host = state.hosts.first { $0.id == host }
            bundle.searchHits = searchHits
            bundle.directoryViews = directoryViews
            bundle.tasksTimeFilter = tasksTimeFilter
            bundle.reposTimeFilter = reposTimeFilter
            bundle.pendingSessionAccessIDs = pendingSessionAccess.isEmpty ? nil : pendingSessionAccess.keys.sorted { $0.rawValue < $1.rawValue }
            bundle.deniedSessionAccessIDs = deniedSessionAccess.isEmpty ? nil : deniedSessionAccess.sorted { $0.rawValue < $1.rawValue }
            bundle.sessionAccessOverflow = sessionAccessOverflow ? true : nil
            let pendingQueue = state.queueCommands.compactMapValues { value -> CommandID? in
                switch value {
                case .pending(let id), .uncertain(let id): id
                case .failed: nil
                }
            }
            bundle.pendingQueueCommands = pendingQueue.isEmpty ? nil : pendingQueue
            bundle.selections[state.composer.draft.id] = state.composer.selection
            bundle.pendingStop = state.pendingStop
            if let intent = state.composer.send.intent, state.composer.send.isInFlight || isUncertain(state.composer.send) {
                var saved = state.composer.send
                if state.composer.send.isInFlight, let intent = state.composer.send.intent {
                    saved = .uncertain(intent)
                }
                bundle.operations[intent.draftID] = saved
            } else if case .idle = state.composer.send {
                bundle.operations[state.composer.draft.id] = nil
            } else {
                bundle.operations[state.composer.draft.id] = state.composer.send
            }
        }
        do {
            try memory.commit(scope)
            storageWritesBlocked = false
            state.storageError = nil
            if memory.needsRetentionRecovery(scope) { scheduleRetentionRecovery(scope) }
            scheduleRetentionExpiry(scope)
            return true
        } catch {
            let wasBlocked = storageWritesBlocked
            storageWritesBlocked = true
            requiresFreshSnapshot = true
            state.sync.needsSnapshot = true
            state.connection = .offline
            state.storageError = "Local storage is unavailable. Changes have not been saved."
            if (error as? GianStorageError) == .unavailable, memory.needsRetentionRecovery(scope) { scheduleRetentionRecovery(scope) }
            if !wasBlocked { eventCoordinator?.storageBecameUnavailable() }
            return false
        }
    }

    func persistenceResult() -> GianDispatchResult { persist() ? .applied : reject(.mutationsDisabled) }

    /// Coalesces noncritical streaming writes; command intents always bypass this
    /// queue and commit synchronously. Lifecycle/background handlers flush too.
    func schedulePersistence() {
        pendingEventCount += 1
        if pendingEventCount >= 64 { persist(); return }
        guard pendingPersistence == nil else { return }
        let token = epoch
        pendingPersistence = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, token == self.epoch else { return }
            self.pendingPersistence = nil
            self.persist()
        }
    }

    @discardableResult
    public func flushStorage() -> GianDispatchResult { persistenceResult() }

    @discardableResult
    func restore(host: HostID) -> Bool {
        guard let scope = readyScope(), scope.host == host else { return false }
        do { try memory.load(scope) }
        catch {
            storageLoadFailed = true
            state.storageError = "Local history could not be opened. No data was replaced."
            if (error as? GianStorageError) == .unavailable, memory.needsRetentionRecovery(scope) { scheduleRetentionRecovery(scope) }
            return false
        }
        storageLoadFailed = false
        state.storageError = nil
        memory.update(scope) { $0 = $0.recovered() }
        let bundle = memory.bundle(for: scope)
        sessions = bundle.sessions.filter { $0.hostID == host }
        let restoredDenials = Set(sessions.filter { !$0.authorized }.map(\.id) + bundle.searchHits.filter { !$0.authorized }.map(\.id))
            .union(bundle.deniedSessionAccessIDs ?? [])
        deniedSessionAccess = Set(restoredDenials.sorted { $0.rawValue < $1.rawValue }.prefix(4_096))
        sessionAccessOverflow = bundle.sessionAccessOverflow == true || restoredDenials.count > 4_096
        pendingSessionAccess = [:]
        for id in bundle.pendingSessionAccessIDs ?? [] {
            sessionAccessSequence += 1
            pendingSessionAccess[id] = sessionAccessSequence
        }
        taskRecords = bundle.tasks
        state.workspaces = bundle.workspaces
        state.agents = bundle.agents
        state.interactions = bundle.interactions
        state.translations = bundle.translations
        state.catalogRevision = bundle.catalogRevision
        state.capabilities = bundle.capabilities
        state.directory.authority = bundle.authority
        state.sync.cursor = bundle.cursor
        state.sync.needsSnapshot = bundle.needsSnapshot
        searchHits = bundle.searchHits
        directorySequence += 1
        directoryViews = bundle.directoryViews ?? [:]
        temporarySearchResultID = nil
        tasksTimeFilter = bundle.tasksTimeFilter ?? .last7Days
        reposTimeFilter = bundle.reposTimeFilter ?? .last7Days
        state.queueCommands = (bundle.pendingQueueCommands ?? [:]).mapValues { .uncertain($0) }
        state.directory.searchQuery = directoryViews[.search]?.query ?? ""
        state.drafts = bundle.drafts.filter { $0.hostID == host }
        state.composer.draft = DraftDocument.placeholder(now: clock.now())
        state.composer.send = .idle
        state.pendingStop = bundle.pendingStop
        if let active = bundle.drafts.first(where: { $0.id == bundle.activeDraftID }) {
            state.composer.draft = active
            restoreComposerOperation()
            if case .conversation(let id) = active.target,
               let session = (sessions + searchHits).first(where: { $0.id == id && $0.authorized && !$0.archived }) {
                state.navigation.destination = .conversation(id)
                let stored = bundle.transcriptCursors[id]
                let cursor = stored?.hostGeneration != nil && stored?.hostGeneration == bundle.cursor?.hostGeneration ? stored : nil
                state.conversation = ConversationProjection(session: session, items: bundle.transcripts[id] ?? [],
                    cursor: cursor?.cursor, hasOlder: cursor?.hasOlder ?? true, hydratedFromCache: true)
            } else {
                state.navigation.destination = .newChat
            }
        } else { loadDraft(for: .newConversation) }
        if let saved = bundle.operations[state.composer.draft.id] {
            switch saved {
            case .creating(let intent), .awaitingTranslation(let intent), .sending(let intent), .uncertain(let intent):
                state.composer.send = .uncertain(intent)
                state.composer.notice = .keptAfterUncertainOutcome
            case .idle, .failed, .succeeded:
                state.composer.send = saved
            }
        }
        reproject()
        // Apply expired-cache retention even when the Host stays offline.
        _ = persist()
        return true
    }

    func upsertSession(_ session: SessionRecord) {
        // Another Host's record would fail every later commit's scope check.
        guard session.hostID == state.currentHostID, !deniedSessionAccess.contains(session.id),
              sessions.first(where: { $0.id == session.id })?.authorized != false,
              !sessionAccessOverflow || sessions.contains(where: { $0.id == session.id && $0.authorized }) else { return }
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            let previous = sessions[index]
            sessions[index] = session
            if !session.activityIsMessageOrExecution {
                sessions[index].lastActivityAt = previous.lastActivityAt
                sessions[index].activityIsMessageOrExecution = previous.activityIsMessageOrExecution
            }
            if session.completedAt == nil { sessions[index].completedAt = previous.completedAt }
        } else {
            sessions.append(session)
        }
        noteRetentionActivity(session)
    }

    func recordSessionDenial(_ id: SessionID) {
        if deniedSessionAccess.contains(id) || deniedSessionAccess.count < 4_096 { deniedSessionAccess.insert(id) }
        else { sessionAccessOverflow = true }
    }

    func noteRetentionActivity(_ session: SessionRecord) {
        guard session.authorized, !session.archived, session.activityIsMessageOrExecution,
              let at = session.lastActivityAt, at.timeIntervalSince1970.isFinite,
              let scope = readyScope(), session.hostID == scope.host else { return }
        memory.noteRetentionActivity(session, scope: scope, at: at)
    }

    private func isUncertain(_ phase: SendPhase) -> Bool {
        if case .uncertain = phase { return true }
        return false
    }

    private func setServer(_ raw: String) -> GianDispatchResult {
        guard state.phase == .signedOut || state.phase == .serverEntered else { return reject(.staleOperation) }
        guard let server = ServerAddress(parsing: raw) else { return reject(.invalidServerAddress) }
        epoch += 1
        state.server = server
        state.account = .signedOut
        serviceDiagnostic = nil
        expectedServiceEpoch = nil
        state.phase = .serverEntered
        state.connection = .signedOut
        return .applied
    }

    /// Verifies the Server's identity (pinned on first use) and prepares this
    /// app's controller identity there. A Server already used on this device
    /// restores its paired Hosts; otherwise Host pairing comes next.
    private func connectServer(enrollmentToken: String?) async -> GianDispatchResult {
        guard let server = state.server, state.phase == .serverEntered else { return reject(.notAuthorized) }
        epoch += 1
        state.account = AccountAuthorization(status: .pending)
        let token = epoch
        let enrollment = enrollmentToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let response = await service.connectServer(server: server, enrollmentToken: enrollment?.isEmpty == false ? enrollment : nil)
        guard token == epoch, state.server == server else { return reject(.staleOperation) }
        switch response {
        case .failed(let message):
            state.account = AccountAuthorization(status: .error, failure: message)
            return .applied
        case .identityChanged:
            state.account = AccountAuthorization(status: .serverIdentityChanged)
            return reject(.serverIdentityChanged)
        case .connected(let identity):
            if let live = service as? LiveGianClientService {
                do {
                    if let authorization = try live.loadCachedAuthorization(server: server, account: identity.account),
                       !authorization.hosts.isEmpty {
                        let result = restoreAuthorizedSession(authorization: authorization)
                        guard result.isApplied else { return result }
                        if readyScope() != nil { return await refresh() }
                        return .applied
                    }
                } catch {
                    state.account = AccountAuthorization(status: .error, failure: (error as? RemoteClientError)?.safeDescription)
                    return reject(.notAuthorized)
                }
            }
            state.account = AccountAuthorization(status: .signedIn, accountID: identity.account,
                                                 installationID: identity.installationID)
            state.phase = .awaitingHostPairing
            return .applied
        }
    }

    func logout(invalidateRemote: Bool = true) -> GianDispatchResult {
        clearTranscriptFileCache()
        if invalidateRemote, let scope = accountScope(), service is any GianClientLifecycle {
            pendingRemoteLogout = scope
            serverOutcomeUnconfirmed = true
        }
        if let scope = accountScope() {
            let now = clock.now()
            invalidatedAuthorizations[scope] = max(invalidatedAuthorizations[scope] ?? now, now)
            do {
                try memory.invalidateAuthorization(scope: scope, at: now)
                authorizationInvalidationUnconfirmed = false
            } catch {
                authorizationInvalidationUnconfirmed = true
                state.storageError = "Signed out locally. Durable authorization removal could not be confirmed."
            }
        }
        if state.composer.send.isInFlight, let intent = state.composer.send.intent {
            state.composer.send = .uncertain(intent)
            state.composer.notice = .keptAfterUncertainOutcome
        }
        persist()
        let storageError = state.storageError
        epoch += 1
        let connectivity = state.localConnectivity
        expectedServiceEpoch = nil
        let foreground = state.foreground
        state = .signedOut()
        state.storageError = storageError
        serviceDiagnostic = nil
        state.localConnectivity = connectivity
        state.foreground = foreground
        sessions = []
        taskRecords = []
        searchHits = []
        directoryViews = [:]
        manualDirectoryRecoveries = [:]
        temporarySearchResultID = nil
        locallyCreatedSessions = []; locallyCreatedWithActivity = []
        pendingSessionAccess = [:]; deniedSessionAccess = []; sessionAccessOverflow = false
        directoryExpiryTask?.cancel(); directoryExpiryTask = nil
        cancelRetentionExpiry()
        directoryRefreshPending = false
        memory.discardCommitted()
        storageLoadFailed = false
        requiresFreshSnapshot = true
        return .applied
    }

    /// Restores only the selected, evidenced Host's local cache. Neither cached
    /// capabilities nor an earlier online validation enable commands here.
    @discardableResult
    public func restoreAuthorizedSession(
        authorization: AuthorizedSessionRestoration,
        selectedHost: HostID? = nil
    ) -> GianDispatchResult {
        guard remoteLogoutTask == nil, pendingRemoteLogout == nil else { return reject(.operationInFlight) }
        let now = clock.now()
        let identity = authorization.identity
        let data = DataScope(server: authorization.server, account: identity.account)
        let invalidatedAt: Date?
        do {
            let durable = try memory.authorizationInvalidatedAt(scope: data)
            invalidatedAt = [durable, invalidatedAuthorizations[data]].compactMap { $0 }.max()
        } catch {
            state.storageError = "Local authorization safety could not be verified."
            return reject(.notAuthorized)
        }
        guard authorization.accountLastVerifiedAt <= now,
              invalidatedAt.map({ authorization.accountLastVerifiedAt > $0 }) ?? true,
              ServerAddress(parsing: authorization.server.absoluteString) == authorization.server,
              AccountID(provider: identity.account.provider, id: identity.account.id) == identity.account,
              InstallationID(rawValue: identity.installationID.rawValue) != nil,
              !authorization.serverIdentityFingerprint.isEmpty, !authorization.accountKeyFingerprint.isEmpty,
              Set(authorization.hosts.map { $0.host.id }).count == authorization.hosts.count,
              authorization.hosts.allSatisfy({ host in
                  HostID(rawValue: host.host.id.rawValue) != nil && DeviceID(rawValue: host.deviceID.rawValue) != nil
                      && !host.hostKeyFingerprint.isEmpty && !host.deviceKeyFingerprint.isEmpty && host.lastVerifiedAt <= now
                      && (invalidatedHosts[ClientScope(server: authorization.server, account: identity.account, host: host.host.id)]
                          .map({ host.lastVerifiedAt > $0 }) ?? true)
              }) else { return reject(.notAuthorized) }
        if let pin = serverPins[authorization.server], pin != authorization.serverIdentityFingerprint {
            return reject(.notAuthorized)
        }
        let host = selectedHost ?? authorization.hosts.first?.host.id
        guard host == nil || authorization.hosts.contains(where: { $0.host.id == host }) else { return reject(.scopeMismatch) }
        if state.account.accountID == identity.account, state.server == authorization.server,
           let installation = state.account.installationID, installation != identity.installationID {
            return reject(.scopeMismatch)
        }
        if readyScope() != nil { persist() }
        clearTranscriptFileCache()
        memory.discardCommitted()
        let previousStorageError = state.storageError
        let connectivity = state.localConnectivity
        let foreground = state.foreground
        if let previous = accountScope(), previous != data { invalidatedAuthorizations[previous] = now }
        epoch += 1
        navigationEpoch += 1
        expectedServiceEpoch = nil
        state = .signedOut()
        state.localConnectivity = connectivity
        state.foreground = foreground
        state.storageError = previousStorageError
        serviceDiagnostic = nil
        sessions = []
        taskRecords = []
        searchHits = []
        directoryViews = [:]
        manualDirectoryRecoveries = [:]
        temporarySearchResultID = nil
        locallyCreatedSessions = []; locallyCreatedWithActivity = []
        pendingSessionAccess = [:]; deniedSessionAccess = []; sessionAccessOverflow = false
        directoryExpiryTask?.cancel(); directoryExpiryTask = nil
        cancelRetentionExpiry()
        directoryRefreshPending = false
        storageLoadFailed = false
        state.server = authorization.server
        state.account = AccountAuthorization(status: .signedIn, accountID: identity.account,
                                             installationID: identity.installationID)
        state.hosts = authorization.hosts.map(\.host)
        state.currentHostID = host
        serverPins[authorization.server] = authorization.serverIdentityFingerprint
        requiresFreshSnapshot = true
        state.connection = .offline
        guard let host else {
            state.phase = .awaitingHostPairing
            return .applied
        }
        state.phase = .ready
        guard restore(host: host) else { return reject(.mutationsDisabled) }
        if let previousStorageError { state.storageError = previousStorageError }
        state.sync.needsSnapshot = true
        state.capabilities = .empty
        return .applied
    }

    /// Setup pairs the first Host; once ready, the same flow adds another
    /// Host while the current one stays open.
    private func beginQR(_ payload: String) async -> GianDispatchResult {
        guard let server = state.server else { return reject(.notAuthorized) }
        switch PairingQR.parse(payload: payload, server: server) {
        case .failure(let code):
            state.pairingOutcome = .invalidCode
            return reject(code)
        case .success(let invitation):
            return await claim(invitation)
        }
    }

    private func beginCode(_ input: String) async -> GianDispatchResult {
        guard let code = PairingCode.canonical(input) else {
            state.pairingOutcome = .invalidCode
            return reject(.pairingQRInvalid)
        }
        return await claim(.code(code))
    }

    private func claim(_ invitation: HostPairingInvitation) async -> GianDispatchResult {
        guard state.phase == .awaitingHostPairing || state.phase == .ready,
              let server = state.server, let account = state.account.accountID else {
            return reject(.notAuthorized)
        }
        state.pairingOutcome = nil
        let token = epoch
        let sequence = pairingSequence
        let response = await service.claimHost(server: server, account: account, invitation: invitation)
        guard token == epoch, sequence == pairingSequence else { return reject(.staleOperation) }
        return await finishPairing(response)
    }

    private func refreshPairing() async -> GianDispatchResult {
        guard let pending = state.pendingPairing, let server = state.server, let account = state.account.accountID else {
            return reject(.notFound)
        }
        let token = epoch
        let sequence = pairingSequence
        let response = await service.refreshHostPairing(server: server, account: account, pairingID: pending.pairingID)
        guard token == epoch, sequence == pairingSequence, state.pendingPairing == pending else { return reject(.staleOperation) }
        return await finishPairing(response)
    }

    private func cancelPairing() -> GianDispatchResult {
        pairingSequence += 1
        state.pendingPairing = nil
        state.pairingOutcome = nil
        return .applied
    }

    private func finishPairing(_ response: HostPairingResponse) async -> GianDispatchResult {
        // Adding a Host: stay on the current Host until the new one is confirmed.
        let addingHost = state.phase == .ready
        switch response {
        case .pendingConfirmation(let pairingID, let hostID):
            state.pendingPairing = PendingHostPairing(pairingID: pairingID, hostID: hostID)
            if !addingHost { state.phase = .awaitingHostPairing }
            return .applied
        case .rejected, .expired, .failed:
            state.pendingPairing = nil
            switch response {
            case .rejected: state.pairingOutcome = .rejected
            case .expired: state.pairingOutcome = .expired
            case .failed(let message): state.pairingOutcome = .failed(message)
            default: break
            }
            if !addingHost { state.phase = .awaitingHostPairing }
            return .applied
        case .confirmed(let host, _):
            state.pendingPairing = nil
            state.pairingOutcome = .paired(host.id)
            if !state.hosts.contains(where: { $0.id == host.id }) { state.hosts.append(host) }
            if addingHost { return await selectHost(host.id) }
            state.currentHostID = host.id
            expectedServiceEpoch = nil
            requiresFreshSnapshot = true
            state.phase = .ready
            state.connection = state.localConnectivity == .available ? .resyncing : .offline
            guard restore(host: host.id) else { return reject(.mutationsDisabled) }
            return await refresh()
        }
    }

    private func selectHost(_ id: HostID) async -> GianDispatchResult {
        guard state.phase == .ready, state.hosts.contains(where: { $0.id == id }) else { return reject(.notFound) }
        clearTranscriptFileCache()
        persist()
        let previousStorageError = state.storageError
        memory.discardCommitted()
        epoch += 1
        navigationEpoch += 1
        expectedServiceEpoch = nil
        state.currentHostID = id
        serviceDiagnostic = nil
        state.navigation = .home
        state.banners = []
        state.queueCommands = [:]
        state.conversation = nil
        state.composer = ComposerProjection(selection: ComposerSelection(), draft: .placeholder(now: clock.now()), send: .idle, notice: .none)
        state.drafts = []
        state.translations = [:]
        state.interactions = []
        state.sync = SyncProjection(cursor: nil, needsSnapshot: true, reason: .generationChanged)
        sessions = []
        taskRecords = []
        searchHits = []
        directoryViews = [:]
        manualDirectoryRecoveries = [:]
        temporarySearchResultID = nil
        locallyCreatedSessions = []; locallyCreatedWithActivity = []
        pendingSessionAccess = [:]; deniedSessionAccess = []; sessionAccessOverflow = false
        directoryExpiryTask?.cancel(); directoryExpiryTask = nil
        cancelRetentionExpiry()
        directoryRefreshPending = false
        guard restore(host: id) else { return reject(.mutationsDisabled) }
        if let previousStorageError { state.storageError = previousStorageError }
        requiresFreshSnapshot = true
        state.sync.needsSnapshot = true
        state.connection = state.localConnectivity == .available ? .resyncing : .offline
        return await refresh()
    }

    func selectConversation(_ id: SessionID) async -> GianDispatchResult {
        guard let scope = readyScope(), let session = (sessions + searchHits).first(where: { $0.id == id && $0.authorized && !$0.archived }) else { return reject(.notFound) }
        if temporarySearchResultID != id { temporarySearchResultID = nil }
        navigationEpoch += 1
        state.navigation.destination = .conversation(id)
        reproject()
        state.navigation.settingsOpen = false
        loadDraft(for: .conversation(id))
        let cached = memory.bundle(for: scope).transcripts[id] ?? []
        let storedCursor = memory.bundle(for: scope).transcriptCursors[id]
        let savedCursor = storedCursor?.hostGeneration != nil && storedCursor?.hostGeneration == state.sync.cursor?.hostGeneration ? storedCursor : nil
        state.conversation = ConversationProjection(
            session: session,
            items: cached,
            cursor: savedCursor?.cursor,
            hasOlder: savedCursor?.hasOlder ?? true,
            hydratedFromCache: !cached.isEmpty,
            transcriptSync: .syncing
        )
        let sync = beginTranscriptSync(session: id)
        let token = epoch
        let navigation = navigationEpoch
        let page = await service.pageTranscript(scope: scope, sessionID: id, cursor: nil)
        guard responseIsCurrent(token), state.currentHostID == scope.host else {
            finishTranscriptSync(sync, session: id, state: .failed)
            return reject(.staleOperation)
        }
        guard !page.failed else {
            finishTranscriptSync(sync, session: id, state: .failed)
            return .applied
        }
        let current = memory.bundle(for: scope).transcripts[id] ?? []
        let anchors = Set(cached.suffix(256).map(\.id))
        let reachedRetainedHistory = anchors.isEmpty || !page.hasOlder || !anchors.isDisjoint(with: page.items.map(\.id))
        let needsCatchUp = storedCursor?.catchUp != nil || !reachedRetainedHistory || current != cached
        let merged = TranscriptLog.mergePage(baseline: cached, current: current, page: page.items)
        if navigation == navigationEpoch, currentSessionID == id {
            state.conversation?.items = merged
            state.conversation?.cursor = savedCursor?.cursor ?? page.cursor
            state.conversation?.hasOlder = savedCursor?.hasOlder ?? page.hasOlder
            state.conversation?.hydratedFromCache = needsCatchUp
        }
        memory.update(scope) {
            $0.transcripts[id] = merged
            if savedCursor == nil {
                var cursor = StoredTranscriptCursor(cursor: page.cursor, hasOlder: page.hasOlder)
                cursor.hostGeneration = state.sync.cursor?.hostGeneration
                cursor.catchUp = storedCursor?.catchUp
                $0.transcriptCursors[id] = cursor
            }
            if needsCatchUp, $0.transcriptCursors[id]?.catchUp == nil {
                $0.transcriptCursors[id]?.catchUp = StoredTranscriptCatchUp(anchorIDs: Array(anchors).sorted { $0.rawValue < $1.rawValue })
            }
        }
        if navigation == navigationEpoch, currentSessionID == id,
           (sessions + searchHits).contains(where: { $0.id == id && $0.authorized && !$0.archived }),
           let tail = memory.retentionTailIDs(scope, session: id) {
            let reachedTail = tail.isEmpty || !page.hasOlder || !tail.isDisjoint(with: page.items.map(\.id))
            memory.noteRetentionItems(page.items, session: id, scope: scope, hydrated: reachedTail && current == cached)
        }
        let result = persistenceResult()
        finishTranscriptSync(sync, session: id, state: result.isApplied ? (needsCatchUp ? .syncing : .idle) : .failed)
        return result
    }

    func beginTranscriptSync(session: SessionID) -> (sequence: Int, epoch: Int) {
        transcriptSyncSequence += 1
        if currentSessionID == session { state.conversation?.transcriptSync = .syncing }
        return (transcriptSyncSequence, epoch)
    }

    func finishTranscriptSync(_ ticket: (sequence: Int, epoch: Int), session: SessionID, state value: TranscriptSyncState) {
        guard ticket.sequence == transcriptSyncSequence, ticket.epoch == epoch, currentSessionID == session,
              state.conversation?.session.id == session else { return }
        state.conversation?.transcriptSync = value
    }

    private func openBanner(_ id: BannerID) async -> GianDispatchResult {
        guard let banner = state.banners.first(where: { $0.id == id }) else { return reject(.notFound) }
        state.banners.removeAll { $0.id == id }
        return await selectConversation(banner.sessionID)
    }

    private func noteConnectivity(_ connectivity: LocalConnectivity) -> GianDispatchResult {
        state.localConnectivity = connectivity
        guard state.phase == .ready else { return .applied }
        if connectivity == .unavailable {
            markTranscriptCatchUp()
            state.connection = .offline
            requiresFreshSnapshot = true
            state.sync.needsSnapshot = true
            state.sync.reason = .cryptoResumed
        } else if state.connection == .offline {
            state.connection = .resyncing
        }
        persist()
        return .applied
    }

    private func editDraft(_ text: String) -> GianDispatchResult {
        guard readyScope() != nil else { return reject(.notAuthorized) }
        guard text.utf8.count <= 2 * 1024 * 1024 else {
            state.storageError = "The draft exceeds local storage limits."
            return reject(.mutationsDisabled)
        }
        if state.composer.send.isInFlight { return reject(.operationInFlight) }
        state.composer.draft.text = text
        noteDraftEdited()
        rememberDraft()
        // Keystrokes coalesce like streaming writes instead of a synchronous
        // commit each; send, navigation and backgrounding still commit at once.
        guard !storageWritesBlocked, !storageLoadFailed else { return persistenceResult() }
        schedulePersistence()
        return .applied
    }

    private func clearCache() -> GianDispatchResult {
        guard let scope = readyScope() else { return reject(.notAuthorized) }
        clearTranscriptFileCache()
        do { try memory.clearDownloads(scope) }
        catch {
            storageWritesBlocked = true
            requiresFreshSnapshot = true
            state.sync.needsSnapshot = true
            state.connection = .offline
            state.storageError = "Local storage is unavailable. Changes have not been saved."
            eventCoordinator?.storageBecameUnavailable()
            return reject(.mutationsDisabled)
        }
        for index in state.composer.draft.attachments.indices where state.composer.draft.attachments[index].state == .cached {
            state.composer.draft.attachments[index].state = state.composer.draft.attachments[index].remoteID == nil ? .localOnly : .uploaded
        }
        rememberDraft()
        return persistenceResult()
    }
}
