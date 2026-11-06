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
            self.snapshot = state; self.capabilities = state["capabilities"]; self.catalog = catalog; self.cursor = payload.cursor
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
            let fence = sessionFence(sessionID)
            if subscribedSession != sessionID || cursor == nil {
                let waiting = try await subscribe(scope: scope, sessionID: sessionID, epoch: captured, fence: fence)
                if waiting { requestSubscriptionRefresh(scope: scope) }
            }
            var params: [String: WireValue] = ["session_id": .string(sessionID.rawValue), "turns": .int(10)]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await rpc(scope: scope, method: "session.page", params: .object(params))
            try checkEpoch(captured)
            guard fence == sessionFence(sessionID), subscribedSession == sessionID else { throw RemoteClientError.cancelled }
            guard try result.identifier("session_id") == sessionID.rawValue else { throw RemoteClientError.integrity }
            let rawItems = try result.array("items")
            let items = try RemoteMapping.transcriptPage(rawItems)
            let next = try result.optionalString("cursor")
            let hasOlder = try result.boolean("has_more")
            try captureFiles(rawItems, session: sessionID)
            try applyPageTranslations(result, sessionID: sessionID, scope: scope)
            noteTranscriptTurns(items, session: sessionID)
            return TranscriptPageResponse(items: items, cursor: next, hasOlder: hasOlder)
        } catch {
            let safe = note(error)
            if safe == .capabilityDenied || safe == .server(code: "RESOURCE_NOT_FOUND", retryAfter: nil) {
                sessionBecameUnavailable(sessionID, scope: scope)
            }
            return TranscriptPageResponse(items: [], cursor: cursor, hasOlder: false, failed: true)
        }
    }

    /// Moves this device's Host subscription to `sessionID` and publishes its
    /// metadata, cards and translation state, unless something about the chat
    /// changed while the read was in flight (`fence`). Returns whether the Host
    /// says the chat waits for the user but listed no card yet: it marks the
    /// chat pending just before it registers the card.
    func subscribe(scope: ClientScope, sessionID: SessionID, epoch captured: Int, fence: Int) async throws -> Bool {
        subscriptionReadGeneration += 1
        let read = subscriptionReadGeneration
        subscribesInFlight += 1
        defer { subscribesInFlight -= 1 }
        let subscribed = try await rpc(scope: scope, method: "session.subscribe", params: .object(["session_id": .string(sessionID.rawValue)]))
        guard try subscribed["session"].identifier("id") == sessionID.rawValue else { throw RemoteClientError.integrity }
        try checkEpoch(captured)
        guard fence == sessionFence(sessionID), read == subscriptionReadGeneration else { throw RemoteClientError.cancelled }
        if subscribedSession != sessionID { subscribedCards.removeAll(); waitingRefreshRevision = nil }
        subscribedSession = sessionID; desiredSession = sessionID
        _ = try subscribed.string("cursor")
        fileDescriptors.removeAll()
        var waiting = false
        if relay?.features.contains(.sessionDirectoryV1) == true {
            let interactions = try subscribed.array("interactions").map(RemoteMapping.interaction)
            guard interactions.allSatisfy({ $0.sessionID == sessionID }),
                  Set(interactions.map(\.id)).count == interactions.count else { throw RemoteClientError.invalidPayload }
            let session = try RemoteMapping.session(subscribed["session"], host: scope.host)
            subscribedCards = Set(interactions.map(\.id))
            waiting = session.status == .pending && interactions.isEmpty
            emit(.sessionMetadata(session, interactions: interactions), scope: scope)
        }
        if !subscribed["translation"].isNull {
            try requireTranslation(scope)
            emit(.translation(sessionID: sessionID, update: .state(try RemoteMapping.translationState(subscribed["translation"]), authoritativeBaseline: true)), scope: scope)
        }
        return waiting
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
        let records = try result.array("translations").map { value in
            guard try value.string("purpose") == "read" else { throw RemoteClientError.invalidPayload }
            return try RemoteMapping.reading(value, session: sessionID)
        }
        for record in records { emit(.translation(sessionID: sessionID, update: .upsert(record)), scope: scope) }
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
            emit(.directoryChanged(generation: generation, revision: revision), scope: scope)
        case "snapshot.required":
            let reason: SnapshotRequiredReason = try RemoteMapping.enumeration(message, "reason")
            invalidateDirectoryRead(); emit(.snapshotRequired(reason), scope: scope); diagnostic(.resyncRequired(reason), scope: scope)
        case "resume.ok": break
        case "state.patch":
            try message.closed(["type", "host_generation", "event_sequence", "base_revision", "revision", "patch"])
            let generation: HostGenerationID = try message.scoped("host_generation")
            let sequence = try message.integer("event_sequence")
            let base = try message.string("base_revision")
            let revision = try message.string("revision")
            guard generation.rawValue == relay?.generation, let current = cursor,
                  current.hostGeneration == generation, sequence == current.eventSequence + 1,
                  !base.isEmpty, !revision.isEmpty, base == current.revision else {
                invalidateDirectoryRead(); emit(.snapshotRequired(.revisionMismatch), scope: scope)
                diagnostic(.resyncRequired(.revisionMismatch), scope: scope); return
            }
            guard case .object(let fields) = message["patch"] else { throw RemoteClientError.invalidPayload }
            if !Set(fields.keys).isSubset(of: ["sessions", "tasks", "interactions", "attention", "queues"]) {
                invalidateDirectoryRead(); emit(.snapshotRequired(.revisionMismatch), scope: scope)
                diagnostic(.resyncRequired(.revisionMismatch), scope: scope); return
            }
            let patch = try RemoteMapping.statePatch(message["patch"], host: scope.host)
            if !patch.removedSessions.isEmpty || !patch.removedTasks.isEmpty { directoryMembershipGeneration += 1 }
            // Removed ids don't say which chat they belonged to.
            if !patch.removedTasks.isEmpty || !patch.removedInteractions.isEmpty { advanceAllSessionFences() }
            advanceSessionFences(patch.removedSessions + patch.sessions.map(\.id) + patch.interactions.map(\.sessionID) + Array(patch.queues.keys))
            subscribedCards.subtract(patch.removedInteractions)
            subscribedCards.formUnion(patch.interactions.filter { $0.sessionID == subscribedSession }.map(\.id))
            invalidateInFlightDirectoryRead()
            cursor?.eventSequence = sequence; cursor?.revision = revision
            emit(.statePatch(sequence: sequence, generation: generation, baseRevision: base, revision: revision, patch: patch), scope: scope)
            // For a chat outside an open task this is how the Host says it
            // changed, including that it now waits for an answer.
            if let session = subscribedSession, patch.removedSessions.contains(session) { requestSubscriptionRefresh(scope: scope) }
        case "event": try receiveEvent(message, scope: scope)
        case "transcript.page":
            let session: SessionID = try message.scoped("session_id")
            guard session == subscribedSession else { throw RemoteClientError.integrity }
            let rawItems = try message.array("items")
            let items = try RemoteMapping.transcriptPage(rawItems)
            try captureFiles(rawItems, session: session)
            try applyPageTranslations(message, sessionID: session, scope: scope)
            noteTranscriptTurns(items, session: session)
            for item in items { emit(.transcript(sessionID: session, item: item), scope: scope) }
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
        try message.closed(["type", "host_generation", "event_sequence", "event"])
        let generation: HostGenerationID = try message.scoped("host_generation")
        let sequence = try message.integer("event_sequence")
        let value = message["event"]
        let kind = try value.string("kind")
        let canonical = kind != "transcript.item" && kind != "translation.updated"
        guard generation.rawValue == relay?.generation else { throw RemoteClientError.integrity }
        if canonical {
            invalidateInFlightDirectoryRead()
            guard let current = cursor, current.hostGeneration == generation, sequence == current.eventSequence + 1 else {
                invalidateDirectoryRead()
                emit(.snapshotRequired(.gapEvicted), scope: scope)
                diagnostic(.resyncRequired(.gapEvicted), scope: scope)
                return
            }
        }
        switch kind {
        case "session.updated":
            try value.closed(["kind", "session"])
            let session = try RemoteMapping.session(value["session"], host: scope.host)
            advanceSessionFences([session.id])
            emit(.canonical(sequence: sequence, generation: generation, body: .session(session)), scope: scope)
        case "interaction.updated":
            try value.closed(["kind", "interaction"])
            let interaction = try RemoteMapping.interaction(value["interaction"])
            advanceSessionFences([interaction.sessionID])
            if interaction.sessionID == subscribedSession { subscribedCards.insert(interaction.id) }
            emit(.canonical(sequence: sequence, generation: generation, body: .interaction(interaction)), scope: scope)
        case "attention.updated":
            try value.closed(["kind", "attention"])
            let values = try RemoteMapping.attention(value.array("attention"))
            emit(.canonical(sequence: sequence, generation: generation, body: .attentions(values)), scope: scope)
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
            if !value["upsert"].isNull {
                let purpose = try value["upsert"].string("purpose")
                guard purpose == "read" || purpose == "send" else { throw RemoteClientError.invalidPayload }
                if purpose == "read" {
                    emit(.translation(sessionID: session, update: .upsert(try RemoteMapping.reading(value["upsert"], session: session))), scope: scope)
                }
            }
            if let request = try value.optionalString("request_id") { try mailboxes["translation:\(session.rawValue):\(request)"]?.push(value) }
        default: throw RemoteClientError.invalidPayload
        }
        if canonical { cursor?.eventSequence = sequence }
    }
}
