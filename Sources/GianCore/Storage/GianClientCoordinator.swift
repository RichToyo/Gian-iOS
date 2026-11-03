import Foundation

public enum GianCoordinatorError: Error, Sendable, Equatable {
    case serviceMismatch
    case alreadyBound
    case sqliteRequired
}

/// One application-owned coordinator per store/service lifetime. Construction
/// performs no I/O; start the consumers once, never from an individual View.
@MainActor
public final class GianClientCoordinator {
    public let store: GianClientStore
    public private(set) var isRunning = false

    private let runtime: any GianClientLifecycle & GianClientEventSource
    private let events: AsyncStream<InboundEnvelope>
    private let diagnostics: AsyncStream<RemoteServiceDiagnostic>
    private let loadAuthorization: @MainActor (ServerAddress, AccountID) throws -> AuthorizedSessionRestoration?
    private var eventTask: Task<Void, Never>?
    private var diagnosticTask: Task<Void, Never>?
    private var refreshTask: Task<GianDispatchResult, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var directoryTask: Task<Void, Never>?
    private var invalidationTask: Task<Void, Never>?
    private var refreshID = 0
    private var reconciliationID = 0
    private var directoryID = 0
    private var stopped = false

    public convenience init(store: GianClientStore, service: LiveGianClientService) throws {
        guard store.memory.usesSQLite else { throw GianCoordinatorError.sqliteRequired }
        try self.init(store: store, runtime: service, events: service.events, diagnostics: service.diagnostics,
            loadAuthorization: { try service.loadCachedAuthorization(server: $0, account: $1) })
    }

    init(store: GianClientStore, runtime: any GianClientLifecycle & GianClientEventSource,
         events: AsyncStream<InboundEnvelope>, diagnostics: AsyncStream<RemoteServiceDiagnostic>,
         loadAuthorization: @escaping @MainActor (ServerAddress, AccountID) throws -> AuthorizedSessionRestoration?) throws {
        guard ObjectIdentifier(store.service) == ObjectIdentifier(runtime) else { throw GianCoordinatorError.serviceMismatch }
        guard store.eventCoordinator == nil else { throw GianCoordinatorError.alreadyBound }
        self.store = store
        self.runtime = runtime
        self.events = events
        self.diagnostics = diagnostics
        self.loadAuthorization = loadAuthorization
        store.eventCoordinator = self
    }

    deinit {
        eventTask?.cancel()
        diagnosticTask?.cancel()
        refreshTask?.cancel()
        reconciliationTask?.cancel()
        directoryTask?.cancel()
        invalidationTask?.cancel()
    }

    public func start() {
        guard !isRunning, !stopped else { return }
        isRunning = true
        store.synchronizeServiceEpoch()
        let events = events
        eventTask = Task { @MainActor [weak self] in
            for await envelope in events {
                guard let self, !Task.isCancelled else { break }
                self.store.synchronizeServiceEpoch()
                let result = self.store.ingest(envelope)
                if result.isApplied {
                    if case .directory = envelope.event { self.queueReconciliation() }
                    if case .directoryChanged = envelope.event { self.queueDirectoryRefresh() }
                }
                self.queueRefreshIfNeeded()
                self.queuePendingInvalidation()
            }
            if let self, self.isRunning {
                await self.streamEnded()
            }
        }
        let diagnostics = diagnostics
        diagnosticTask = Task { @MainActor [weak self] in
            for await diagnostic in diagnostics {
                guard let self, !Task.isCancelled else { break }
                self.apply(diagnostic)
                self.queuePendingInvalidation()
            }
            if let self, self.isRunning { await self.streamEnded() }
        }
        if store.readyScope() != nil, store.state.localConnectivity == .available, store.state.foreground == .foreground {
            store.markConnectionNotReady(.resyncing, reason: .cryptoResumed)
            queueRefreshIfNeeded()
        }
    }

    /// Final disposal, not a background/foreground toggle. A stopped service's
    /// AsyncStream consumer is not silently replaced by another subscription.
    public func stop() async {
        guard !stopped else { return }
        stopped = true
        isRunning = false
        cancelNetworkEffects()
        eventTask?.cancel(); eventTask = nil
        diagnosticTask?.cancel(); diagnosticTask = nil
        _ = store.flushStorage()
        store.markConnectionNotReady(.offline, reason: .cryptoResumed)
        await runtime.disconnect()
        store.synchronizeServiceEpoch()
    }

