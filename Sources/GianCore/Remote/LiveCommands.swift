import Foundation

extension LiveGianClientService: GianClientServicing {
    func requireConnection(_ scope: ClientScope) throws -> RemoteRelay {
        guard relayScope == scope, let relay, relay.isOpen, !overflowed else { throw RemoteClientError.disconnected }
        let vault = try requireVault(server: scope.server, account: scope.account)
        guard vault.hosts[scope.host.rawValue]?.deviceID != nil, try !hostIsInvalid(scope) else { throw RemoteClientError.notAuthorized }
        return relay
    }
    func requireCapability(_ capability: BusinessCapability, scope: ClientScope) throws {
        _ = try requireConnection(scope)
        // Not the snapshot: any session event drops it, and a message sent
        // right after one (the first message of a new chat) was refused.
        guard let capabilities, try capabilities[capability.rawValue].string("state") == "supported" else {
            throw RemoteClientError.capabilityDenied
        }
    }
    func requireTranslation(_ scope: ClientScope) throws {
        let relay = try requireConnection(scope)
        guard relay.features.contains(.conversationTranslation) else { throw RemoteClientError.unsupported }
    }

    func rpc(scope: ClientScope, method: String, params: WireValue, command: CommandID? = nil,
             expected: [String: WireValue] = [:]) async throws -> WireValue {
        let remote = try requireConnection(scope)
        guard commandWaiters.count < 64 else { throw RemoteClientError.bufferLimit }
        let captured = epoch
        let id = command?.rawValue ?? newID()
        guard commandWaiters[id] == nil else { throw RemoteClientError.invalidPayload }
        let createdAt = try RemoteWire.commandDate(id)
        let attempt = newID()
        let mailbox = RemoteMailbox()
        commandWaiters[id] = RemoteCommandWaiter(attempt: attempt, method: method, mailbox: mailbox)
        defer { if commandWaiters[id]?.mailbox === mailbox { commandWaiters.removeValue(forKey: id) } }
        var fields = expected
        fields["host_generation"] = .string(remote.generation)
        let request = WireValue.object(["type": .string("command.request"), "command_id": .string(id), "created_at": .int(createdAt),
            "attempt_id": .string(attempt), "method": .string(method), "params": params, "expected": .object(fields)])
        try await remote.send(request)
        let response = try await mailbox.next()
        try checkEpoch(captured)
        guard try response.boolean("ok") else { throw RemoteWire.error(response["error"]) }
        guard !response["data"].isNull else { throw RemoteClientError.invalidPayload }
        if lastFailure != nil, method != "state.refresh", method != "catalog.read" { lastFailure = nil; diagnostic(.cleared, scope: scope) }
        return response["data"]
    }

    func commandSuccess(_ data: WireValue, method: String, command: CommandID, scope: ClientScope, queueSession: SessionID? = nil) throws -> CommandSuccess {
        let session: SessionRecord?
        var queue: SessionQueue?
        switch method {
        case "session.create": session = try RemoteMapping.session(data, host: scope.host)
        case "session.send":
            try validateDelivery(data)
            session = try RemoteMapping.session(data["session"], host: scope.host)
        case "session.stop":
            _ = try data.boolean("already_idle"); _ = try data.string("session_revision")
            session = nil
        case "interaction.respond":
            guard try data.boolean("resolved") else { throw RemoteClientError.invalidPayload }
            _ = try data.identifier("interaction_id"); _ = try data.string("revision")
            session = nil
        case "queue.update", "queue.remove", "queue.clear", "queue.send_now":
            guard let queueSession else { throw RemoteClientError.invalidPayload }
            if method == "queue.send_now" {
                try data.closed(["mode", "queue", "queue_revision"], optional: ["affected"])
                let mode = try data.string("mode")
                guard ["noop", "started", "steered"].contains(mode) else { throw RemoteClientError.invalidPayload }
                if !data["affected"].isNull {
                    for item in try data.array("affected", maximum: 64) {
                        try item.closed(["queue_id", "state", "turn_number"])
                        _ = try item.identifier("queue_id")
                        guard ["started", "steered"].contains(try item.string("state")) else { throw RemoteClientError.invalidPayload }
                        _ = try item.integer("turn_number", range: 1...9_007_199_254_740_991)
                    }
                }
            } else {
                try data.closed(["queue", "queue_revision"])
            }
            queue = try RemoteMapping.queue(.object(["revision": data["queue_revision"], "entries": data["queue"]]), session: queueSession)
            session = nil
        default: throw RemoteClientError.invalidPayload
        }
        return CommandSuccess(commandID: command, session: session, deliveryID: try data.optionalString("delivery_id"), queue: queue)
    }

    func validateDelivery(_ data: WireValue) throws {
        guard let state = try data.optionalString("delivery_state") else { return }
        switch state {
        case "started", "queued", "steered", "completed": break
        case "unknown": throw RemoteClientError.server(code: "UNKNOWN_OUTCOME", retryAfter: nil)
        case "error", "stopped", "cancelled": throw RemoteClientError.deliveryNotStarted
        default: throw RemoteClientError.invalidPayload
        }
    }

