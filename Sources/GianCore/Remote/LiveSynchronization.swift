import Foundation

extension LiveGianClientService {
    public func refreshDirectory(scope: ClientScope) async -> DirectoryRefreshResponse {
        var fence: RemoteDirectoryReadFence?
        var pendingSnapshotID: String?
        defer { if let pendingSnapshotID { pendingReadSnapshots.remove(pendingSnapshotID) } }
        do {
            try await connect(scope: scope)
            let captured = epoch
            let read = beginDirectoryRead()
            fence = read
            var state = try await rpc(scope: scope, method: "state.refresh", params: .object([:]))
            if try state.string("type") == "state.snapshot.pending" {
                let id = try state.identifier("snapshot_id")
                pendingSnapshotID = id
                if let stagedSnapshot, try stagedSnapshot.identifier("snapshot_id") == id { state = stagedSnapshot }
                else {
                    let mailbox = RemoteMailbox(limit: 1)
                    mailboxes["snapshot:\(id)"] = mailbox
                    defer { if mailboxes["snapshot:\(id)"] === mailbox { mailboxes.removeValue(forKey: "snapshot:\(id)") } }
                    state = try await mailbox.next()
                }
            }
            try checkDirectoryRead(read)
            guard try state.string("type") == "state.snapshot", try state.identifier("host_generation") == relay?.generation else {
                throw RemoteClientError.invalidPayload
            }
            let catalog = try await rpc(scope: scope, method: "catalog.read", params: .object([:]))
            try checkDirectoryRead(read)
            let payload = try RemoteMapping.directory(snapshot: state, catalog: catalog, scope: scope, features: relay?.features ?? [])
            var vault = try requireVault(server: scope.server, account: scope.account)
            if var host = vault.hosts[scope.host.rawValue] {
                host.name = payload.host.name; host.version = payload.host.version; vault.hosts[host.id] = host
                try saveVault(vault, server: scope.server, account: scope.account, epoch: captured)
            }
            try checkDirectoryRead(read)
            self.snapshot = state; self.catalog = catalog; self.cursor = payload.cursor
            lastFailure = nil
            emit(.directory(payload), scope: scope)
            try checkDirectoryRead(read)
            return .snapshot(payload)
        } catch {
            if let fence, !directoryReadIsCurrent(fence) { return .unknownOutcome }
            let safe = note(error)
            if safe == .timeout || safe == .disconnected || safe == .cancelled { return .unknownOutcome }
            return .failed(safe.safeDescription)
        }
    }

    public func pageTranscript(scope: ClientScope, sessionID: SessionID, cursor: String?) async -> TranscriptPageResponse {
        do {
            try requireCapability(.sessionRead, scope: scope)
            let captured = epoch
            let membershipGeneration = directoryMembershipGeneration
            if subscribedSession != sessionID || cursor == nil {
                subscriptionReadGeneration += 1
                let read = subscriptionReadGeneration
                let subscribed = try await rpc(scope: scope, method: "session.subscribe", params: .object(["session_id": .string(sessionID.rawValue)]))
                guard try subscribed["session"].identifier("id") == sessionID.rawValue else { throw RemoteClientError.integrity }
                try checkEpoch(captured)
                guard membershipGeneration == directoryMembershipGeneration, read == subscriptionReadGeneration else { throw RemoteClientError.cancelled }
                subscribedSession = sessionID; desiredSession = sessionID
                _ = try subscribed.string("cursor")
                fileDescriptors.removeAll()
                if relay?.features.contains(.sessionDirectoryV1) == true {
                    let interactions = try subscribed.array("interactions").map(RemoteMapping.interaction)
                    guard interactions.allSatisfy({ $0.sessionID == sessionID }),
                          Set(interactions.map(\.id)).count == interactions.count else { throw RemoteClientError.invalidPayload }
                    emit(.sessionMetadata(try RemoteMapping.session(subscribed["session"], host: scope.host), interactions: interactions), scope: scope)
                }
                if !subscribed["translation"].isNull {
                    try requireTranslation(scope)
                    emit(.translation(sessionID: sessionID, update: .state(try RemoteMapping.translationState(subscribed["translation"]), authoritativeBaseline: true)), scope: scope)
                }
            }
            var params: [String: WireValue] = ["session_id": .string(sessionID.rawValue), "turns": .int(10)]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await rpc(scope: scope, method: "session.page", params: .object(params))
            try checkEpoch(captured)
            guard membershipGeneration == directoryMembershipGeneration, subscribedSession == sessionID else { throw RemoteClientError.cancelled }
            guard try result.identifier("session_id") == sessionID.rawValue else { throw RemoteClientError.integrity }
            try captureFiles(result.array("items"), session: sessionID)
            try applyPageTranslations(result, sessionID: sessionID, scope: scope)
            let items = try RemoteMapping.transcriptPage(result.array("items"))
            noteTranscriptTurns(items, session: sessionID)
            return TranscriptPageResponse(items: items,
                cursor: try result.optionalString("cursor"), hasOlder: try result.boolean("has_more"))
        } catch {
            let safe = note(error)
            if safe == .capabilityDenied || safe == .server(code: "RESOURCE_NOT_FOUND", retryAfter: nil) {
                emit(.sessionUnavailable(sessionID), scope: scope)
            }
            return TranscriptPageResponse(items: [], cursor: cursor, hasOlder: false, failed: true)
        }
    }
    public func searchSessions(scope: ClientScope, query: String) async -> SearchResponse {
        // This old, non-paginated API cannot truthfully represent incomplete
        // global search. The Store uses listDirectory for negotiated search.
        SearchResponse(supported: false, sessions: [])
    }

