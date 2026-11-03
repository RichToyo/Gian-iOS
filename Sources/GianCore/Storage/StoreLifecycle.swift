import Foundation

extension GianClientStore {
    // Stream delivery can lag behind an awaited service result. Fence against
    // the producer's actual generation before applying that result as well.
    func responseIsCurrent(_ storeEpoch: Int) -> Bool {
        synchronizeServiceEpoch()
        return storeEpoch == epoch
    }

    func recoverLocalStorage() -> GianDispatchResult {
        do {
            try memory.flushDirty()
            storageWritesBlocked = false
            if readyScope() != nil { return persistenceResult() }
            if !storageLoadFailed { state.storageError = nil }
            return .applied
        } catch {
            storageWritesBlocked = true
            state.storageError = "Local storage is unavailable. Changes have not been saved."
            return reject(.mutationsDisabled)
        }
    }

    /// Service generations are independent from the store's scope epoch.
    /// Register the current service value, never a value supplied by a packet.
    func synchronizeServiceEpoch() {
        guard let source = service as? any GianClientEventSource else { return }
        let current = source.eventEpoch
        guard expectedServiceEpoch != current else { return }
        let previous = expectedServiceEpoch
        expectedServiceEpoch = current
        if readyServiceEpoch != current { readyServiceEpoch = nil }
        eventCoordinator?.didChangeServiceEpoch()
        guard previous != nil else { return }
        if state.phase == .serverEntered && state.account.status == .pending {
            epoch += 1
            serviceDiagnostic = nil
            return
        }
        guard readyScope() != nil else { return }
        epoch += 1
        if state.composer.send.isInFlight, let intent = state.composer.send.intent {
            state.composer.send = .uncertain(intent)
            state.composer.notice = .keptAfterUncertainOutcome
        }
        if state.pendingStop.isInFlight, let intent = state.pendingStop.intent { state.pendingStop = .uncertain(intent) }
        for index in state.interactions.indices where state.interactions[index].phase == .responding {
            state.interactions[index].phase = .uncertain
        }
        for session in state.translations.keys {
            guard var translation = state.translations[session] else { continue }
            for source in translation.reading.keys where translation.reading[source]?.pending == true {
                translation.reading[source]?.uncertain = true
            }
            state.translations[session] = translation
        }
        markConnectionNotReady(state.localConnectivity == .available && state.foreground == .foreground ? .resyncing : .offline,
                               reason: .cryptoResumed)
    }

    func markConnectionNotReady(_ projection: ConnectionProjection, reason: SnapshotRequiredReason?) {
        invalidateDirectoryViews()
        directoryRefreshPending = negotiatedDirectory
        markTranscriptCatchUp()
        readyServiceEpoch = nil
        requiresFreshSnapshot = true
        state.sync.needsSnapshot = true
        state.sync.reason = reason
        state.connection = projection
        if readyScope() != nil { persist() }
    }

    func markTranscriptCatchUp() {
        guard let scope = readyScope() else { return }
        memory.update(scope) { bundle in
            for (session, items) in bundle.transcripts where !items.isEmpty {
                if bundle.transcriptCursors[session]?.catchUp != nil { continue }
                let anchors = items.suffix(256).map(\.id)
                var cursor = bundle.transcriptCursors[session] ?? StoredTranscriptCursor(cursor: nil, hasOlder: true)
                cursor.hostGeneration = state.sync.cursor?.hostGeneration
                cursor.catchUp = StoredTranscriptCatchUp(anchorIDs: anchors)
                bundle.transcriptCursors[session] = cursor
            }
        }
        state.conversation?.hydratedFromCache = true
    }

    func finishPendingRemoteLogout() async {
        if let task = remoteLogoutTask {
            let request = remoteLogoutID
            await task.value
            if request == remoteLogoutID { remoteLogoutTask = nil }
            return
        }
        guard let scope = pendingRemoteLogout, let lifecycle = service as? any GianClientLifecycle else { return }
        pendingRemoteLogout = nil
        let sequence = beginLifecycleOutcome()
        remoteLogoutID += 1
        let request = remoteLogoutID
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            do {
                try await lifecycle.logout(server: scope.server, account: scope.account)
                self?.finishLifecycleOutcome(sequence, confirmed: true)
            } catch {
                // Local hiding is final, regardless of server confirmation.
                self?.finishLifecycleOutcome(sequence, confirmed: false)
            }
        }
        remoteLogoutTask = task
        await task.value
        if request == remoteLogoutID { remoteLogoutTask = nil }
    }

    func beginLifecycleOutcome() -> Int {
        lifecycleOutcomeSequence += 1
        serverOutcomeUnconfirmed = true
        return lifecycleOutcomeSequence
    }

    func finishLifecycleOutcome(_ sequence: Int, confirmed: Bool) {
        if sequence == lifecycleOutcomeSequence { serverOutcomeUnconfirmed = !confirmed }
    }

    func hideAuthorizationFromService() {
        _ = logout(invalidateRemote: false)
    }

    func hideHost(_ scope: ClientScope, confirmed: Bool = true) {
        guard readyScope() == scope else { return }
        clearTranscriptFileCache()
        persist()
        epoch += 1
        navigationEpoch += 1
        expectedServiceEpoch = nil
        requiresFreshSnapshot = true
        invalidatedHosts[scope] = clock.now()
        state.hosts.removeAll { $0.id == scope.host }
        state.currentHostID = nil
        state.pendingPairing = nil
        state.phase = state.hosts.isEmpty ? .awaitingHostPairing : .ready
        state.connection = confirmed ? .deviceRevoked : .offline
        state.navigation = .home
        state.directory = .empty
        state.conversation = nil
        state.drafts = []
        state.composer = ComposerProjection(selection: ComposerSelection(), draft: .placeholder(now: clock.now()), send: .idle, notice: .none)
        state.interactions = []
        state.translations = [:]
        state.banners = []
        state.workspaces = []
        state.agents = []
        state.catalogRevision = ""
        state.capabilities = .empty
        state.sync = SyncProjection()
        state.pendingStop = .idle
        sessions = []
        taskRecords = []
        searchHits = []
        directoryViews = [:]
        directoryRefreshPending = false
    }

    /// Revalidation evidence must match the current Server pin, controller
    /// and Host; there is no account deadline to extend.
    func acceptsRevalidation(_ authorization: AuthorizedSessionRestoration) -> Bool {
        guard let scope = readyScope(), authorization.server == scope.server,
              authorization.identity.account == scope.account,
              authorization.identity.installationID == state.account.installationID,
              authorization.hosts.contains(where: { $0.host.id == scope.host }),
              serverPins[scope.server].map({ $0 == authorization.serverIdentityFingerprint }) ?? true else { return false }
        return true
    }
}
