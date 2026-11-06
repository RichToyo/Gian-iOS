import Foundation

extension LiveGianClientService {
    public func setAutoTranslation(scope: ClientScope, request: TranslationAutoRequest) async -> TranslationCommandResponse {
        do {
            try requireTranslation(scope)
            // The Host grants `translation.set_auto` under session.update.
            try requireCapability(.sessionUpdate, scope: scope)
            var params: [String: WireValue] = ["session_id": .string(request.sessionID.rawValue), "enabled": .bool(request.enabled)]
            if let enabled = request.expectedEnabled { params["expected_enabled"] = .bool(enabled) }
            if let revision = request.expectedRevision { params["expected_revision"] = .int(revision) }
            let data = try await rpc(scope: scope, method: "translation.set_auto", params: .object(params), command: request.commandID)
            return .state(try RemoteMapping.translationState(data))
        } catch {
            let safe = note(error)
            if safe == .unsupported { return .unavailable }
            return .failed(safe.safeDescription)
        }
    }
    public func requestTranslation(scope: ClientScope, request: TranslationRequest) async -> TranslationCommandResponse {
        var mayHaveBeenDispatched = false
        do {
            try requireTranslation(scope)
            try requireCapability(.sessionSend, scope: scope)
            guard !request.text.isEmpty, request.text.utf16.count <= 120_000 else { throw RemoteClientError.bufferLimit }
            let key = "translation:\(request.sessionID.rawValue):\(request.requestID.rawValue)"
            guard mailboxes[key] == nil, mailboxes.count < 64 else { throw RemoteClientError.bufferLimit }
            let mailbox = RemoteMailbox(limit: 1)
            mailboxes[key] = mailbox
            defer { if mailboxes[key] === mailbox { mailboxes.removeValue(forKey: key) } }
            // Recovery is a query, never a second paid model request with a new identity.
            let status = try await rpc(scope: scope, method: "translation.request_status", params: .object([
                "session_id": .string(request.sessionID.rawValue), "request_id": .string(request.requestID.rawValue),
            ]))
            let state = try status.string("state")
            if state == "succeeded" || state == "failed" {
                mayHaveBeenDispatched = true
                if !status["record"].isNull { try validateTranslationSource(status["record"], request: request) }
                return try await settledTranslation(status, request: request.requestID, session: request.sessionID, scope: scope)
            }
            if state == "unknown" {
                var params: [String: WireValue] = ["session_id": .string(request.sessionID.rawValue), "request_id": .string(request.requestID.rawValue),
                    "purpose": .string(request.purpose.rawValue), "text": .string(request.text)]
                if let source = request.sourceID { params["source_id"] = .string(source) }
                var vault = try requireVault(server: scope.server, account: scope.account)
                let identity = "\(scope.host.rawValue):\(request.requestID.rawValue)"
                let fingerprint = RemoteWire.hash(try WireValue.object(params).encoded())
                if let previous = vault.translationAttempts[identity] {
                    guard previous == fingerprint else { throw RemoteClientError.integrity }
                    return .unknown(request.requestID)
                }
                guard vault.translationAttempts.count < 2048 else { throw RemoteClientError.bufferLimit }
                // A lost paid-request ACK stays uncertain even across process restarts.
                vault.translationAttempts[identity] = fingerprint
                try saveVault(vault, server: scope.server, account: scope.account, epoch: epoch)
                mayHaveBeenDispatched = true
                let accepted = try await rpc(scope: scope, method: "translation.request", params: .object(params))
                guard try accepted.string("request_id") == request.requestID.rawValue,
                      try accepted.string("status") == "accepted" else { throw RemoteClientError.invalidPayload }
            } else if state == "pending" { mayHaveBeenDispatched = true }
            else { throw RemoteClientError.invalidPayload }
            // An accepted receipt is not a settled translation. Wait for the matching subscription event.
            let result = try await mailbox.next(timeout: .seconds(120))
            if !result["upsert"].isNull { try validateTranslationSource(result["upsert"], request: request) }
            guard !result["upsert"].isNull || !result["error"].isNull else { throw RemoteClientError.invalidPayload }
            let record = result["upsert"].isNull ? nil : try RemoteMapping.reading(result["upsert"], session: request.sessionID)
            return .settled(request.requestID, record: try await completeTranslation(record, session: request.sessionID, scope: scope),
                error: try RemoteMapping.safeTranslationError(result))
        } catch {
            let safe = note(error)
            if mayHaveBeenDispatched { return .unknown(request.requestID) }
            if safe == .unsupported { return .unavailable }
            if safe == .timeout || safe == .disconnected || safe == .transport || safe == .cancelled { return .unknown(request.requestID) }
            return .failed(safe.safeDescription)
        }
    }

