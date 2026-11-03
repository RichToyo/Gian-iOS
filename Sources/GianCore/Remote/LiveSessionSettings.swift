import Foundation

extension LiveGianClientService {
    /// `session.update`: one setting per command, guarded by the conversation
    /// revision. The result is the Host's record with the new revision, which
    /// callers must store; the `session.updated` event can arrive before the
    /// revision bump and is not a substitute.
    public func updateSession(scope: ClientScope, request: SessionUpdateRequest) async -> SessionUpdateResponse {
        do {
            try requireCapability(.sessionUpdate, scope: scope)
        } catch {
            let safe = note(error)
            return safe == .capabilityDenied || safe == .unsupported ? .unsupported : .rejected(message: safe.safeDescription)
        }
        var params: [String: WireValue] = [
            "session_id": .string(request.sessionID.rawValue),
            "session_revision": .string(request.sessionRevision),
        ]
        switch request.change {
        case .model(let model): params["model"] = model.map(WireValue.string) ?? .null
        case .thinking(let thinking): params["thinking"] = thinking.map(WireValue.string) ?? .null
        case .fast(let enabled): params["service_tier"] = .string(enabled ? "fast" : "standard")
        case .approvalMode(let mode): params["approval_mode"] = mode.map(WireValue.string) ?? .null
        }
        do {
            let data = try await rpc(scope: scope, method: "session.update", params: .object(params), command: request.commandID)
            return .updated(try RemoteMapping.session(data, host: scope.host))
        } catch {
            let safe = note(error)
            // The Host reports invalid or unsupported values as INVALID_FRAME.
            if RemoteWire.isDefinitiveRejection(safe) { return .rejected(message: safe.safeDescription) }
            if case .server(let code, _) = safe, code == "INVALID_FRAME" { return .rejected(message: safe.safeDescription) }
            return .unknownOutcome
        }
    }

    /// `catalog.agent` is the only source of approval choices, thinking
    /// labels and per-model Fast support. Account-bound devices only.
    public func agentOptions(scope: ClientScope, request: AgentOptionsRequest) async -> AgentOptionsResponse {
        var params: [String: WireValue] = ["agent_id": .string(request.agentID.rawValue)]
        if let revision = request.catalogRevision { params["catalog_revision"] = .string(revision) }
        do {
            let data = try await rpc(scope: scope, method: "catalog.agent", params: .object(params))
            return .options(try RemoteMapping.agentOptions(data))
        } catch {
            let safe = note(error)
            if safe == .unsupported || safe == .capabilityDenied { return .unavailable }
            return .failed(safe.safeDescription)
        }
    }
}
