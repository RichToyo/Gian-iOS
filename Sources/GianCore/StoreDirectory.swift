import Foundation

extension GianClientStore {
    var negotiatedDirectory: Bool { state.capabilities.negotiatedFeatures.contains(.sessionDirectoryV1) }

    func resolveSessionAccess(_ result: SessionAccessResult, session: SessionID, version: Int, scope: ClientScope) {
        guard readyScope() == scope, pendingSessionAccess[session] == version else { return }
        switch result {
        case .authorized:
            pendingSessionAccess.removeValue(forKey: session)
            reproject()
            _ = persist()
        case .unavailable:
            // Like an authorization, an answered denial applies even before
            // the directory is negotiated again (e.g. restored from cache).
            _ = applySessionUnavailable(session)
        case .retry:
            break
        }
    }

    func applySessionUnavailable(_ session: SessionID) -> GianDispatchResult {
        recordSessionDenial(session)
        pendingSessionAccess.removeValue(forKey: session)
        invalidateDirectoryViews()
        directoryRefreshPending = true
        for collection in directoryViews.keys {
            directoryViews[collection]?.entries.removeAll { $0.session.id == session }
        }
        if let scope = readyScope() { memory.clearRetentionActivity(scope: scope, session: session) }
        if let index = sessions.firstIndex(where: { $0.id == session }) { sessions[index].authorized = false }
        if let index = searchHits.firstIndex(where: { $0.id == session }) { searchHits[index].authorized = false }
        if temporarySearchResultID == session { temporarySearchResultID = nil }
        locallyCreatedSessions.remove(session); locallyCreatedWithActivity.remove(session)
        state.interactions.removeAll { $0.sessionID == session }
        if currentSessionID == session {
            navigationEpoch += 1; state.conversation = nil; state.navigation.destination = .home
        }
        reproject()
        return persistenceResult()
    }

    func manualRefreshDirectory(_ view: DirectoryCollection) async -> GianDispatchResult {
        guard let scope = readyScope() else { return reject(.notAuthorized) }
        let selectedView = state.navigation.directoryView
        let expectedView: DirectoryCollection = selectedView == .tasks ? .tasks : .repos
        guard view == .search || view == expectedView else { return reject(.staleOperation) }
        let navigation = navigationEpoch
        let query = state.directory.searchQuery
        func stillCurrent() -> Bool {
            readyScope() == scope && navigationEpoch == navigation && state.navigation.directoryView == selectedView
                && (view != .search || state.directory.searchQuery == query)
        }
        func fail(_ message: String, code: RejectionCode = .mutationsDisabled) -> GianDispatchResult {
            guard stillCurrent() else { return reject(.staleOperation) }
            if state.capabilities.state(of: .sessionRead) == .denied { return denyDirectoryAccess() }
            var saved = directoryViews[view] ?? StoredDirectoryView()
            saved.status = DirectoryPageStatus(phase: .failed, hasMore: saved.cursor != nil, isStale: true, error: message)
            directoryViews[view] = saved
            reproject()
            return reject(code)
        }

        guard !storageLoadFailed, !storageWritesBlocked else {
            return fail("Local storage is unavailable. Resolve the storage error and try again.")
        }
        guard state.localConnectivity == .available else {
            return fail("Network unavailable. Check your connection and try again.")
        }
        guard state.foreground == .foreground else {
            return fail("Return to the app and try again.")
        }
        if manualDirectoryRecoveries[view]?.isEmpty == false { return reject(.operationInFlight) }
        if !directoryReadyForRecovery() {
            guard let coordinator = eventCoordinator else {
                return fail("The connection is not ready. Reconnect and try again.")
            }
            manualDirectoryRecoverySequence += 1
            let recoveryID = manualDirectoryRecoverySequence
            manualDirectoryRecoveries[view, default: []].insert(recoveryID)
            reproject()
            let recovery = await coordinator.refreshConnection()
            if readyScope() == scope {
                manualDirectoryRecoveries[view]?.remove(recoveryID)
                if manualDirectoryRecoveries[view]?.isEmpty == true { manualDirectoryRecoveries[view] = nil }
                reproject()
            }
            guard stillCurrent() else { return reject(.staleOperation) }
            if !recovery.isApplied, directoryReadyForRecovery() {
                let status = directoryViews[view]?.status.phase
                if status == .complete { return .applied }
                if status == .loading { return reject(.operationInFlight) }
                if status == .failed || status == .cursorInvalid { return recovery }
            }
            guard recovery.isApplied, directoryReadyForRecovery() else {
                if directoryViews[view]?.status.phase == .denied { return reject(.capabilityDenied) }
                return fail("Could not reconnect to the Host. Check the connection and retry.")
            }
            if directoryViews[view]?.status.phase == .complete { return .applied }
        }
        guard stillCurrent() else { return reject(.staleOperation) }
        if view == .tasks, !negotiatedDirectory { return await refresh() }
        if directoryViews[view]?.status.isLoading == true { return reject(.operationInFlight) }
        let phase = directoryViews[view]?.status.phase
        return await loadDirectory(view, reset: phase == .complete || phase == .cursorInvalid || phase == .unsupported)
    }

