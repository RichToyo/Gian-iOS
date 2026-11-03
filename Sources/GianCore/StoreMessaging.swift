import Foundation

extension GianClientStore {
    func performSend(explicitOriginal: Bool, reusedRequestID: TranslationRequestID?) async -> GianDispatchResult {
        guard let scope = readyScope() else { return reject(.notAuthorized) }
        if state.localConnectivity == .unavailable || state.connection == .offline {
            state.composer.notice = .offlineDraftRetained
            rememberDraft()
            persist()
            return reject(.offlineDraftRetained)
        }
        if state.sync.needsSnapshot || !mutationsAllowed() { return reject(.mutationsDisabled) }
        if case .uncertain = state.composer.send {
            state.composer.notice = .keptAfterUncertainOutcome
            return reject(.uncertainOutcome)
        }
        if state.composer.send.isInFlight { return reject(.operationInFlight) }
        if let code = requireCapability(.sessionSend) { return reject(code) }
        var draft = state.composer.draft
        let navigation = navigationEpoch
        if draft.isEmpty { return reject(.emptyDraft) }
        if draft.attachments.contains(where: { $0.state == .uploading || $0.state == .downloading }) { return reject(.operationInFlight) }
        if draft.attachments.contains(where: { $0.remoteID == nil }), let code = requireCapability(.attachmentUpload) { return reject(code) }

        var intent = DurableSendIntent(draftID: draft.id, stage: .send, explicitOriginal: explicitOriginal)
        intent.creationID = draft.boundCreationID
        if let original = memory.bundle(for: scope).operations[draft.id]?.intent,
           original.creationID == draft.boundCreationID { intent.createRequest = original.createRequest }
        if case .failed(let prior, _) = state.composer.send,
           prior.draftID == draft.id,
           memory.bundle(for: scope).submittedDrafts[draft.id]?.localRevision == draft.localRevision,
           let receipt = prior.translationReceiptID, !explicitOriginal {
            intent.translationReceiptID = receipt
            intent.translationRequestID = prior.translationRequestID
        }
        if let receipt = intent.translationReceiptID {
            guard let session = draft.boundSessionID ?? currentSessionID,
                  let record = state.translations[session]?.records.first(where: { $0.id == receipt }),
                  record.presentableText != nil else { return reject(.translationUnavailable) }
        }
        if let reusedRequestID {
            intent.translationRequestID = reusedRequestID
            intent.stage = .translation
        }
        if let existing = draft.boundSessionID ?? currentSessionID {
            guard (sessions + searchHits).contains(where: { $0.id == existing && $0.authorized && !$0.archived }) else {
                return reject(.notAuthorized)
            }
            intent.sessionID = existing
        }
        memory.update(scope) { $0.submittedDrafts[draft.id] = draft }

        if intent.sessionID == nil {
            if let stopped = await createForSend(scope: scope, intent: &intent, draft: &draft) {
                return stopped
            }
        }
        guard intent.sessionID != nil else {
            state.composer.send = .uncertain(intent)
            persist()
            return .applied
        }

        // The Host may require a canonical session before it accepts uploads.
        // First Send creates once, then uploads retained originals into that
        // session; a failed upload keeps the binding and never recreates it.
        for attachment in draft.attachments where attachment.remoteID == nil {
            let result = await upload(attachment.id)
            guard navigation == navigationEpoch else { return reject(.staleOperation) }
            guard result.isApplied,
                  state.composer.draft.attachments.first(where: { $0.id == attachment.id })?.remoteID != nil else {
                state.composer.send = .failed(intent, message: "An attachment could not be uploaded. The draft was kept.")
                persist()
                return reject(.attachmentRejected)
            }
        }
        draft = state.composer.draft
        memory.update(scope) { $0.submittedDrafts[draft.id] = draft }

        if shouldTranslate(intent, draft: draft) {
            if let stopped = await translateForSend(scope: scope, intent: &intent, draft: draft) {
                return stopped
            }
        }
        return await deliver(scope: scope, intent: &intent, draft: draft)
    }

    func retryTranslation() async -> GianDispatchResult {
        guard case .failed(let prior, _) = state.composer.send,
              prior.stage == .translation,
              let requestID = prior.translationRequestID
        else { return reject(.notFound) }
        return await performSend(explicitOriginal: false, reusedRequestID: requestID)
    }

    func sendOriginal() async -> GianDispatchResult {
        guard case .failed(let prior, _) = state.composer.send, prior.stage == .translation else {
            return reject(.translationUnavailable)
        }
        return await performSend(explicitOriginal: true, reusedRequestID: nil)
    }

