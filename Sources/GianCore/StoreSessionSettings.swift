import Foundation

extension GianClientStore {
    /// Reads an Agent's conversation options once per catalog revision.
    func loadAgentOptions(_ agentID: AgentID) async -> GianDispatchResult {
        guard let scope = readyScope() else { return reject(.notAuthorized) }
        let revision = state.catalogRevision
        if state.agentOptions[agentID]?.catalogRevision == revision { return .applied }
        let token = epoch
        let response = await service.agentOptions(
            scope: scope,
            request: AgentOptionsRequest(agentID: agentID, catalogRevision: revision.isEmpty ? nil : revision)
        )
        guard responseIsCurrent(token), state.catalogRevision == revision else { return reject(.staleOperation) }
        switch response {
        case .options(var options):
            // Keyed by the catalog this read was made against.
            options.catalogRevision = revision
            state.agentOptions[agentID] = options
            return .applied
        case .unavailable:
            state.agentOptions[agentID] = AgentConversationOptions(catalogRevision: revision)
            return reject(.capabilityUnsupported)
        case .failed:
            return reject(.notFound)
        }
    }

    /// Fetches the Agents' own logos (both appearances) once per Host. A Host
    /// without a logo for an Agent isn't asked again; one that predates
    /// `proxy.logo` isn't asked at all. Failed reads retry on the next load.
    func loadAgentLogos() async -> GianDispatchResult {
        guard let scope = readyScope() else { return reject(.notAuthorized) }
        guard !agentLogoUnsupportedHosts.contains(scope.host) else { return reject(.capabilityUnsupported) }
        let pluginIDs = Set(state.agents.map(\.pluginID) + sessions.map(\.pluginID)).filter { !$0.isEmpty }.sorted()
        let token = epoch
        for pluginID in pluginIDs {
            for variant in AgentLogoVariant.allCases {
                let key = "\(scope.host.rawValue)|\(pluginID)|\(variant.rawValue)"
                guard state.agentLogos[pluginID]?[variant] == nil, !agentLogoSkips.contains(key) else { continue }
                agentLogoSkips.insert(key)
                let response = await service.agentLogo(scope: scope, pluginID: pluginID, variant: variant)
                guard responseIsCurrent(token) else {
                    agentLogoSkips.remove(key)
                    return reject(.staleOperation)
                }
                switch response {
                case .logo(let data):
                    agentLogoSkips.remove(key)
                    state.agentLogos[pluginID, default: AgentLogoImages()][variant] = data
                case .notFound:
                    break
                case .unsupported:
                    agentLogoSkips.remove(key)
                    agentLogoUnsupportedHosts.insert(scope.host)
                    return reject(.capabilityUnsupported)
                case .failed:
                    agentLogoSkips.remove(key)
                }
            }
        }
        return .applied
    }

    /// Changes one setting of the open conversation. The Host accepts this
    /// while a turn runs and applies it from the next turn. The returned record
    /// replaces ours so the next update carries the current revision.
    func updateConversation(_ change: SessionSettingChange) async -> GianDispatchResult {
        guard let scope = readyScope(), let sessionID = currentSessionID,
              let session = sessions.first(where: { $0.id == sessionID }) else { return reject(.notFound) }
        if !mutationsAllowed() { return reject(.mutationsDisabled) }
        if let code = requireCapability(.sessionUpdate) { return reject(code) }
        guard !state.settingsUpdatePending else { return reject(.staleOperation) }
        state.settingsUpdatePending = true
        state.settingsNotice = nil
        defer { state.settingsUpdatePending = false }
        let token = epoch
        let navigation = navigationEpoch
        let response = await service.updateSession(
            scope: scope,
            request: SessionUpdateRequest(commandID: mint(), sessionID: sessionID, sessionRevision: session.revision, change: change)
        )
        guard responseIsCurrent(token), navigation == navigationEpoch else { return reject(.staleOperation) }
        switch response {
        case .updated(let record):
            guard record.id == sessionID, record.hostID == scope.host else { return reject(.scopeMismatch) }
            upsertSession(record)
            if state.conversation?.session.id == sessionID {
                state.conversation?.session = sessions.first { $0.id == sessionID } ?? record
            }
            reproject()
            return persistenceResult()
        case .rejected:
            state.settingsNotice = "The Host didn't accept that change. Refresh and try again."
            return reject(.staleOperation)
        case .unknownOutcome:
            state.settingsNotice = "The change isn't confirmed yet. Refresh to see the current setting."
            return reject(.uncertainOutcome)
        case .unsupported:
            return reject(.capabilityUnsupported)
        }
    }

    /// New-chat Agent change: options belong to the previous Agent.
    func selectAgentForNewChat(_ agentID: AgentID) -> GianDispatchResult {
        if state.composer.selection.agentID != agentID {
            state.composer.selection.thinking = nil
            state.composer.selection.fast = nil
            state.composer.selection.approvalMode = nil
        }
        state.composer.selection.agentID = agentID
        return persistenceResult()
    }

    /// New-chat model change: Fast stays only where the model supports it.
    func selectModelForNewChat(_ model: String?) -> GianDispatchResult {
        state.composer.selection.model = model
        if state.composer.selection.fast == true, let agentID = state.composer.selection.agentID,
           state.agentOptions[agentID]?.fastAvailable(forModel: model ?? defaultModel(of: agentID)) != true {
            state.composer.selection.fast = nil
        }
        return persistenceResult()
    }

    func defaultModel(of agentID: AgentID) -> String? {
        guard let agent = state.agents.first(where: { $0.id == agentID }) else { return nil }
        return agent.models?.first(where: \.isDefault)?.id ?? agent.defaultModel
    }

    /// `session.create` carries Fast only when the Agent offers it for the model.
    func newChatServiceTier(agentID: AgentID) -> String? {
        guard state.composer.selection.fast == true else { return nil }
        let model = state.composer.selection.model ?? defaultModel(of: agentID)
        return state.agentOptions[agentID]?.fastAvailable(forModel: model) == true ? "fast" : nil
    }

    /// `session.create` has no approval field, so a chosen approval mode is
    /// applied right after creation, before the first message is sent.
    /// Best effort: a failure leaves the Agent default and says so.
    func applyNewChatApproval(_ mode: String?, to session: SessionRecord, scope: ClientScope) async {
        guard let mode, mode != session.approvalMode, requireCapability(.sessionUpdate) == nil else { return }
        let response = await service.updateSession(
            scope: scope,
            request: SessionUpdateRequest(commandID: mint(), sessionID: session.id, sessionRevision: session.revision, change: .approvalMode(mode))
        )
        if case .updated(let record) = response, record.id == session.id {
            upsertSession(record)
        } else {
            state.settingsNotice = "The conversation started with the Agent's default approval mode."
        }
    }
}