    func dispatchCommand(scope: ClientScope, id: CommandID, method: String, params: WireValue,
                         capability: BusinessCapability, expected: [String: WireValue] = [:],
                         queueSession: SessionID? = nil) async -> CommandDispatchResponse {
        var attempted = false
        var knownPriorAttempt = false
        let captured = epoch
        do {
            _ = try requireConnection(scope)
            var vault = try requireVault(server: scope.server, account: scope.account)
            guard let device = vault.hosts[scope.host.rawValue]?.deviceID else { throw RemoteClientError.notAuthorized }
            let fingerprint = RemoteWire.hash(try WireValue.object(["method": .string(method), "params": params,
                "server": .string(scope.server.absoluteString), "account": .string(scope.account.id), "host": .string(scope.host.rawValue), "device": .string(device)]).encoded())
            if let existing = issuedCommands[id.rawValue], existing != fingerprint { throw RemoteClientError.integrity }
            if let previous = vault.commandAttempts[id.rawValue] {
                knownPriorAttempt = true
                guard previous == fingerprint else { throw RemoteClientError.server(code: "UNKNOWN_OUTCOME", retryAfter: nil) }
            }
            // Always reconcile a durable command ID first. A restarted client has no in-memory ledger.
            let status = try await statusData(scope: scope, command: id)
            try checkEpoch(captured)
            switch try status.string("state") {
            case "succeeded": return .succeeded(try commandSuccess(status["result"], method: method, command: id, scope: scope, queueSession: queueSession))
            case "failed": return .failed(id, message: RemoteWire.error(status["error"]).safeDescription)
            case "expired": return .failed(id, message: RemoteClientError.expired.safeDescription)
            case "accepted", "unknown_outcome": return .unknownOutcome(id)
            case "not_seen": break
            default: throw RemoteClientError.invalidPayload
            }
            guard issuedCommands.count < 2048 || issuedCommands[id.rawValue] != nil else { throw RemoteClientError.bufferLimit }
            issuedCommands[id.rawValue] = fingerprint
            try requireCapability(capability, scope: scope)
            vault = try requireVault(server: scope.server, account: scope.account)
            guard vault.commandAttempts.count < 2048 || vault.commandAttempts[id.rawValue] != nil else { throw RemoteClientError.bufferLimit }
            vault.commandAttempts[id.rawValue] = fingerprint
            try saveVault(vault, server: scope.server, account: scope.account, epoch: captured)
            attempted = true
            let data = try await rpc(scope: scope, method: method, params: params, command: id, expected: expected)
            return .succeeded(try commandSuccess(data, method: method, command: id, scope: scope, queueSession: queueSession))
        } catch {
            let safe = note(error)
            // Once bytes may have left the device, transport/cancellation/decode failure is uncertain.
            if case .server(code: "UNKNOWN_OUTCOME", retryAfter: _) = safe { return .unknownOutcome(id) }
            if attempted || knownPriorAttempt, safe != .capabilityDenied, safe != .expired,
               !RemoteWire.isDefinitiveRejection(safe) { return .unknownOutcome(id) }
            return .failed(id, message: safe.safeDescription)
        }
    }

    public func createSession(scope: ClientScope, request: SessionCreateRequest) async -> CommandDispatchResponse {
        if request.taskID == nil {
            do {
                guard try requireConnection(scope).features.contains(.sessionDirectoryV1) else {
                    return .failed(request.commandID, message: RemoteClientError.unsupported.safeDescription)
                }
            } catch { return .failed(request.commandID, message: note(error).safeDescription) }
        }
        var params: [String: WireValue] = ["catalog_revision": .string(request.catalogRevision), "workspace_id": .string(request.workspaceID.rawValue),
            "agent_id": .string(request.agentID.rawValue)]
        if let task = request.taskID { params["task_id"] = .string(task.rawValue) }
        if let model = request.model { params["model"] = .string(model) }
        if let thinking = request.thinking { params["thinking"] = .string(thinking) }
        if let tier = request.serviceTier { params["service_tier"] = .string(tier) }
        if let name = request.name { params["name"] = .string(name) }
        return await dispatchCommand(scope: scope, id: request.commandID, method: "session.create", params: .object(params), capability: .sessionCreate,
            expected: ["catalog_revision": .string(request.catalogRevision)])
    }
    public func sendMessage(scope: ClientScope, request: SessionSendRequest) async -> CommandDispatchResponse {
        guard request.text.utf16.count <= 64 * 1024, request.attachmentIDs.count <= 32 else {
            return .failed(request.commandID, message: RemoteClientError.bufferLimit.safeDescription)
        }
        var params: [String: WireValue] = ["session_id": .string(request.sessionID.rawValue), "text": .string(request.text)]
        if let busy = request.busy { params["busy"] = .string(busy.rawValue) }
        if !request.attachmentIDs.isEmpty {
            params["items"] = .array(request.attachmentIDs.map { .object(["type": .string("attachment"), "attachment_id": .string($0.rawValue)]) })
        }
        if let translation = request.translation {
            do { try requireTranslation(scope) } catch { return .failed(request.commandID, message: note(error).safeDescription) }
            switch translation {
            case .original: params["translation_id"] = .string("original")
            case .receipt(let id): params["translation_id"] = .string(id.rawValue)
            }
        }
        return await dispatchCommand(scope: scope, id: request.commandID, method: "session.send", params: .object(params), capability: .sessionSend)
    }
    public func stopSession(scope: ClientScope, request: SessionStopRequest) async -> CommandDispatchResponse {
        await dispatchCommand(scope: scope, id: request.commandID, method: "session.stop", params: .object([
            "session_id": .string(request.sessionID.rawValue), "session_revision": .string(request.sessionRevision),
        ]), capability: .sessionStop, expected: ["session_revision": .string(request.sessionRevision)])
    }