    private func streamEnded() async {
        let scope = store.readyScope()
        await stop()
        store.serviceDiagnostic = RemoteServiceDiagnostic(server: scope?.server, account: scope?.account,
            host: scope?.host, epoch: runtime.eventEpoch, status: .connectionClosed(.disconnected))
    }

    @discardableResult
    public func restoreCachedAuthorization(
        server: ServerAddress, account: AccountID, selectedHost: HostID? = nil
    ) async -> GianDispatchResult {
        guard !stopped else { return .rejected(.mutationsDisabled) }
        start()
        cancelNetworkEffects()
        await store.finishPendingRemoteLogout()
        if let previous = store.accountScope(), previous != DataScope(server: server, account: account) {
            _ = await store.dispatch(.logout)
        }
        await runtime.disconnect()
        store.synchronizeServiceEpoch()
        do {
            guard let authorization = try loadAuthorization(server, account) else {
                store.hideAuthorizationFromService()
                _ = await store.dispatch(.setServerAddress(server.absoluteString))
                return .rejected(.notAuthorized)
            }
            let result = store.restoreAuthorizedSession(authorization: authorization, selectedHost: selectedHost)
            guard result.isApplied, store.readyScope() != nil else { return result }
            if store.state.localConnectivity == .available, store.state.foreground == .foreground {
                return await refreshConnection()
            }
            return result
        } catch {
            store.hideAuthorizationFromService()
            _ = await store.dispatch(.setServerAddress(server.absoluteString))
            store.serviceDiagnostic = RemoteServiceDiagnostic(server: server, account: account, host: selectedHost,
                epoch: runtime.eventEpoch, status: .connectionClosed(.integrity))
            return .rejected(.notAuthorized)
        }
    }

    @discardableResult
    public func refreshConnection() async -> GianDispatchResult {
        guard isRunning, !stopped, let scope = store.readyScope(),
              !store.storageLoadFailed, !store.storageWritesBlocked,
              store.state.localConnectivity == .available, store.state.foreground == .foreground else {
            return .rejected(.mutationsDisabled)
        }
        if let refreshTask { return await refreshTask.value }
        return await makeRefreshTask(scope: scope).value
    }

    private func makeRefreshTask(scope: ClientScope) -> Task<GianDispatchResult, Never> {
        refreshID += 1
        let request = refreshID
        let task = Task { @MainActor [weak self] () -> GianDispatchResult in
            guard let self else { return .rejected(.staleOperation) }
            defer { if request == self.refreshID { self.refreshTask = nil } }
            guard self.isRunning, !self.stopped, !Task.isCancelled, self.store.readyScope() == scope else {
                return .rejected(.staleOperation)
            }
            do {
                if self.store.state.sync.needsSnapshot { self.store.state.connection = .resyncing }
                else { self.store.markConnectionNotReady(.resyncing, reason: .cryptoResumed) }
                for _ in 0..<3 {
                    try await self.runtime.connect(scope: scope)
                    self.store.synchronizeServiceEpoch()
                    guard request == self.refreshID, self.store.readyScope() == scope, !Task.isCancelled else {
                        return .rejected(.staleOperation)
                    }
                    let result = await self.store.dispatch(.refreshDirectory)
                    guard request == self.refreshID, self.store.readyScope() == scope, !Task.isCancelled else {
                        return .rejected(.staleOperation)
                    }
                    if result.isApplied { self.queueReconciliation(); return result }
                    if result != .rejected(.staleOperation) { return result }
                }
                return .rejected(.mutationsDisabled)
            } catch {
                guard request == self.refreshID, !Task.isCancelled, self.store.readyScope() == scope else {
                    return .rejected(.staleOperation)
                }
                self.store.markConnectionNotReady(.offline, reason: .cryptoResumed)
                return .rejected(.mutationsDisabled)
            }
        }
        refreshTask = task
        return task
    }

    @discardableResult
    public func revokeCurrentHost() async -> GianDispatchResult {
        guard let scope = store.readyScope() else { return .rejected(.notAuthorized) }
        cancelNetworkEffects()
        store.hideHost(scope, confirmed: false)
        let sequence = store.beginLifecycleOutcome()
        do {
            try await runtime.revoke(scope: scope)
            store.finishLifecycleOutcome(sequence, confirmed: true)
            if store.state.currentHostID == nil, store.accountScope() == scope.data { store.state.connection = .deviceRevoked }
        } catch { store.finishLifecycleOutcome(sequence, confirmed: false) }
        store.synchronizeServiceEpoch()
        return .applied
    }