    func validateTranslationSource(_ record: WireValue, request: TranslationRequest) throws {
        guard try record.string("purpose") == request.purpose.rawValue,
              try record.string("source_sha256") == RemoteWire.hash(Data(request.text.utf8)) else { throw RemoteClientError.integrity }
        if let source = request.sourceID {
            guard try record.optionalString("source_id") == source else { throw RemoteClientError.integrity }
        }
    }
    public func cancelTranslation(scope: ClientScope, request: TranslationCancelRequest) async -> TranslationCommandResponse {
        let key = "translation:\(request.sessionID.rawValue):\(request.requestID.rawValue)"
        mailboxes[key]?.fail(.cancelled)
        do {
            try requireTranslation(scope)
            let result = try await rpc(scope: scope, method: "translation.cancel", params: .object([
                "session_id": .string(request.sessionID.rawValue), "request_id": .string(request.requestID.rawValue),
            ]))
            guard try result.boolean("ok") else { throw RemoteClientError.invalidPayload }
            return .cancelled(request.requestID)
        } catch { _ = note(error); return .unknown(request.requestID) }
    }
    public func pageTranslationText(scope: ClientScope, request: TranslationTextPageRequest) async -> TranslationTextPageResponse {
        do {
            try requireTranslation(scope)
            guard request.offset.map({ $0 >= 0 && $0 <= 1_000_000 }) ?? true else { throw RemoteClientError.invalidPayload }
            var params: [String: WireValue] = ["session_id": .string(request.sessionID.rawValue), "record_id": .string(request.recordID.rawValue)]
            if let offset = request.offset { params["offset"] = .int(offset) }
            let result = try await rpc(scope: scope, method: "translation.result_text", params: .object(params))
            let text = try result.string("text")
            let next = result["next_offset"].isNull ? nil : try result.integer("next_offset", range: 0...1_000_000)
            if let next { guard next == (request.offset ?? 0) + text.utf16.count, next > (request.offset ?? 0) else { throw RemoteClientError.integrity } }
            return .page(text: text, nextOffset: next)
        } catch {
            let safe = note(error)
            if safe == .expired || safe == .server(code: "RESOURCE_NOT_FOUND", retryAfter: nil) { return .notFound }
            if safe == .timeout || safe == .disconnected { return .unknown }
            return .failed(safe.safeDescription)
        }
    }
    public func translationRequestStatus(scope: ClientScope, request: TranslationStatusRequest) async -> TranslationCommandResponse {
        do {
            try requireTranslation(scope)
            let result = try await rpc(scope: scope, method: "translation.request_status", params: .object([
                "session_id": .string(request.sessionID.rawValue), "request_id": .string(request.requestID.rawValue),
            ]))
            return try await settledTranslation(result, request: request.requestID, session: request.sessionID, scope: scope)
        } catch { _ = note(error); return .unknown(request.requestID) }
    }
    func settledTranslation(_ result: WireValue, request: TranslationRequestID, session: SessionID, scope: ClientScope) async throws -> TranslationCommandResponse {
        switch try result.string("state") {
        case "unknown", "pending": return .unknown(request)
        case "succeeded":
            guard !result["record"].isNull else { throw RemoteClientError.invalidPayload }
            return .settled(request, record: try await completeTranslation(RemoteMapping.reading(result["record"], session: session), session: session, scope: scope), error: nil)
        case "failed": return .settled(request, record: nil, error: try RemoteMapping.safeTranslationError(result) ?? "Translation failed.")
        default: throw RemoteClientError.invalidPayload
        }
    }

    func completeTranslation(_ record: ReadingTranslation?, session: SessionID, scope: ClientScope) async throws -> ReadingTranslation? {
        guard var record, record.integrity == .descriptorPending else { return record }
        var text = ""
        var offset = 0
        for _ in 0..<64 {
            let response = await pageTranslationText(scope: scope, request: TranslationTextPageRequest(sessionID: session, recordID: record.id, offset: offset))
            guard case .page(let chunk, let next) = response else { throw RemoteClientError.expired }
            text += chunk
            guard text.utf16.count <= record.textLength, text.utf8.count <= 4 * 1024 * 1024 else { throw RemoteClientError.bufferLimit }
            if let next { offset = next; continue }
            guard text.utf16.count == record.textLength, RemoteWire.hash(Data(text.utf8)) == record.textSHA256 else { throw RemoteClientError.integrity }
            record.presentableText = text; record.integrity = .pagedVerified
            return record
        }
        throw RemoteClientError.bufferLimit
    }
}