    func stop() async -> GianDispatchResult {
        guard let scope = readyScope(), let sessionID = currentSessionID,
              let session = sessions.first(where: { $0.id == sessionID })
        else { return reject(.notFound) }
        if case .uncertain = state.pendingStop { return reject(.uncertainOutcome) }
        if state.pendingStop.isInFlight { return reject(.operationInFlight) }
        if !mutationsAllowed() { return reject(.mutationsDisabled) }
        if let code = requireCapability(.sessionStop) { return reject(code) }
        let commandID: CommandID = mint()
        var intent = DurableSendIntent(draftID: state.composer.draft.id, stage: .send, sendID: commandID, sessionID: sessionID)
        intent.sendDispatched = true
        state.pendingStop = .sending(intent)
        guard persist() else {
            state.pendingStop = .uncertain(intent)
            return reject(.mutationsDisabled)
        }
        let token = epoch
        let response = await service.stopSession(
            scope: scope,
            request: SessionStopRequest(commandID: commandID, sessionID: sessionID, sessionRevision: session.revision)
        )
        guard responseIsCurrent(token) else { return reject(.staleOperation) }
        if case .succeeded(let canonical) = state.pendingStop, canonical.sendID == commandID { return persistenceResult() }
        switch response {
        case .succeeded(let success) where success.commandID == commandID:
            state.pendingStop = .succeeded(intent)
        case .failed(let id, let message) where id == commandID:
            state.pendingStop = .failed(intent, message: message)
        default:
            state.pendingStop = .uncertain(intent)
        }
        return persistenceResult()
    }

    func recover() async -> GianDispatchResult {
        guard let scope = readyScope() else { return reject(.notAuthorized) }
        guard case .uncertain(let intent) = state.composer.send else {
            return await recoverAuxiliaryOperation(scope: scope)
        }
        let token = epoch
        let navigation = navigationEpoch
        switch intent.stage {
        case .create:
            guard let commandID = intent.creationID else { return reject(.notFound) }
            let status = await service.queryCommand(scope: scope, commandID: commandID)
            guard responseIsCurrent(token), navigation == navigationEpoch else { return reject(.staleOperation) }
            resolveCommand(status)
        case .send:
            guard let commandID = intent.sendID else { return reject(.notFound) }
            let status = await service.queryCommand(scope: scope, commandID: commandID)
            guard responseIsCurrent(token), navigation == navigationEpoch else { return reject(.staleOperation) }
            resolveCommand(status)
        case .translation:
            guard let sessionID = intent.sessionID, let requestID = intent.translationRequestID else {
                return reject(.notFound)
            }
            let status = await service.translationRequestStatus(
                scope: scope,
                request: TranslationStatusRequest(sessionID: sessionID, requestID: requestID)
            )
            guard responseIsCurrent(token), navigation == navigationEpoch else { return reject(.staleOperation) }
            resolveTranslation(status, intent: intent)
        }
        persist()
        return .applied
    }

    func retryCreate() async -> GianDispatchResult {
        guard let scope = readyScope(), negotiatedDirectory else { return reject(.legacyTasklessCreateUnsupported) }
        guard mutationsAllowed() else { return reject(.mutationsDisabled) }
        guard case .uncertain(var intent) = state.composer.send, intent.stage == .create,
              let request = intent.createRequest, request.commandID == intent.creationID,
              intent.draftID == state.composer.draft.id else { return reject(.uncertainOutcome) }
        // Explicit create retry only. The service reconciles command.status and
        // uses this exact command ID/params; this action never sends a message.
        intent.userRequestedSend = false
        state.composer.send = .creating(intent)
        guard persist() else { state.composer.send = .uncertain(intent); return reject(.mutationsDisabled) }
        let token = epoch
        let navigation = navigationEpoch
        let result = await service.createSession(scope: scope, request: request)
        guard responseIsCurrent(token), navigation == navigationEpoch,
              state.composer.send.intent?.creationID == request.commandID else { return reject(.staleOperation) }
        switch result {
        case .succeeded(let success) where success.commandID == request.commandID: resolveCommand(.succeeded(success))
        case .failed:
            // A retry can fail before status reconciliation (including expired
            // identity/grants). It cannot erase the original unknown effect.
            state.composer.send = .uncertain(intent)
        default: state.composer.send = .uncertain(intent)
        }
        return persistenceResult()
    }