    func noteTranscriptTurns(_ items: [TranscriptItem], session: SessionID) {
        if let maximum = items.map(\.turn).max() {
            latestTranscriptTurns[session] = max(latestTranscriptTurns[session] ?? 0, maximum)
        }
    }

    func catchUpTranscript(scope: ClientScope, session: SessionID, epoch captured: Int) async throws {
        let previousTurn = latestTranscriptTurns[session]
        var before: String?
        var seenCursors: Set<String> = []
        var count = 0
        for _ in 0..<64 {
            let page = await pageTranscript(scope: scope, sessionID: session, cursor: before)
            try checkEpoch(captured)
            guard !page.failed else { throw RemoteClientError.disconnected }
            count += page.items.count
            guard count <= 4096 else { throw RemoteClientError.bufferLimit }
            for item in page.items { emit(.transcript(sessionID: session, item: item), scope: scope) }
            var reachedPrevious = false
            if let previousTurn, let earliest = page.items.map(\.turn).min() { reachedPrevious = earliest <= previousTurn }
            if previousTurn == nil || !page.hasOlder || reachedPrevious { return }
            guard let next = page.cursor, seenCursors.insert(next).inserted else { throw RemoteClientError.invalidPayload }
            before = next
        }
        throw RemoteClientError.bufferLimit
    }

    func applyPageTranslations(_ result: WireValue, sessionID: SessionID, scope: ClientScope) throws {
        guard !result["translations"].isNull else { return }
        try requireTranslation(scope)
        for value in try result.array("translations") {
            emit(.translation(sessionID: sessionID, update: .upsert(try RemoteMapping.reading(value, session: sessionID))), scope: scope)
        }
    }