    func didDispatch(_ action: GianClientAction, result: GianDispatchResult) {
        guard isRunning else { return }
        switch action {
        case .logout:
            cancelNetworkEffects()
        case .setServerAddress:
            // Reconnecting to a Server already used here restores its Hosts.
            if result.isApplied, store.readyScope() != nil { queueReconciliation() } else { cancelNetworkEffects() }
        case .setForeground(.background), .noteLocalConnectivity(.unavailable):
            cancelNetworkEffects()
        case .setForeground(.foreground), .noteLocalConnectivity(.available):
            if result.isApplied { queueRefreshIfNeeded() }
        case .refreshDirectory:
            if result.isApplied { queueReconciliation(); queueDirectoryRefresh() }
            else if result == .rejected(.staleOperation) { queueRefreshIfNeeded() }
        case .selectConversation, .openBanner, .selectHost, .refreshHostPairing, .beginHostPairingFromQR:
            if result.isApplied { queueReconciliation() }
        default: break
        }
    }

    func willDispatch(_ action: GianClientAction) {
        guard isRunning else { return }
        switch action {
        case .logout, .setForeground(.background), .noteLocalConnectivity(.unavailable):
            cancelNetworkEffects()
        case .setServerAddress(let raw):
            if (store.state.phase == .signedOut || store.state.phase == .serverEntered), ServerAddress(parsing: raw) != nil {
                cancelNetworkEffects()
            }
        case .selectHost(let host):
            if store.state.phase == .ready, store.state.hosts.contains(where: { $0.id == host }) { cancelNetworkEffects() }
        case .selectConversation, .openBanner, .openNewChat, .returnHome:
            reconciliationID += 1
            reconciliationTask?.cancel()
            reconciliationTask = nil
        default: break
        }
    }

    func didChangeServiceEpoch() {
        directoryID += 1
        directoryTask?.cancel(); directoryTask = nil
        reconciliationID += 1
        reconciliationTask?.cancel()
        reconciliationTask = nil
    }

    func storageBecameUnavailable() {
        cancelNetworkEffects()
        let epoch = store.epoch
        Task { @MainActor [weak self] in
            guard let self, self.store.epoch == epoch, self.store.storageWritesBlocked else { return }
            await self.runtime.disconnect()
            self.store.synchronizeServiceEpoch()
        }
    }

    private func cancelNetworkEffects() {
        directoryID += 1
        directoryTask?.cancel(); directoryTask = nil
        refreshID += 1
        reconciliationID += 1
        refreshTask?.cancel(); refreshTask = nil
        reconciliationTask?.cancel(); reconciliationTask = nil
    }