    public func mutateQueue(scope: ClientScope, request: QueueMutationRequest) async -> CommandDispatchResponse {
        var params: [String: WireValue] = ["session_id": .string(request.sessionID.rawValue),
                                           "expected_queue_revision": .string(request.revision)]
        let method: String
        let capability: BusinessCapability
        switch request.mutation {
        case .update(let id, let text):
            method = "queue.update"; capability = .queueUpdate
            params["queue_id"] = .string(id); params["text"] = .string(text)
        case .remove(let id):
            method = "queue.remove"; capability = .queueRemove
            params["queue_id"] = .string(id)
        case .clear:
            method = "queue.clear"; capability = .queueClear
        case .sendNow:
            method = "queue.send_now"; capability = .queueSendNow
        }
        return await dispatchCommand(scope: scope, id: request.commandID, method: method, params: .object(params),
                                     capability: capability, queueSession: request.sessionID)
    }
    public func respondToInteraction(scope: ClientScope, request: InteractionRespondRequest) async -> CommandDispatchResponse {
        var values: [String: WireValue] = [:]
        for (key, value) in request.values {
            switch value {
            case .text(let text): values[key] = .string(text)
            case .boolean(let boolean): values[key] = .bool(boolean)
            case .list(let list): values[key] = .strings(list)
            }
        }
        return await dispatchCommand(scope: scope, id: request.commandID, method: "interaction.respond", params: .object([
            "interaction_id": .string(request.interactionID.rawValue), "interaction_revision": .string(request.revision),
            "action_id": .string(request.actionID.rawValue), "values": .object(values),
        ]), capability: .interactionRespond, expected: ["interaction_id": .string(request.interactionID.rawValue), "interaction_revision": .string(request.revision)])
    }
    func statusData(scope: ClientScope, command: CommandID) async throws -> WireValue {
        let result = try await rpc(scope: scope, method: "command.status", params: .object(["command_id": .string(command.rawValue)]))
        guard try result.string("command_id") == command.rawValue else { throw RemoteClientError.integrity }
        return result
    }
    public func queryCommand(scope: ClientScope, commandID: CommandID) async -> CommandStatusResponse {
        do {
            let result = try await statusData(scope: scope, command: commandID)
            switch try result.string("state") {
            case "not_seen": return .notSeen(commandID)
            case "accepted": return .accepted(commandID)
            case "unknown_outcome": return .unknownOutcome(commandID)
            case "expired": return .expired(commandID)
            case "failed": return .failed(commandID, message: RemoteWire.error(result["error"]).safeDescription)
            case "succeeded":
                let data = result["result"]
                let session: SessionRecord?
                if !data["session"].isNull { try validateDelivery(data); session = try RemoteMapping.session(data["session"], host: scope.host) }
                else if !data["workspace_id"].isNull { session = try RemoteMapping.session(data, host: scope.host) }
                else { session = nil }
                return .succeeded(CommandSuccess(commandID: commandID, session: session, deliveryID: try data.optionalString("delivery_id")))
            default: throw RemoteClientError.invalidPayload
            }
        } catch {
            let safe = note(error)
            if safe == .deliveryNotStarted { return .failed(commandID, message: safe.safeDescription) }
            return .unknownOutcome(commandID)
        }
    }
}

extension RemoteWire {
    static func isDefinitiveRejection(_ error: RemoteClientError) -> Bool {
        if case .server(let code, _) = error {
            return ["PRECONDITION_FAILED", "REMOTE_CAPABILITY_DENIED", "COMMAND_EXPIRED", "RESOURCE_NOT_FOUND", "DEVICE_REVOKED"].contains(code)
        }
        return error == .notAuthorized || error == .deviceRevoked || error == .versionMismatch || error == .deliveryNotStarted
    }
}