    func receive(_ message: WireValue, scope: ClientScope) throws {
        let kind = try message.string("type")
        switch kind {
        case "command.accepted", "command.result":
            let id = try message.string("command_id")
            guard let waiter = commandWaiters[id], try message.identifier("attempt_id") == waiter.attempt else { return }
            if kind == "command.accepted" {
                // Receipt only; never resolve the command's terminal waiter.
                return
            }
            if waiter.method == "state.refresh", try message.boolean("ok"),
               (try? message["data"].string("type")) == "state.snapshot.pending" {
                guard pendingReadSnapshots.count < 64 else { throw RemoteClientError.bufferLimit }
                pendingReadSnapshots.insert(try message["data"].identifier("snapshot_id"))
            }
            try waiter.mailbox.push(message)
        case "state.snapshot": try acceptSnapshot(message, scope: scope)
        case "state.snapshot.part": try acceptSnapshotPart(message, scope: scope)
        case "directory.changed":
            guard relay?.features.contains(.sessionDirectoryV1) == true else { throw RemoteClientError.invalidPayload }
            try message.closed(["type", "version", "host_generation", "revision"])
            _ = try message.integer("version", range: 1...1)
            let generation: HostGenerationID = try message.scoped("host_generation")
            let revision = try message.string("revision")
            guard generation.rawValue == relay?.generation, !revision.isEmpty else { throw RemoteClientError.integrity }
            directoryMembershipGeneration += 1
            subscribedSession = nil
            emit(.directoryChanged(generation: generation, revision: revision), scope: scope)
        case "snapshot.required":
            let reason: SnapshotRequiredReason = try RemoteMapping.enumeration(message, "reason")
            invalidateDirectoryRead(); emit(.snapshotRequired(reason), scope: scope); diagnostic(.resyncRequired(reason), scope: scope)
        case "resume.ok": break
        case "state.patch":
            invalidateDirectoryRead()
            emit(.snapshotRequired(.revisionMismatch), scope: scope)
            diagnostic(.resyncRequired(.revisionMismatch), scope: scope)
        case "event": try receiveEvent(message, scope: scope)
        case "transcript.page":
            let session: SessionID = try message.scoped("session_id")
            guard session == subscribedSession else { throw RemoteClientError.integrity }
            try captureFiles(message.array("items"), session: session)
            let items = try RemoteMapping.transcriptPage(message.array("items"))
            noteTranscriptTurns(items, session: session)
            for item in items { emit(.transcript(sessionID: session, item: item), scope: scope) }
            try applyPageTranslations(message, sessionID: session, scope: scope)
        case "transfer.ack", "transfer.error", "transfer.cancel", "attachment.result", "download.metadata", "attachment.chunk", "download.complete":
            let id = try message.identifier("transfer_id")
            guard let transfer = transfers[id] else { return }
            if kind == "transfer.error" { transfer.mailbox.fail(RemoteWire.error(message)); return }
            if kind == "transfer.cancel" { transfer.mailbox.fail(.cancelled); return }
            try transfer.mailbox.push(message)
        case "error": throw RemoteWire.error(message)
        default: throw RemoteClientError.invalidPayload
        }
    }
    func acceptSnapshot(_ message: WireValue, scope: ClientScope) throws {
        guard try message.identifier("host_generation") == relay?.generation,
              try message["host"].identifier("id") == scope.host.rawValue else { throw RemoteClientError.integrity }
        let id = try message.identifier("snapshot_id")
        if !pendingReadSnapshots.contains(id) {
            invalidateDirectoryRead()
            emit(.snapshotRequired(.revisionMismatch), scope: scope)
            diagnostic(.resyncRequired(.revisionMismatch), scope: scope)
        }
        snapshot = nil; stagedSnapshot = message
        try mailboxes["snapshot:\(id)"]?.push(message)
    }
    func acceptSnapshotPart(_ message: WireValue, scope: ClientScope) throws {
        guard relay?.features.contains(.snapshotParts) == true else { throw RemoteClientError.versionMismatch }
        let id = try message.identifier("snapshot_id")
        let generation = try message.identifier("host_generation")
        let revision = try message.string("revision")
        let sequence = try message.integer("event_sequence")
        let size = try message.integer("payload_size", range: 1...RemoteWire.maxSnapshot)
        let total = try message.integer("part_total", range: 1...64)
        let index = try message.integer("part_index", range: 0...(total - 1))
        let hash = try message.string("payload_sha256"); try RemoteMapping.validateHash(hash)
        guard generation == relay?.generation else { throw RemoteClientError.integrity }
        if snapshotParts == nil {
            if !pendingReadSnapshots.contains(id) {
                invalidateDirectoryRead()
                emit(.snapshotRequired(.revisionMismatch), scope: scope)
                diagnostic(.resyncRequired(.revisionMismatch), scope: scope)
            }
            snapshotParts = RemoteSnapshotAssembly(id: id, generation: generation, revision: revision, sequence: sequence, total: total, size: size, hash: hash)
            let captured = epoch
            snapshotTimeout = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(20))
                    guard let self, self.epoch == captured, self.snapshotParts?.id == id else { return }
                    self.relay?.close(.timeout)
                } catch {}
            }
        }
        guard var assembly = snapshotParts, assembly.id == id, assembly.generation == generation, assembly.revision == revision,
              assembly.sequence == sequence, assembly.size == size, assembly.total == total, assembly.hash == hash else { throw RemoteClientError.integrity }
        let bytes = try RemoteWire.unbase64(message.string("bytes", maximum: RemoteWire.maxFrame), maximum: 256 * 1024)
        if let previous = assembly.parts[index] {
            guard previous == bytes else { throw RemoteClientError.integrity }
            return
        }
        assembly.parts[index] = bytes; assembly.bytes += bytes.count
        guard assembly.bytes <= size else { throw RemoteClientError.bufferLimit }
        snapshotParts = assembly
        guard assembly.parts.count == total else { return }
        var data = Data()
        for index in 0..<total { guard let part = assembly.parts[index] else { throw RemoteClientError.integrity }; data.append(part) }
        guard data.count == size, RemoteWire.hash(data) == hash else { throw RemoteClientError.integrity }
        let result = try WireValue.decode(data, maximum: RemoteWire.maxSnapshot)
        guard try result.identifier("snapshot_id") == id, try result.identifier("host_generation") == generation,
              try result.string("revision") == revision, try result.integer("event_sequence") == sequence else { throw RemoteClientError.integrity }
        snapshotParts = nil
        snapshotTimeout?.cancel(); snapshotTimeout = nil
        try acceptSnapshot(result, scope: scope)
    }
    func receiveEvent(_ message: WireValue, scope: ClientScope) throws {
        let generation: HostGenerationID = try message.scoped("host_generation")
        let sequence = try message.integer("event_sequence")
        let value = message["event"]
        let kind = try value.string("kind")
        let canonical = kind != "transcript.item" && kind != "translation.updated"
        guard generation.rawValue == relay?.generation else { throw RemoteClientError.integrity }
        if canonical {
            invalidateDirectoryRead()
            guard let current = cursor, current.hostGeneration == generation, sequence == current.eventSequence + 1 else {
                emit(.snapshotRequired(.gapEvicted), scope: scope)
                diagnostic(.resyncRequired(.gapEvicted), scope: scope)
                return
            }
        }
        switch kind {
        case "session.updated":
            emit(.canonical(sequence: sequence, generation: generation, body: .session(try RemoteMapping.session(value["session"], host: scope.host))), scope: scope)
        case "interaction.updated":
            emit(.canonical(sequence: sequence, generation: generation, body: .interaction(try RemoteMapping.interaction(value["interaction"]))), scope: scope)
        case "attention.updated":
            // One canonical event may contain many attention rows, which the baseline store API cannot represent atomically.
            snapshot = nil; emit(.snapshotRequired(.revisionMismatch), scope: scope)
        case "transcript.item":
            let session: SessionID = try value.scoped("session_id")
            try captureFiles([value["item"]], session: session)
            let item = try RemoteMapping.transcript(value["item"])
            noteTranscriptTurns([item], session: session)
            emit(.transcript(sessionID: session, item: item), scope: scope)
        case "translation.updated":
            try requireTranslation(scope)
            let session: SessionID = try value.scoped("session_id")
            if !value["state"].isNull { emit(.translation(sessionID: session, update: .state(try RemoteMapping.translationState(value["state"]), authoritativeBaseline: false)), scope: scope) }
            if !value["automatic"].isNull {
                let automatic = value["automatic"]
                emit(.translation(sessionID: session, update: .automatic(sourceID: try automatic.string("source_id"), pending: try automatic.boolean("pending"),
                    error: try RemoteMapping.safeTranslationError(automatic), revision: try value.integer("automatic_revision"), epoch: try value.string("automatic_epoch"))), scope: scope)
            }
            if !value["upsert"].isNull { emit(.translation(sessionID: session, update: .upsert(try RemoteMapping.reading(value["upsert"], session: session))), scope: scope) }
            if let request = try value.optionalString("request_id") { try mailboxes["translation:\(session.rawValue):\(request)"]?.push(value) }
        default: throw RemoteClientError.invalidPayload
        }
        if canonical { cursor?.eventSequence = sequence }
    }
}
