import Foundation

extension GianClientStore {
    var negotiatedDirectory: Bool { state.capabilities.negotiatedFeatures.contains(.sessionDirectoryV1) }

    func invalidateDirectoryViews() {
        directorySequence += 1
        for view in directoryViews.keys { directoryViews[view]?.invalidate() }
        reproject()
    }

    func refreshLoadedDirectoryViews() async -> GianDispatchResult {
        guard negotiatedDirectory else { return .applied }
        let active: DirectoryCollection = state.navigation.directoryView == .tasks ? .tasks : .repos
        let views = [active] + DirectoryCollection.allCases.filter { $0 != active && directoryViews[$0] != nil }
        let sequence = directorySequence
        for view in views {
            if view == .search && state.directory.searchQuery.isEmpty { continue }
            let result = await loadDirectory(view, reset: true)
            if !result.isApplied { return result }
        }
        if sequence == directorySequence { directoryRefreshPending = false }
        return .applied
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
                // This directory requires session.read. An authority denial is
                // not a transient read failure that may keep displaying rows.
                directorySequence += 1
                directoryRefreshPending = false
                for collection in DirectoryCollection.allCases {
                    var denied = StoredDirectoryView()
                    denied.status = DirectoryPageStatus(phase: .denied, error: "The Host has not granted conversation access.")
                    directoryViews[collection] = denied
                }
                for index in sessions.indices { sessions[index].authorized = false }
                state.interactions = []
                state.banners = []
                if state.conversation != nil {
                    navigationEpoch += 1; state.conversation = nil; state.navigation.destination = .home
                }
                reproject()
                return persistenceResult()
            case .unsupported:
                saved.invalidate(); saved.entries = []
                saved.status = DirectoryPageStatus(phase: .unsupported)
            case .failed(let message):
                saved.status = DirectoryPageStatus(phase: .failed, hasMore: saved.cursor != nil,
                    isStale: saved.status.isStale, error: message)
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
            return persistenceResult()
        }
        directoryViews[view] = saved; reproject()
        return persistenceResult()
    }

    func mergeDirectoryMetadata(_ entries: [DirectoryEntry]) {
        for entry in entries {
            if let index = sessions.firstIndex(where: { $0.id == entry.session.id }) { sessions[index] = entry.session }
            else { sessions.append(entry.session) }
            if let index = state.workspaces.firstIndex(where: { $0.id == entry.workspace.id }) { state.workspaces[index] = entry.workspace }
            else { state.workspaces.append(entry.workspace) }
            if let task = entry.task {
                if let index = taskRecords.firstIndex(where: { $0.id == task.id }) { taskRecords[index] = task }
                else { taskRecords.append(task) }
            }
        }
    }

    func projectDirectoryMembership() {
        func entries(_ view: DirectoryCollection) -> [DirectoryEntry] {
            (directoryViews[view]?.visibleEntries ?? []).compactMap { entry in
                guard let current = sessions.first(where: { $0.id == entry.session.id }), current.authorized, !current.archived else { return nil }
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
        state.directory.tasks = Dictionary(grouping: tasks.filter { entry in
            entry.task?.status == .open && entry.session.taskID == entry.task?.id
        }, by: { $0.task!.id })
            .map { id, rows in TaskSection(id: id, title: rows[0].task!.title,
                conversations: rows.map { DirectoryFilter.summary($0.session, names: names) }.sorted { $0.id.rawValue < $1.id.rawValue }) }
            .sorted { $0.id.rawValue < $1.id.rawValue }
        state.directory.repos = repos.map { DirectoryFilter.summary($0.session, names: names) }
        state.directory.repositories = Dictionary(grouping: repos, by: { $0.workspace.id }).map { id, rows in
            RepositorySection(id: id, title: rows[0].workspace.name,
                conversations: rows.map { DirectoryFilter.summary($0.session, names: names) })
        }.sorted { $0.id.rawValue < $1.id.rawValue }
        state.directory.searchResults = state.directory.searchQuery.isEmpty ? [] : search.map { DirectoryFilter.summary($0.session, names: names) }
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
        state.directory.tasksPage = directoryViews[.tasks]?.status ?? DirectoryPageStatus()
        state.directory.reposPage = directoryViews[.repos]?.status ?? DirectoryPageStatus()
        state.directory.searchPage = directoryViews[.search]?.status ?? DirectoryPageStatus()
        if state.directory.authority == .legacyOpenDoingTasksOnly {
            state.directory.reposPage = DirectoryPageStatus(phase: .unsupported)
            state.directory.searchPage = DirectoryPageStatus(phase: .unsupported)
        }
    }
}
