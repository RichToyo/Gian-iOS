import Foundation
@testable import GianCore

/// Fictional backend with explicit response gates. Tests advance it without
/// sleeps, real networking, credentials or a user's Application Support folder.
@MainActor
class ControlledService: GianClientServicing {
    let base = PreviewGianClientService(script: .legacyContract)
    var holdNextPage = false
    var holdNextSend = false
    var holdNextTranslation = false
    var page: CheckedContinuation<TranscriptPageResponse, Never>?
    var send: CheckedContinuation<CommandDispatchResponse, Never>?
    var translation: CheckedContinuation<TranslationCommandResponse, Never>?
    var sendRequest: SessionSendRequest?
    var queueRequests: [QueueMutationRequest] = []
    var queueReturnsUnknown = false
    var holdNextQueue = false
    var queueContinuation: CheckedContinuation<CommandDispatchResponse, Never>?
    var queueStatus: CommandStatusResponse?
    var translationRequest: TranslationRequest?
    var translationStatus: TranslationCommandResponse?
    var translationPages: [TranslationTextPageResponse] = []
    var transcriptPages: [TranscriptPageResponse] = []
    var transcriptRequestCursors: [String?] = []
    var sessionCreateRequests: [SessionCreateRequest] = []
    var updateRequests: [SessionUpdateRequest] = []
    /// Overrides the preview service's `session.update` result when set.
    var updateResponse: SessionUpdateResponse?
    var holdNextUpdate = false
    var update: CheckedContinuation<SessionUpdateResponse, Never>?
    /// Scripted pairing replies, consumed in order before the preview's.
    var claimResponses: [HostPairingResponse] = []
    var pairingRefreshResponses: [HostPairingResponse] = []
    var holdNextPairingRefresh = false
    var pairingRefresh: CheckedContinuation<HostPairingResponse, Never>?
    /// Further Hosts; each answers with an empty directory under its own summary.
    var extraHosts: [HostSummary] = []
    /// Tasks added to every snapshot (e.g. open tasks with no conversations).
    var extraTasks: [TaskRecord] = []
    /// `proxy.logo` replies by plugin ID (default: none); reads are recorded.
    var logos: [String: AgentLogoResponse] = [:]
    var logoRequests: [String] = []

