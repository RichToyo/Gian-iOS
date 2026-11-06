import Foundation

extension GianClientStore {
    func cancelRetentionExpiry() {
        retentionExpiryGeneration &+= 1
        retentionExpiryTask?.cancel()
        retentionExpiryTask = nil
        retentionExpiryDeadline = nil
        retentionExpiryScope = nil
        retentionExpiryEpoch = nil
    }

    func scheduleRetentionExpiry(_ scope: ClientScope) {
        guard readyScope() == scope, state.foreground == .foreground,
              let deadline = memory.retentionNextExpiry(scope), deadline.timeIntervalSince1970.isFinite else {
            cancelRetentionExpiry()
            return
        }
        if retentionExpiryTask != nil, retentionExpiryDeadline == deadline,
           retentionExpiryScope == scope, retentionExpiryEpoch == epoch { return }
        cancelRetentionExpiry()
        retentionExpiryDeadline = deadline
        let ownerEpoch = epoch
        retentionExpiryScope = scope
        retentionExpiryEpoch = ownerEpoch
        let generation = retentionExpiryGeneration
        retentionExpiryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.retentionExpiryGeneration == generation {
                    self.retentionExpiryTask = nil
                    self.retentionExpiryDeadline = nil
                    self.retentionExpiryScope = nil
                    self.retentionExpiryEpoch = nil
                    if !Task.isCancelled, self.readyScope() == scope, self.state.foreground == .foreground {
                        self.scheduleRetentionExpiry(scope)
                    }
                }
            }
            var retry = false
            while !Task.isCancelled {
                let seconds = retry ? 30 : UInt64(min(max(ceil(deadline.timeIntervalSince(self.clock.now())) + 1, 1), 7 * 24 * 60 * 60))
                do { try await self.retentionExpirySleep(seconds) }
                catch {
                    guard !Task.isCancelled else { return }
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                    retry = true
                    continue
                }
                guard !Task.isCancelled, self.retentionExpiryGeneration == generation,
                      self.readyScope() == scope, self.epoch == ownerEpoch,
                      self.state.foreground == .foreground else { return }
                if self.clock.now() <= deadline { retry = false; continue }
                if self.persist() { return }
                retry = true
            }
        }
    }

    func scheduleRetentionRecovery(_ scope: ClientScope) {
        guard retentionRecoveryTasks[scope] == nil else { return }
        let ownerEpoch = epoch
        retentionRecoveryTasks[scope] = Task { @MainActor [weak self] in
            var delay: UInt64 = 1
            var staleSteps = 0
            var cachedGeneration: Int?
            var cachedMemoryGeneration: Int?
            var cachedReferences: Set<AttachmentID> = []
            var cachedProtectedSessions: Set<SessionID> = []
            var cachedHoldDownloads = false
            while !Task.isCancelled {
                guard let self else { return }
                guard self.readyScope() == scope, self.epoch == ownerEpoch, self.state.foreground == .foreground else {
                    self.retentionRecoveryTasks[scope] = nil
                    if self.readyScope() == scope, self.state.foreground == .foreground,
                       self.memory.needsRetentionRecovery(scope) { self.scheduleRetentionRecovery(scope) }
                    return
                }
                do {
                    guard let (snapshot, stored, generation, memoryGeneration, evicted, now) = try self.memory.retentionWorkSnapshot(scope) else {
                        self.retentionRecoveryTasks[scope] = nil
                        return
                    }
                    if cachedGeneration != generation || cachedMemoryGeneration != memoryGeneration {
                        let result = await Task.detached(priority: .utility) { snapshot.retentionWorkReferences(stored: stored, evicted: evicted, now: now) }.value
                        cachedReferences = result.0
                        cachedProtectedSessions = result.1
                        cachedHoldDownloads = result.2
                        cachedGeneration = generation
                        cachedMemoryGeneration = memoryGeneration
                    }
                    guard !Task.isCancelled, self.readyScope() == scope, self.epoch == ownerEpoch,
                          self.state.foreground == .foreground else {
                        self.retentionRecoveryTasks[scope] = nil
                        if !Task.isCancelled, self.readyScope() == scope, self.state.foreground == .foreground,
                           self.memory.needsRetentionRecovery(scope) { self.scheduleRetentionRecovery(scope) }
                        return
                    }
                    switch try self.memory.retentionStep(scope, generation: generation, memoryGeneration: memoryGeneration,
                                                         protected: cachedReferences, protectedSessions: cachedProtectedSessions,
                                                         holdDownloads: cachedHoldDownloads) {
                    case .complete:
                        self.retentionRecoveryTasks[scope] = nil
                        if self.storageLoadFailed { _ = self.restore(host: scope.host) }
                        else if self.storageWritesBlocked { _ = self.recoverLocalStorage() }
                        else { _ = self.persist() }
                        return
                    case .paused:
                        self.retentionRecoveryTasks[scope] = nil; return
                    case .more:
                        delay = 1; staleSteps = 0
                        await self.retentionRecoveryYield()
                    case .stale:
                        cachedGeneration = nil; cachedMemoryGeneration = nil
                        staleSteps += 1
                        // Each streamed chunk moves the bundle generation. Back off
                        // rather than recompute references back to back meanwhile.
                        if staleSteps < 3 {
                            delay = 1
                            await self.retentionRecoveryYield()
                        } else {
                            do { try await self.retentionRecoverySleep(delay) }
                            catch { self.retentionRecoveryTasks[scope] = nil; return }
                            delay = min(delay * 2, 30)
                        }
                    }
                } catch {
                    if (error as? GianStorageError) != .unavailable {
                        if self.readyScope() == scope {
                            self.state.storageError = "Local history cleanup could not continue."
                        }
                        self.retentionRecoveryTasks[scope] = nil; return
                    }
                    do { try await self.retentionRecoverySleep(delay) }
                    catch { self.retentionRecoveryTasks[scope] = nil; return }
                    delay = min(delay * 2, 30)
                }
            }
        }
    }

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
        if let scope = readyScope() { scheduleRetentionExpiry(scope) }
        locallyCreatedSessions = []; locallyCreatedWithActivity = []
        if state.composer.send.isInFlight, let intent = state.composer.send.intent {
            state.composer.send = .uncertain(intent)
            state.composer.notice = .keptAfterUncertainOutcome
        }
        if state.pendingStop.isInFlight, let intent = state.pendingStop.intent { state.pendingStop = .uncertain(intent) }
        // The pending reply is dropped as stale; recovery queries the command.
        for (session, command) in state.queueCommands {
            if case .pending(let id) = command { state.queueCommands[session] = .uncertain(id) }
        }
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
        manualDirectoryRecoveries = [:]
        temporarySearchResultID = nil
        locallyCreatedSessions = []; locallyCreatedWithActivity = []
        pendingSessionAccess = [:]; deniedSessionAccess = []; sessionAccessOverflow = false
        directoryExpiryTask?.cancel(); directoryExpiryTask = nil
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