    private func queuePendingInvalidation() {
        guard invalidationTask == nil, store.pendingRemoteLogout != nil else { return }
        invalidationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.invalidationTask = nil }
            await self.store.finishPendingRemoteLogout()
        }
    }

    private func queueRefreshIfNeeded() {
        guard isRunning, !stopped, refreshTask == nil, store.activeDirectoryReads == 0,
              !store.storageLoadFailed, !store.storageWritesBlocked,
              store.state.sync.needsSnapshot, store.state.connection == .resyncing,
              store.readyScope() != nil, store.state.localConnectivity == .available,
              store.state.foreground == .foreground else { return }
        guard let scope = store.readyScope() else { return }
        _ = makeRefreshTask(scope: scope)
    }

    private func queueDirectoryRefresh() {
        guard isRunning, !stopped, directoryTask == nil, store.directoryRefreshPending,
              store.directoryReadyForRecovery() else { return }
        let scope = store.readyScope()
        let serviceEpoch = runtime.eventEpoch
        directoryID += 1
        let request = directoryID
        directoryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.directoryID == request { self.directoryTask = nil } }
            for _ in 0..<3 {
                guard !Task.isCancelled, self.directoryID == request, self.store.readyScope() == scope, self.runtime.eventEpoch == serviceEpoch else { return }
                let result = await self.store.refreshLoadedDirectoryViews()
                if result.isApplied { self.queueReconciliation(); return }
                if result != .rejected(.staleOperation) { return }
            }
        }
    }

    private func queueReconciliation() {
        guard isRunning, !stopped, reconciliationTask == nil, store.directoryReadyForRecovery(),
              let scope = store.readyScope() else { return }
        reconciliationID += 1
        let request = reconciliationID
        let epoch = store.epoch
        let session = store.currentSessionID
        reconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if request == self.reconciliationID { self.reconciliationTask = nil } }
            guard !Task.isCancelled, self.store.epoch == epoch, self.store.readyScope() == scope else { return }
            if let session, self.store.state.conversation?.hydratedFromCache == true
                || self.store.memory.bundle(for: scope).transcriptCursors[session]?.catchUp != nil {
                var reconciled = false
                for _ in 0..<3 {
                    let result = await self.store.reconcileActiveTranscript()
                    if result.isApplied { reconciled = true; break }
                    guard result == .rejected(.staleOperation), !Task.isCancelled,
                          self.store.epoch == epoch, self.store.readyScope() == scope,
                          self.store.currentSessionID == session else { return }
                }
                guard reconciled else { return }
            }
            guard !Task.isCancelled, self.store.epoch == epoch, self.store.readyScope() == scope else { return }
            // Status reads and full-text reads are safe recovery operations;
            // this path never invokes send or a paid translation request.
            _ = await self.store.dispatch(.recoverUncertainOperation)
            if let session, self.store.currentSessionID == session,
               let translations = self.store.state.translations[session] {
                for record in translations.records.prefix(32) where record.presentableText == nil {
                    guard !Task.isCancelled, self.store.epoch == epoch, self.store.readyScope() == scope else { break }
                    _ = await self.store.dispatch(.retryTranslationText(record.id))
                }
            }
        }
    }

    private func apply(_ diagnostic: RemoteServiceDiagnostic) {
        store.synchronizeServiceEpoch()
        guard diagnostic.epoch == runtime.eventEpoch,
              diagnostic.server.map({ $0 == store.state.server }) ?? true,
              diagnostic.account.map({ $0 == store.state.account.accountID }) ?? true,
              diagnostic.host.map({ $0 == store.state.currentHostID }) ?? true else { return }
        switch diagnostic.status {
        case .connectionClosed(let error):
            store.serviceDiagnostic = diagnostic
            cancelNetworkEffects()
            if store.readyScope() == nil, error == .unsupported, store.serverOutcomeUnconfirmed {
                store.serviceDiagnostic = nil
                return
            }
            if error == .notAuthorized {
                store.hideAuthorizationFromService()
                store.serviceDiagnostic = RemoteServiceDiagnostic(server: nil, account: nil, host: nil,
                    epoch: diagnostic.epoch, status: .connectionClosed(.notAuthorized))
            }
            else if error == .deviceRevoked, let scope = store.readyScope() { store.hideHost(scope) }
            else if error == .versionMismatch { store.markConnectionNotReady(.versionMismatch(hostVersion: "unknown"), reason: nil) }
            else if store.readyScope() != nil { store.markConnectionNotReady(.offline, reason: .cryptoResumed) }
        case .resyncRequired(let reason):
            if let producer = runtime as? any DirectoryReadinessReporting, producer.acceptedDirectory != nil {
                // Proven stale at the producer. Preserve any newer local need.
                queueRefreshIfNeeded()
                return
            }
            store.serviceDiagnostic = diagnostic
            if !store.state.sync.needsSnapshot || store.readyServiceEpoch != runtime.eventEpoch {
                store.markConnectionNotReady(.resyncing, reason: reason)
            }
            queueRefreshIfNeeded()
        case .cleared:
            if let previous = store.serviceDiagnostic, case .resyncRequired = previous.status, store.state.sync.needsSnapshot {
                // Socket success is not directory freshness evidence.
            } else { store.serviceDiagnostic = nil }
            guard diagnostic.host != nil, let scope = store.readyScope() else { return }
            do {
                guard let evidence = try loadAuthorization(scope.server, scope.account), store.acceptsRevalidation(evidence) else {
                    store.hideAuthorizationFromService()
                    return
                }
            } catch { store.hideAuthorizationFromService(); return }
            if store.readyServiceEpoch == runtime.eventEpoch, !store.state.sync.needsSnapshot { return }
            if store.state.sync.needsSnapshot { store.state.connection = .resyncing }
            else { store.markConnectionNotReady(.resyncing, reason: .cryptoResumed) }
            queueRefreshIfNeeded()
        }
    }
}