    func connectServer(server: ServerAddress, enrollmentToken: String?) async -> ServerConnectResponse {
        await base.connectServer(server: server, enrollmentToken: enrollmentToken)
    }
    var claimInvitations: [HostPairingInvitation] = []
    func claimHost(server: ServerAddress, account: AccountID, invitation: HostPairingInvitation) async -> HostPairingResponse {
        claimInvitations.append(invitation)
        if !claimResponses.isEmpty { return claimResponses.removeFirst() }
        return await base.claimHost(server: server, account: account, invitation: invitation)
    }
    func refreshHostPairing(server: ServerAddress, account: AccountID, pairingID: PairingID) async -> HostPairingResponse {
        if holdNextPairingRefresh {
            holdNextPairingRefresh = false
            return await withCheckedContinuation { pairingRefresh = $0 }
        }
        if !pairingRefreshResponses.isEmpty { return pairingRefreshResponses.removeFirst() }
        return await base.refreshHostPairing(server: server, account: account, pairingID: pairingID)
    }
    func refreshDirectory(scope: ClientScope) async -> DirectoryRefreshResponse {
        if let host = extraHosts.first(where: { $0.id == scope.host }) {
            guard case .snapshot(var payload) = await base.refreshDirectory(scope: scope) else { return .failed("no snapshot") }
            payload.host = host
            payload.tasks = []; payload.sessions = []; payload.interactions = []; payload.workspaces = []; payload.agents = []
            return .snapshot(payload)
        }
        guard case .snapshot(var payload) = await base.refreshDirectory(scope: scope) else { return await base.refreshDirectory(scope: scope) }
        payload.tasks += extraTasks
        return .snapshot(payload)
    }
    func agentLogo(scope: ClientScope, pluginID: String, variant: AgentLogoVariant) async -> AgentLogoResponse {
        logoRequests.append("\(pluginID)/\(variant.rawValue)")
        return logos[pluginID] ?? .notFound
    }
    func listDirectory(scope: ClientScope, request: DirectoryPageRequest) async -> DirectoryPageResponse { .unsupported }
    func createSession(scope: ClientScope, request: SessionCreateRequest) async -> CommandDispatchResponse {
        sessionCreateRequests.append(request)
        return await base.createSession(scope: scope, request: request)
    }
    func updateSession(scope: ClientScope, request: SessionUpdateRequest) async -> SessionUpdateResponse {
        updateRequests.append(request)
        if holdNextUpdate {
            holdNextUpdate = false
            return await withCheckedContinuation { update = $0 }
        }
        if let updateResponse { return updateResponse }
        return await base.updateSession(scope: scope, request: request)
    }
    func agentOptions(scope: ClientScope, request: AgentOptionsRequest) async -> AgentOptionsResponse {
        await base.agentOptions(scope: scope, request: request)
    }
    func sendMessage(scope: ClientScope, request: SessionSendRequest) async -> CommandDispatchResponse {
        sendRequest = request
        if holdNextSend {
            holdNextSend = false
            return await withCheckedContinuation { send = $0 }
        }
        return await base.sendMessage(scope: scope, request: request)
    }
    func stopSession(scope: ClientScope, request: SessionStopRequest) async -> CommandDispatchResponse { await base.stopSession(scope: scope, request: request) }
    func mutateQueue(scope: ClientScope, request: QueueMutationRequest) async -> CommandDispatchResponse {
        queueRequests.append(request)
        if holdNextQueue {
            holdNextQueue = false
            return await withCheckedContinuation { queueContinuation = $0 }
        }
        if queueReturnsUnknown { return .unknownOutcome(request.commandID) }
        return await base.mutateQueue(scope: scope, request: request)
    }
    func queryCommand(scope: ClientScope, commandID: CommandID) async -> CommandStatusResponse {
        if let queueStatus { return queueStatus }
        return await base.queryCommand(scope: scope, commandID: commandID)
    }
    func respondToInteraction(scope: ClientScope, request: InteractionRespondRequest) async -> CommandDispatchResponse { await base.respondToInteraction(scope: scope, request: request) }
    func setAutoTranslation(scope: ClientScope, request: TranslationAutoRequest) async -> TranslationCommandResponse { await base.setAutoTranslation(scope: scope, request: request) }
    func requestTranslation(scope: ClientScope, request: TranslationRequest) async -> TranslationCommandResponse {
        translationRequest = request
        if holdNextTranslation {
            holdNextTranslation = false
            return await withCheckedContinuation { translation = $0 }
        }
        return await base.requestTranslation(scope: scope, request: request)
    }
    func cancelTranslation(scope: ClientScope, request: TranslationCancelRequest) async -> TranslationCommandResponse { await base.cancelTranslation(scope: scope, request: request) }
    func pageTranslationText(scope: ClientScope, request: TranslationTextPageRequest) async -> TranslationTextPageResponse {
        if !translationPages.isEmpty { return translationPages.removeFirst() }
        return await base.pageTranslationText(scope: scope, request: request)
    }
    func translationRequestStatus(scope: ClientScope, request: TranslationStatusRequest) async -> TranslationCommandResponse {
        if let translationStatus { return translationStatus }
        return await base.translationRequestStatus(scope: scope, request: request)
    }
    func uploadAttachment(scope: ClientScope, request: AttachmentUploadRequest) async -> AttachmentTransferResponse { await base.uploadAttachment(scope: scope, request: request) }
    func downloadAttachment(scope: ClientScope, request: AttachmentDownloadRequest) async -> AttachmentTransferResponse { await base.downloadAttachment(scope: scope, request: request) }
    func pageTranscript(scope: ClientScope, sessionID: SessionID, cursor: String?) async -> TranscriptPageResponse {
        transcriptRequestCursors.append(cursor)
        if holdNextPage {
            holdNextPage = false
            return await withCheckedContinuation { page = $0 }
        }
        if !transcriptPages.isEmpty { return transcriptPages.removeFirst() }
        return await base.pageTranscript(scope: scope, sessionID: sessionID, cursor: cursor)
    }
    func searchSessions(scope: ClientScope, query: String) async -> SearchResponse { await base.searchSessions(scope: scope, query: query) }
}