    func resolveAuxiliaryCommand(_ status: CommandStatusResponse) -> Bool {
        if let intent = state.pendingStop.intent, intent.sendID == status.commandID {
            if case .succeeded = state.pendingStop { return true }
            if case .failed = state.pendingStop { return true }
            switch status {
            case .succeeded: state.pendingStop = .succeeded(intent)
            case .notSeen: state.pendingStop = .failed(intent, message: "The stop was not received. No retry was sent.")
            case .failed(_, let message): state.pendingStop = .failed(intent, message: message)
            case .accepted, .unknownOutcome, .expired: state.pendingStop = .uncertain(intent)
            }
            return true
        }
        guard let scope = readyScope() else { return false }
        if let entry = memory.bundle(for: scope).autoTranslationCommands.first(where: { $0.value == status.commandID }) {
            switch status {
            case .accepted, .unknownOutcome, .expired:
                state.translations[entry.key]?.notice = "Automatic translation state is unconfirmed."
            case .succeeded:
                memory.update(scope) { $0.autoTranslationCommands[entry.key] = nil }
                state.translations[entry.key]?.notice = "Refresh the confirmed automatic translation setting."
            case .notSeen, .failed:
                memory.update(scope) { $0.autoTranslationCommands[entry.key] = nil }
                state.translations[entry.key]?.notice = "Automatic translation setting was not changed."
            }
            return true
        }
        guard
              let entry = memory.bundle(for: scope).interactionCommands.first(where: { $0.value == status.commandID }),
              let index = state.interactions.firstIndex(where: { $0.id == entry.key }) else { return false }
        switch status {
        case .succeeded:
            state.interactions[index].phase = .resolvedHere
        case .notSeen:
            state.interactions[index].phase = .pending
        case .failed:
            state.interactions[index].phase = .failed
        case .accepted, .unknownOutcome, .expired:
            state.interactions[index].phase = .uncertain
            return true
        }
        memory.update(scope) { $0.interactionCommands[entry.key] = nil }
        return true
    }