    func noteCreatedActivity(_ id: SessionID) {
        guard locallyCreatedSessions.contains(id), locallyCreatedWithActivity.insert(id).inserted else { return }
        directoryRefreshPending = true
        invalidateDirectoryViews()
    }

    func scheduleDirectoryExpiry(now: Date) {
        directoryExpiryTask?.cancel()
        directoryExpiryTask = nil
        guard clock is SystemGianClock, let scope = readyScope() else { return }
        let durations = [tasksTimeFilter.duration, reposTimeFilter.duration, DirectoryTimeFilter.last7Days.duration]
        let deadlines = sessions.compactMap { session -> Date? in
            guard session.activityIsMessageOrExecution, let activity = session.lastActivityAt else { return nil }
            return durations.map { activity.addingTimeInterval($0) }.filter { $0 >= now }.min()
        }
        guard let deadline = deadlines.min() else { return }
        let delay = min(max(deadline.timeIntervalSince(now) + 0.01, 0.01), 24 * 60 * 60)
        guard delay.isFinite else { return }
        directoryExpiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard let self, self.readyScope() == scope else { return }
            self.reproject()
            _ = self.persist()
        }
    }

    func invalidateDirectoryViews() {
        directorySequence += 1
        for view in directoryViews.keys { directoryViews[view]?.invalidate() }
        reproject()
    }

    func refreshLoadedDirectoryViews() async -> DirectoryRefreshOutcome {
        guard negotiatedDirectory else { return .blocked }
        let active: DirectoryCollection = state.navigation.directoryView == .tasks ? .tasks : .repos
        let views = [active] + DirectoryCollection.allCases.filter { $0 != active && directoryViews[$0] != nil }
        let sequence = directorySequence
        for view in views {
            if view == .search && state.directory.searchQuery.isEmpty { continue }
            if directoryViews[view]?.status.phase == .unsupported { continue }
            let result = await loadDirectory(view, reset: false)
            if result == .rejected(.staleOperation) { return .stale }
            if result == .rejected(.mutationsDisabled) || result == .rejected(.notAuthorized) { return .blocked }
            let status = directoryViews[view]?.status.phase
            if status == .denied { return .blocked }
            if status == .failed || status == .cursorInvalid { return .failed }
            if status == .incomplete || status == .loading || status == .idle { return .incomplete }
            if !result.isApplied && status != .unsupported { return .failed }
        }
        guard sequence == directorySequence else { return .stale }
        directoryRefreshPending = false
        return .complete
    }

    func loadDirectory(_ view: DirectoryCollection, reset: Bool) async -> GianDispatchResult {
        guard let scope = readyScope() else { return reject(.notAuthorized) }
        guard negotiatedDirectory else {
            var saved = directoryViews[view] ?? StoredDirectoryView()
            saved.status = DirectoryPageStatus(phase: .unsupported)
            directoryViews[view] = saved; reproject()
            return reject(view == .search ? .legacySearchUnsupported : .capabilityUnsupported)
        }
        guard directoryReadyForRecovery() else { return reject(.mutationsDisabled) }
        if state.capabilities.state(of: .sessionRead) == .denied { return denyDirectoryAccess() }
        guard state.capabilities.state(of: .sessionRead) == .supported else {
            var saved = directoryViews[view] ?? StoredDirectoryView()
            saved.invalidate(); saved.entries = []; saved.status = DirectoryPageStatus(phase: .unsupported)
            directoryViews[view] = saved; reproject()
            return reject(.capabilityUnsupported)
        }
        let query = view == .search ? state.directory.searchQuery : nil
        guard view != .search || query.map({ !$0.isEmpty && $0.utf16.count <= 256 }) == true else { return reject(.notFound) }
        var saved = directoryViews[view] ?? StoredDirectoryView()
        if !reset, saved.status.isLoading { return reject(.operationInFlight) }
        if saved.query != query { saved = StoredDirectoryView(); saved.query = query }
        if reset { saved.invalidate(); saved.query = query }
        if !reset, saved.status.phase == .complete { return .applied }
        directoryRequestSequence += 1
        let requestID = directoryRequestSequence
        directoryRequests[view] = requestID
        let token = epoch
        let invalidation = directorySequence
        let serviceEpoch = (service as? any GianClientEventSource)?.eventEpoch
        let membershipEpoch = (service as? any DirectoryMembershipEpoch)?.directoryMembershipGeneration
        saved.status.phase = .loading; saved.status.error = nil
        directoryViews[view] = saved; reproject()
        var resets = 0
        // Reads are bounded per action. Even an empty incomplete page consumes
        // one budget slot and retains a real continuation for the next action.
        for _ in 0..<4 {
            saved.status.phase = .loading
            directoryViews[view] = saved; reproject()
            let response = await service.listDirectory(scope: scope,
                request: DirectoryPageRequest(view: view, query: query, cursor: saved.cursor))
            guard responseIsCurrent(token), readyScope() == scope, directorySequence == invalidation,
                  directoryRequests[view] == requestID,
                  view != .search || state.directory.searchQuery == query,
                  (service as? any GianClientEventSource)?.eventEpoch == serviceEpoch,
                  (service as? any DirectoryMembershipEpoch)?.directoryMembershipGeneration == membershipEpoch,
                  !Task.isCancelled else {
                if readyScope() == scope, directorySequence == invalidation, directoryRequests[view] == requestID {
                    saved.status.phase = saved.cursor == nil ? .idle : .incomplete
                    directoryViews[view] = saved; reproject()
                }
                return reject(.staleOperation)
            }
            switch response {
            case .denied:
                return denyDirectoryAccess()
            case .unsupported:
                saved.invalidate(); saved.entries = []
                saved.status = DirectoryPageStatus(phase: .unsupported)
            case .failed(let message):
                saved.status = DirectoryPageStatus(phase: .failed, hasMore: saved.cursor != nil,
                    isStale: saved.status.isStale, error: message)
                directoryRefreshPending = true
            case .page(let page):
                guard saved.apply(page, scope: scope, view: view) else {
                    saved.invalidate()
                    saved.status = DirectoryPageStatus(phase: .failed, error: "The Host returned an inconsistent directory page.")
                    directoryViews[view] = saved; reproject()
                    _ = persist()
                    return reject(.notFound)
                }
                directoryViews[view] = saved
                mergeDirectoryMetadata(page.entries)
                reproject()
                if page.state == .cursorInvalid {
                    resets += 1
                    if resets <= 2 { continue }
                    saved.status.error = "The directory changed repeatedly. Refresh to try again."
                } else if page.state == .incomplete { continue }
            }
            directoryViews[view] = saved; reproject()
            guard persist() else { return reject(.mutationsDisabled) }
            if saved.status.phase == .failed || saved.status.phase == .cursorInvalid { return reject(.notFound) }
            if saved.status.phase == .unsupported { return reject(.capabilityUnsupported) }
            return .applied
        }
        directoryRefreshPending = saved.status.phase == .incomplete || directoryRefreshPending
        directoryViews[view] = saved; reproject()
        return persistenceResult()
    }

    func mergeDirectoryMetadata(_ entries: [DirectoryEntry]) {
        for entry in entries {
            pendingSessionAccess.removeValue(forKey: entry.session.id)
            deniedSessionAccess.remove(entry.session.id)
            if let index = sessions.firstIndex(where: { $0.id == entry.session.id }) {
                // Directory rows carry no queue or conversation settings.
                var session = entry.session
                let previous = sessions[index]
                if session.queue == nil { session.queue = previous.queue }
                session.model = session.model ?? previous.model
                session.thinking = session.thinking ?? previous.thinking
                session.serviceTier = session.serviceTier ?? previous.serviceTier
                session.approvalMode = session.approvalMode ?? previous.approvalMode
                sessions[index] = session
            } else { sessions.append(entry.session) }
            noteRetentionActivity(entry.session)
            if let index = state.workspaces.firstIndex(where: { $0.id == entry.workspace.id }) { state.workspaces[index] = entry.workspace }
            else { state.workspaces.append(entry.workspace) }
            if let task = entry.task {
                if let index = taskRecords.firstIndex(where: { $0.id == task.id }) { taskRecords[index] = task }
                else { taskRecords.append(task) }
            }
        }
    }

    func projectDirectoryMembership(now: Date) {
        func entries(_ view: DirectoryCollection) -> [DirectoryEntry] {
            (directoryViews[view]?.visibleEntries ?? []).compactMap { entry in
                guard let current = sessions.first(where: { $0.id == entry.session.id }), current.authorized, !current.archived else { return nil }
                // The page's own task record decides, not one merged from another view.
                guard entry.task == nil || entry.task?.status == .open else { return nil }
                guard current.taskID == entry.task?.id, current.workspaceID == entry.workspace.id else { return nil }
                var next = entry; next.session = current
                return next
            }
        }
        let tasks = entries(.tasks)
        let repos = entries(.repos)
        let search = entries(.search)
        let names = state.workspaces.reduce(into: [WorkspaceID: String]()) { $0[$1.id] = $1.name }
        // Membership comes from this page. A task record merged from another view
        // must not hide an open Tasks row the page still contains.
        let eligibleTasks = Dictionary(grouping: tasks.filter { entry in
            entry.task?.status == .open && entry.session.taskID == entry.task?.id && entry.session.completedAt == nil
        }, by: { $0.task!.id })
        state.directory.tasks = eligibleTasks.filter { _, rows in
            rows.contains { tasksTimeFilter.includes($0.session, now: now) || $0.session.id == currentSessionID }
        }
            .map { id, rows in TaskSection(id: id, title: rows[0].task!.title,
                conversations: rows.map { DirectoryFilter.summary($0.session, names: names) }.sorted { $0.id.rawValue < $1.id.rawValue }) }
            .sorted { $0.id.rawValue < $1.id.rawValue }
        let recentRepos = repos.filter { reposTimeFilter.includes($0.session, now: now) || $0.session.id == currentSessionID }
        state.directory.repos = recentRepos.map { DirectoryFilter.summary($0.session, names: names) }
        state.directory.repositories = Dictionary(grouping: recentRepos, by: { $0.workspace.id }).map { id, rows in
            RepositorySection(id: id, title: rows[0].workspace.name,
                conversations: rows.map { DirectoryFilter.summary($0.session, names: names) })
        }.sorted { $0.id.rawValue < $1.id.rawValue }
        var matching: [SessionID: ConversationSummary] = [:]
        if !state.directory.searchQuery.isEmpty, !sessionAccessOverflow {
            for entry in search + tasks + repos {
                let id = entry.session.id
                guard matching[id] == nil, pendingSessionAccess[id] == nil, !deniedSessionAccess.contains(id),
                      let name = entry.searchName,
                      DirectoryFilter.titleMatches(name, query: state.directory.searchQuery),
                      DirectoryFilter.titleMatches(entry.session.title, query: state.directory.searchQuery) else { continue }
                matching[id] = DirectoryFilter.summary(entry.session, names: names)
            }
        }
        state.directory.searchResults = matching.values.sorted {
            let lhs = $0.lastActivityAt ?? .distantPast
            let rhs = $1.lastActivityAt ?? .distantPast
            return lhs == rhs ? $0.id.rawValue < $1.id.rawValue : lhs > rhs
        }
        let view: DirectoryCollection = state.navigation.directoryView == .tasks ? .tasks : .repos
        let status = directoryViews[view]?.status.phase
        let hostIncluded = Set((view == .tasks ? tasks : repos).map { $0.session.id })
        let published = Set(view == .tasks ? state.directory.tasks.flatMap(\.conversations).map(\.id) : state.directory.repos.map(\.id))
        if status != .denied && status != .unsupported {
            state.directory.temporaryCreatedResults = sessions.filter { session in
                guard locallyCreatedWithActivity.contains(session.id), !published.contains(session.id),
                      session.authorized, !session.archived else { return false }
                if status == .complete && (!hostIncluded.contains(session.id) || currentSessionID != session.id) { return false }
                if let taskID = session.taskID,
                   taskRecords.contains(where: { $0.id == taskID && $0.status != .open }) { return false }
                if view == .tasks {
                    guard session.completedAt == nil, let taskID = session.taskID else { return false }
                    return taskRecords.contains { $0.id == taskID && $0.status == .open }
                }
                return true
            }.map { DirectoryFilter.summary($0, names: names) }.sorted { $0.id.rawValue < $1.id.rawValue }
        }
        state.directory.reposSupport = directoryViews[.repos]?.status.phase == .unsupported ? .unsupported(.reposDirectory) : .supported
        state.directory.searchSupport = directoryViews[.search]?.status.phase == .unsupported ? .unsupported(.olderSearch) : .supported
        state.directory.legacyLimitations = []
    }

    var publishedDirectorySessionIDs: Set<SessionID> {
        var ids = Set<SessionID>()
        for view in directoryViews.values {
            for entry in view.entries { ids.insert(entry.session.id) }
            for entry in view.pendingEntries ?? [] { ids.insert(entry.session.id) }
        }
        return ids
    }

    func projectDirectoryStatus() {
        func status(_ view: DirectoryCollection) -> DirectoryPageStatus {
            var result = directoryViews[view]?.status ?? DirectoryPageStatus()
            if manualDirectoryRecoveries[view]?.isEmpty == false, result.phase != .denied, result.phase != .unsupported {
                result.phase = .loading; result.error = nil
            }
            return result
        }
        state.directory.tasksPage = status(.tasks)
        state.directory.reposPage = status(.repos)
        state.directory.searchPage = status(.search)
        if state.directory.authority == .legacyOpenDoingTasksOnly {
            state.directory.reposPage = DirectoryPageStatus(phase: .unsupported)
            state.directory.searchPage = DirectoryPageStatus(phase: .unsupported)
        }
    }

    func denyDirectoryAccess() -> GianDispatchResult {
        directorySequence += 1
        if let scope = readyScope() { memory.clearRetentionActivity(scope: scope) }
        for id in sessions.map(\.id) + searchHits.map(\.id) { recordSessionDenial(id) }
        pendingSessionAccess.removeAll()
        directoryRefreshPending = false
        for collection in DirectoryCollection.allCases {
            var denied = StoredDirectoryView()
            denied.status = DirectoryPageStatus(phase: .denied, error: "The Host has not granted conversation access.")
            directoryViews[collection] = denied
        }
        temporarySearchResultID = nil
        locallyCreatedSessions = []; locallyCreatedWithActivity = []
        for index in sessions.indices { sessions[index].authorized = false }
        state.interactions = []; state.banners = []
        if state.conversation != nil {
            navigationEpoch += 1; state.conversation = nil; state.navigation.destination = .home
        }
        reproject()
        return persist() ? reject(.capabilityDenied) : reject(.mutationsDisabled)
    }
}