    private func recoverAuxiliaryOperation(scope: ClientScope) async -> GianDispatchResult {
        let token = epoch
        if case .uncertain(let intent) = state.pendingStop, let id = intent.sendID {
            let status = await service.queryCommand(scope: scope, commandID: id)
            guard responseIsCurrent(token) else { return reject(.staleOperation) }
            _ = resolveAuxiliaryCommand(status)
            return persistenceResult()
        }
        let commands = memory.bundle(for: scope).interactionCommands
        if let interaction = state.interactions.sorted(by: { $0.id.rawValue < $1.id.rawValue }).first(where: {
            $0.phase == .uncertain && commands[$0.id] != nil
        }), let id = commands[interaction.id] {
            let status = await service.queryCommand(scope: scope, commandID: id)
            guard responseIsCurrent(token) else { return reject(.staleOperation) }
            _ = resolveAuxiliaryCommand(status)
            return persistenceResult()
        }
        if let entry = memory.bundle(for: scope).autoTranslationCommands.sorted(by: { $0.key.rawValue < $1.key.rawValue }).first {
            let status = await service.queryCommand(scope: scope, commandID: entry.value)
            guard responseIsCurrent(token) else { return reject(.staleOperation) }
            _ = resolveAuxiliaryCommand(status)
            return persistenceResult()
        }
        for session in state.translations.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let reading = state.translations[session]?.reading ?? [:]
            if let source = reading.keys.sorted().first(where: { reading[$0]?.uncertain == true }), let request = reading[source] {
                let status = await service.translationRequestStatus(scope: scope,
                    request: TranslationStatusRequest(sessionID: session, requestID: request.requestID))
                guard responseIsCurrent(token), state.translations[session]?.reading[source]?.requestID == request.requestID else {
                    return reject(.staleOperation)
                }
                applyReadingResponse(status, sessionID: session, sourceID: source, requestID: request.requestID)
                return persistenceResult()
            }
        }
        return reject(.notFound)
    }

    func resolveCommand(_ status: CommandStatusResponse) {
        guard var intent = state.composer.send.intent else { return }
        let matchesCreate = intent.stage == .create && status.commandID == intent.creationID
        let matchesSend = intent.stage == .send && status.commandID == intent.sendID
        guard matchesCreate || matchesSend else { return }
        switch status {
        case .notSeen:
            // not_seen is not proof that an old request is no longer in flight.
            // Never replace its identity or turn it into a fresh paid send.
            state.composer.send = .uncertain(intent)
            state.composer.notice = .keptAfterUncertainOutcome
        case .accepted, .unknownOutcome:
            state.composer.send = .uncertain(intent)
            state.composer.notice = .keptAfterUncertainOutcome
        case .expired:
            // The server's idempotency record expired, not necessarily the side
            // effect. Expiry never grants permission to create or send again.
            state.composer.send = .uncertain(intent)
        case .failed(_, let message):
            state.composer.send = .failed(intent, message: message.isEmpty ? "The operation failed." : message)
        case .succeeded(let success):
            if matchesCreate {
                guard let session = success.session, session.hostID == state.currentHostID,
                      session.authorized, !session.archived else {
                    state.composer.send = .uncertain(intent)
                    return
                }
                bind(session, intent: &intent)
                intent.stage = .create
                state.composer.send = .failed(intent, message: "The conversation was created. The message was not sent.")
            } else {
                clearSubmittedDraft(intent)
                state.composer.send = .succeeded(intent)
                state.composer.notice = .none
            }
        }
        rememberDraft()
    }

    func respond(_ id: InteractionID, actionID: ActionID, values: [String: InteractionValue]) async -> GianDispatchResult {
        guard let scope = readyScope(), let index = state.interactions.firstIndex(where: { $0.id == id }) else {
            return reject(.notFound)
        }
        let interaction = state.interactions[index]
        guard interaction.phase == .pending else { return reject(.interactionNotPending) }
        guard interaction.actions.contains(where: { $0.id == actionID }) else { return reject(.unknownActionID) }
        let knownInputs = Set(interaction.inputs.map(\.id))
        if values.keys.contains(where: { !knownInputs.contains($0) }) { return reject(.unknownInputID) }
        if !mutationsAllowed() { return reject(.mutationsDisabled) }
        if let code = requireCapability(.interactionRespond) { return reject(code) }
        let commandID: CommandID = mint()
        state.interactions[index].phase = .responding
        memory.update(scope) { $0.interactionCommands[id] = commandID }
        guard persist() else {
            state.interactions[index].phase = .pending
            return reject(.mutationsDisabled)
        }
        let token = epoch
        let response = await service.respondToInteraction(
            scope: scope,
            request: InteractionRespondRequest(
                commandID: commandID,
                interactionID: id,
                revision: interaction.revision,
                actionID: actionID,
                values: values
            )
        )
        guard responseIsCurrent(token), let current = state.interactions.firstIndex(where: { $0.id == id }) else {
            return reject(.staleOperation)
        }
        if state.interactions[current].phase == .resolvedHere || state.interactions[current].phase == .resolvedElsewhere {
            return persistenceResult()
        }
        switch response {
        case .succeeded(let success) where success.commandID == commandID:
            state.interactions[current].phase = .resolvedHere
            memory.update(scope) { $0.interactionCommands[id] = nil }
        case .failed(let failedID, _) where failedID == commandID:
            state.interactions[current].phase = .failed
            memory.update(scope) { $0.interactionCommands[id] = nil }
        default:
            state.interactions[current].phase = .uncertain
        }
        persist()
        return .applied
    }

    func addAttachment(_ input: AttachmentDraftInput) async -> GianDispatchResult {
        guard let scope = readyScope() else { return reject(.notAuthorized) }
        guard !state.composer.send.isInFlight else { return reject(.operationInFlight) }
        guard AttachmentRules.accepts(byteCount: input.bytes.count), AttachmentRules.safeFilename(input.filename) else {
            return reject(.attachmentRejected)
        }
        guard state.composer.draft.attachments.count < 32,
              memory.bundle(for: scope).draftBytes.values.reduce(0, { $0 + $1.count }) + input.bytes.count <= 128 * 1024 * 1024 else {
            return reject(.attachmentRejected)
        }
        let digest = SHA256Hex.digest(input.bytes)
        let attachmentID: AttachmentID = mint()
        let attachment = DraftAttachment(
            id: attachmentID,
            filename: input.filename,
            mime: input.mime,
            byteCount: input.bytes.count,
            sha256: digest,
            state: .localOnly
        )
        state.composer.draft.attachments.append(attachment)
        noteDraftEdited()
        memory.update(scope) { $0.draftBytes[attachmentID] = input.bytes }
        rememberDraft()
        guard persist() else { return reject(.mutationsDisabled) }
        guard state.localConnectivity == .available, mutationsAllowed() else {
            persist()
            return .applied
        }
        return await upload(attachmentID)
    }

    func upload(_ id: AttachmentID) async -> GianDispatchResult {
        guard let scope = readyScope(), let index = state.composer.draft.attachments.firstIndex(where: { $0.id == id }) else {
            return reject(.notFound)
        }
        if let code = requireCapability(.attachmentUpload) { return reject(code) }
        guard mutationsAllowed() else { return reject(.mutationsDisabled) }
        guard let bytes = memory.bundle(for: scope).draftBytes[id] else {
            state.composer.draft.attachments[index].state = .unavailable
            return reject(.attachmentRejected)
        }
        let attachment = state.composer.draft.attachments[index]
        guard bytes.count == attachment.byteCount, SHA256Hex.digest(bytes) == attachment.sha256 else {
            state.composer.draft.attachments[index].state = .hashMismatch
            return reject(.attachmentRejected)
        }
        state.composer.draft.attachments[index].state = .uploading
        guard persist() else { return reject(.mutationsDisabled) }
        let token = epoch
        let response = await service.uploadAttachment(
            scope: scope,
            request: AttachmentUploadRequest(
                localID: id,
                sessionID: currentSessionID ?? state.composer.draft.boundSessionID,
                filename: attachment.filename,
                mime: attachment.mime,
                sha256: attachment.sha256,
                bytes: bytes
            )
        )
        guard responseIsCurrent(token), let current = state.composer.draft.attachments.firstIndex(where: { $0.id == id }) else {
            return reject(.staleOperation)
        }
        switch response {
        case .uploaded(let remoteID, let sha) where sha == attachment.sha256:
            state.composer.draft.attachments[current].state = .uploaded
            state.composer.draft.attachments[current].remoteID = remoteID
        case .uploaded:
            state.composer.draft.attachments[current].state = .hashMismatch
        case .expired:
            state.composer.draft.attachments[current].state = .expired
        case .unavailable:
            state.composer.draft.attachments[current].state = .unavailable
        case .failed(let message):
            state.composer.draft.attachments[current].state = .failed(message)
        case .downloaded:
            state.composer.draft.attachments[current].state = .failed("unexpected download")
        }
        rememberDraft()
        persist()
        return .applied
    }

    func download(_ id: AttachmentID) async -> GianDispatchResult {
        guard let scope = readyScope() else { return reject(.notAuthorized) }
        guard let attachment = state.composer.draft.attachments.first(where: { $0.id == id }) else {
            return await downloadTranscriptFile(id)
        }
        if let cached = memory.bundle(for: scope).downloads[id],
           cached.count == attachment.byteCount, SHA256Hex.digest(cached) == attachment.sha256 {
            if let index = state.composer.draft.attachments.firstIndex(where: { $0.id == id }) {
                state.composer.draft.attachments[index].state = .cached
            }
            return .applied
        }
        if let code = requireCapability(.attachmentRead) { return reject(code) }
        guard let index = state.composer.draft.attachments.firstIndex(where: { $0.id == id }) else { return reject(.notFound) }
        state.composer.draft.attachments[index].state = .downloading
        let token = epoch
        let response = await service.downloadAttachment(
            scope: scope,
            request: AttachmentDownloadRequest(attachmentID: attachment.remoteID ?? id, sha256: attachment.sha256)
        )
        guard responseIsCurrent(token), let current = state.composer.draft.attachments.firstIndex(where: { $0.id == id }) else {
            return reject(.staleOperation)
        }
        switch response {
        case .downloaded(let sha, let bytes):
            let actual = SHA256Hex.digest(bytes)
            if actual == sha && actual == attachment.sha256, bytes.count == attachment.byteCount,
               AttachmentRules.accepts(byteCount: bytes.count) {
                memory.update(scope) { $0.cacheDownload(bytes, id: id) }
                state.composer.draft.attachments[current].state = .cached
            } else {
                state.composer.draft.attachments[current].state = .hashMismatch
            }
        case .expired:
            state.composer.draft.attachments[current].state = .expired
        case .unavailable:
            state.composer.draft.attachments[current].state = .unavailable
        case .failed(let message):
            state.composer.draft.attachments[current].state = .failed(message)
        case .uploaded:
            state.composer.draft.attachments[current].state = .failed("unexpected upload")
        }
        rememberDraft()
        persist()
        return .applied
    }

    /// Returns only bytes in the currently authorized server/account/Host
    /// namespace. UI composition may create its own protected preview URL.
    public func attachmentData(for id: AttachmentID) -> Data? {
        guard let scope = readyScope() else { return nil }
        if let bytes = transcriptFileData(for: id, scope: scope) { return bytes }
        let bundle = memory.bundle(for: scope)
        let descriptor = (bundle.drafts + Array(bundle.submittedDrafts.values)).flatMap(\.attachments)
            .first(where: { $0.id == id || $0.remoteID == id })
        let local = descriptor?.id ?? id
        guard let bytes = bundle.draftBytes[local] ?? bundle.downloads[local],
              AttachmentRules.accepts(byteCount: bytes.count) else { return nil }
        if let descriptor {
            guard bytes.count == descriptor.byteCount, SHA256Hex.digest(bytes) == descriptor.sha256 else { return nil }
        }
        return bytes
    }

    func removeAttachment(_ id: AttachmentID) -> GianDispatchResult {
        guard !state.composer.send.isInFlight else { return reject(.operationInFlight) }
        state.composer.draft.attachments.removeAll { $0.id == id }
        noteDraftEdited()
        if let scope = readyScope() {
            memory.update(scope) { bundle in
                if !bundle.submittedDrafts.values.contains(where: { $0.attachments.contains(where: { $0.id == id }) }) {
                    bundle.draftBytes[id] = nil
                }
                bundle.downloads[id] = nil
            }
        }
        rememberDraft()
        persist()
        return .applied
    }

    private func createForSend(
        scope: ClientScope,
        intent: inout DurableSendIntent,
        draft: inout DraftDocument
    ) async -> GianDispatchResult? {
        if !negotiatedDirectory {
            guard let taskID = state.composer.selection.taskID else {
                state.composer.notice = .legacyTaskRequired
                return reject(.legacyTasklessCreateUnsupported)
            }
            guard taskRecords.contains(where: { $0.id == taskID && $0.status == .open }) else {
                return reject(.missingTask)
            }
        } else if let taskID = state.composer.selection.taskID,
                  !taskRecords.contains(where: { $0.id == taskID && $0.status == .open }) {
            return reject(.missingTask)
        }
        guard let agentID = state.composer.selection.agentID else { return reject(.missingAgent) }
        guard let workspaceID = state.composer.selection.workspaceID else { return reject(.missingWorkspace) }
        guard !state.catalogRevision.isEmpty else { return reject(.missingCatalog) }
        if let code = requireCapability(.sessionCreate) { return reject(code) }
        let creationID: CommandID = mint()
        intent.creationID = creationID
        intent.createDispatched = true
        intent.stage = .create
        let request = SessionCreateRequest(commandID: creationID, catalogRevision: state.catalogRevision,
            workspaceID: workspaceID, agentID: agentID, taskID: state.composer.selection.taskID, model: state.composer.selection.model,
            thinking: state.composer.selection.thinking, serviceTier: newChatServiceTier(agentID: agentID))
        let approvalMode = state.composer.selection.approvalMode
        intent.createRequest = request
        state.composer.send = .creating(intent)
        guard persist() else {
            state.composer.send = .uncertain(intent)
            return reject(.mutationsDisabled)
        }
        let token = epoch
        let navigation = navigationEpoch
        let response = await service.createSession(
            scope: scope,
            request: request
        )
        guard responseIsCurrent(token), navigation == navigationEpoch, state.composer.draft.id == intent.draftID,
              state.composer.send.intent?.userRequestedSend == true else { return reject(.staleOperation) }
        switch response {
        case .unknownOutcome(let id) where id == creationID:
            state.composer.send = .uncertain(intent)
            state.composer.notice = .keptAfterUncertainOutcome
            persist()
            return .applied
        case .failed(let id, let message) where id == creationID:
            state.composer.send = .failed(intent, message: message)
            persist()
            return .applied
        case .succeeded(let success) where success.commandID == creationID:
            guard let session = success.session, session.hostID == scope.host, session.authorized, !session.archived else {
                state.composer.send = .uncertain(intent)
                persist()
                return .applied
            }
            bind(session, intent: &intent)
            draft = state.composer.draft
            await applyNewChatApproval(approvalMode, to: session, scope: scope)
            guard responseIsCurrent(token), navigation == navigationEpoch else { return reject(.staleOperation) }
            return nil
        default:
            state.composer.send = .uncertain(intent)
            persist()
            return .applied
        }
    }

    private func shouldTranslate(_ intent: DurableSendIntent, draft: DraftDocument) -> Bool {
        if intent.explicitOriginal || intent.translationReceiptID != nil { return false }
        guard state.capabilities.translationNegotiated, let sessionID = intent.sessionID else { return false }
        let translation = state.translations[sessionID] ?? .unsupported
        return translation.supported && translation.enabled && !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func translateForSend(
        scope: ClientScope,
        intent: inout DurableSendIntent,
        draft: DraftDocument
    ) async -> GianDispatchResult? {
        guard let sessionID = intent.sessionID else { return reject(.notFound) }
        let translation = state.translations[sessionID] ?? .unsupported
        if !translation.configured {
            state.composer.notice = .translationNeedsChoice
            return reject(.translationNotConfigured)
        }
        let requestID = intent.translationRequestID ?? mint()
        intent.translationRequestID = requestID
        intent.translationDispatched = true
        intent.stage = .translation
        state.composer.send = .awaitingTranslation(intent)
        guard persist() else {
            state.composer.send = .uncertain(intent)
            return reject(.mutationsDisabled)
        }
        let token = epoch
        let navigation = navigationEpoch
        let response = await service.requestTranslation(
            scope: scope,
            request: TranslationRequest(
                requestID: requestID,
                sessionID: sessionID,
                purpose: .send,
                text: draft.text,
                sourceID: nil
            )
        )
        guard responseIsCurrent(token), navigation == navigationEpoch, state.composer.draft.id == intent.draftID,
              state.composer.send.intent?.translationRequestID == requestID,
              state.composer.send.intent?.userRequestedSend == true,
              state.composer.send.isInFlight else { return reject(.staleOperation) }
        switch response {
        case .unknown:
            state.composer.send = .uncertain(intent)
            state.composer.notice = .keptAfterUncertainOutcome
            persist()
            return .applied
        case .failed(let message):
            state.composer.send = .failed(intent, message: message)
            state.composer.notice = .translationNeedsChoice
            persist()
            return .applied
        case .unavailable:
            state.composer.send = .failed(intent, message: "Translation is unavailable.")
            state.composer.notice = .translationNeedsChoice
            persist()
            return .applied
        case .cancelled:
            state.composer.send = .failed(intent, message: "Translation was cancelled.")
            persist()
            return .applied
        case .settled(let settledID, let record, let error):
            guard settledID == requestID else {
                state.composer.send = .uncertain(intent)
                return persistenceResult()
            }
            if let error, record == nil {
                state.composer.send = .failed(intent, message: error)
                state.composer.notice = .translationNeedsChoice
                persist()
                return .applied
            }
            guard let record else {
                state.composer.send = .failed(intent, message: "Translation text failed integrity checks.")
                persist()
                return .applied
            }
            let checked = TranslationReducer.verifiedRecord(
                id: record.id,
                sourceID: record.sourceID,
                targetLanguage: record.targetLanguage,
                text: record.presentableText,
                textLength: record.textLength,
                textSHA256: record.textSHA256,
                sourceSHA256: record.sourceSHA256,
                paged: record.integrity == .pagedVerified
            )
            guard checked.sourceSHA256 == SHA256Hex.digest(Data(draft.text.utf8)) else {
                state.composer.send = .failed(intent, message: "Translation text failed integrity checks.")
                persist()
                return .applied
            }
            intent.translationReceiptID = checked.id
            if state.translations[sessionID] == nil { state.translations[sessionID] = .unsupported }
            state.translations[sessionID]?.records.removeAll { $0.id == checked.id }
            state.translations[sessionID]?.records.append(checked)
            guard checked.presentableText != nil else {
                intent.stage = .translation
                state.composer.send = .failed(intent, message: "Translation full text must be loaded before sending.")
                return persistenceResult()
            }
            intent.stage = .send
            state.composer.send = .sending(intent)
            return nil
        case .state:
            state.composer.send = .uncertain(intent)
            persist()
            return .applied
        }
    }

    private func deliver(scope: ClientScope, intent: inout DurableSendIntent, draft: DraftDocument) async -> GianDispatchResult {
        guard let sessionID = intent.sessionID else { return reject(.notFound) }
        if let session = sessions.first(where: { $0.id == sessionID }),
           session.status == .running || session.status == .pending {
            if let code = requireCapability(.queueAdd) { return reject(code) }
        }
        if intent.sendDispatched {
            state.composer.send = .uncertain(intent)
            persist()
            return .applied
        }
        let sendID: CommandID = mint()
        intent.sendID = sendID
        intent.sendDispatched = true
        intent.stage = .send
        let busy: SendBusyPolicy?
        if let session = sessions.first(where: { $0.id == sessionID }),
           session.status == .running || session.status == .pending {
            busy = .queue
        } else {
            busy = nil
        }
        let translation: TranslationDispatch?
        if intent.explicitOriginal {
            translation = .original
        } else if let receipt = intent.translationReceiptID {
            translation = .receipt(receipt)
        } else {
            translation = nil
        }
        let request = SessionSendRequest(commandID: sendID, sessionID: sessionID, text: draft.text,
            attachmentIDs: draft.attachments.compactMap(\.remoteID), busy: busy, translation: translation)
        intent.sendRequest = request
        state.composer.send = .sending(intent)
        guard persist() else {
            state.composer.send = .uncertain(intent)
            return reject(.mutationsDisabled)
        }
        let token = epoch
        let navigation = navigationEpoch
        let response = await service.sendMessage(
            scope: scope,
            request: request
        )
        guard responseIsCurrent(token), navigation == navigationEpoch, state.composer.draft.id == intent.draftID else { return reject(.staleOperation) }
        if case .succeeded(let canonical) = state.composer.send, canonical.sendID == sendID {
            return persistenceResult()
        }
        switch response {
        case .succeeded(let success) where success.commandID == sendID:
            clearSubmittedDraft(intent)
            state.composer.send = .succeeded(intent)
            state.composer.notice = .none
        case .failed(let id, let message) where id == sendID:
            state.composer.send = .failed(intent, message: message)
        default:
            state.composer.send = .uncertain(intent)
            state.composer.notice = .keptAfterUncertainOutcome
        }
        rememberDraft()
        persist()
        return .applied
    }

    private func bind(_ session: SessionRecord, intent: inout DurableSendIntent) {
        upsertSession(session)
        intent.sessionID = session.id
        state.composer.draft.boundSessionID = session.id
        state.composer.draft.boundCreationID = intent.creationID
        state.composer.draft.target = .conversation(session.id)
        state.composer.draft.hostID = session.hostID
        state.navigation.destination = .conversation(session.id)
        state.conversation = ConversationProjection(
            session: session,
            items: [],
            cursor: nil,
            hasOlder: false,
            hydratedFromCache: false
        )
        reproject()
        rememberDraft()
    }

    private func clearSubmittedDraft(_ intent: DurableSendIntent) {
        guard let scope = readyScope(),
              let submitted = memory.bundle(for: scope).submittedDrafts[intent.draftID] else { return }
        if state.composer.draft.id == submitted.id, state.composer.draft.localRevision == submitted.localRevision {
            state.composer.draft.text = ""
            state.composer.draft.attachments = []
            state.composer.draft.localRevision += 1
        }
        memory.update(scope) { $0.submittedDrafts[intent.draftID] = nil }
    }

    private func resolveTranslation(_ status: TranslationCommandResponse, intent: DurableSendIntent) {
        switch status {
        case .unknown:
            state.composer.send = .uncertain(intent)
        case .settled(let requestID, let record, let error):
            guard requestID == intent.translationRequestID else { return }
            if let record, let session = intent.sessionID, let scope = readyScope(),
               let submitted = memory.bundle(for: scope).submittedDrafts[intent.draftID] {
                var next = intent
                next.translationReceiptID = record.id
                let checked = TranslationReducer.verifiedRecord(id: record.id, sourceID: record.sourceID,
                    targetLanguage: record.targetLanguage, text: record.presentableText, textLength: record.textLength,
                    textSHA256: record.textSHA256, sourceSHA256: record.sourceSHA256, paged: record.integrity == .pagedVerified)
                guard checked.sourceSHA256 == SHA256Hex.digest(Data(submitted.text.utf8)) else { return }
                if state.translations[session] == nil { state.translations[session] = .unsupported }
                state.translations[session]?.records.removeAll { $0.id == checked.id }
                state.translations[session]?.records.append(checked)
                next.stage = .translation
                state.composer.send = .failed(next, message: checked.presentableText == nil
                    ? "Translation full text must be loaded before sending."
                    : "Translation finished. The message was not sent again.")
            } else {
                state.composer.send = .failed(intent, message: error ?? "The translation request was not found. The draft was kept.")
            }
        case .failed(let message):
            state.composer.send = .failed(intent, message: message)
        case .unavailable:
            state.composer.send = .failed(intent, message: "Translation is unavailable.")
        case .cancelled:
            state.composer.send = .failed(intent, message: "Translation was cancelled.")
        case .state:
            state.composer.send = .uncertain(intent)
        }
        state.composer.notice = .keptAfterUncertainOutcome
    }
}
