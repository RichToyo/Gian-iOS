import Foundation

@MainActor
enum RemoteMapping {
    static func attention(_ values: [WireValue]) throws -> [SessionID: AttentionKind] {
        var result: [SessionID: AttentionKind] = [:]
        for value in values {
            try value.closed(["session_id", "kind", "updated_at"])
            let id: SessionID = try value.scoped("session_id")
            _ = try date(value.string("updated_at"))
            guard result[id] == nil else { throw RemoteClientError.invalidPayload }
            result[id] = try enumeration(value, "kind")
        }
        return result
    }

    static func statePatch(_ value: WireValue, host: HostID) throws -> CanonicalStatePatch {
        try value.closed([], optional: ["sessions", "tasks", "interactions", "attention", "queues"])
        var result = CanonicalStatePatch()
        func changes(_ key: String) throws -> ([WireValue], [String])? {
            guard case .object(let fields) = value, let collection = fields[key] else { return nil }
            try collection.closed(["upsert", "remove_ids"])
            let updates = try collection.array("upsert")
            let removed = try collection.array("remove_ids").map { item -> String in
                guard case .string(let raw) = item else { throw RemoteClientError.invalidPayload }
                return try RemoteWire.id(raw)
            }
            guard Set(removed).count == removed.count else { throw RemoteClientError.invalidPayload }
            return (updates, removed)
        }
        if let (updates, removed) = try changes("sessions") {
            result.sessions = try updates.map { value in
                try value.closed(["id", "revision", "name", "task_id", "workspace_id", "agent", "status", "queue", "updated_at"],
                    optional: ["model", "thinking", "service_tier", "approval_mode", "context_tokens_used", "context_window_tokens", "context_usage_updated_at", "unread", "active_turn"])
                try value["agent"].closed(["id", "name", "proxy"])
                try value["queue"].closed(["revision", "entries"])
                _ = try value["queue"].string("revision", maximum: 256)
                for entry in try value["queue"].array("entries", maximum: 64) {
                    try entry.closed(["id", "session_id", "text", "created_at"], optional: ["items", "context_items", "composer_document", "delivery_id"])
                    _ = try entry.identifier("id")
                    guard try entry.identifier("session_id") == value.identifier("id") else { throw RemoteClientError.invalidPayload }
                    _ = try entry.string("text"); _ = try entry.string("created_at")
                    if case .object(let fields) = entry {
                        for key in ["items", "context_items", "composer_document", "delivery_id"] where fields[key]?.isNull == true {
                            throw RemoteClientError.invalidPayload
                        }
                    }
                    if !entry["items"].isNull {
                        for item in try entry.array("items", maximum: 32) {
                            switch try item.string("type") {
                            case "text": try item.closed(["type", "text"]); _ = try item.string("text")
                            case "compiled_text", "attachment": try item.closed(["type", "attachment_id"]); _ = try item.identifier("attachment_id")
                            default: throw RemoteClientError.invalidPayload
                            }
                        }
                    }
                    if !entry["context_items"].isNull {
                        for item in try entry.array("context_items", maximum: 32) {
                            switch try item.string("type") {
                            case "pasted_text": try item.closed(["type", "text"]); _ = try item.string("text")
                            case "file_ref": try item.closed(["type", "handle_id"]); _ = try item.identifier("handle_id")
                            default: throw RemoteClientError.invalidPayload
                            }
                        }
                    }
                    if !entry["composer_document"].isNull {
                        let document = entry["composer_document"]
                        try document.closed(["type", "nodes"])
                        guard try document.string("type") == "document" else { throw RemoteClientError.invalidPayload }
                        for node in try document.array("nodes") {
                            switch try node.string("type") {
                            case "text": try node.closed(["type", "text"]); _ = try node.string("text")
                            case "reference": try node.closed(["type", "handle_id"]); _ = try node.identifier("handle_id")
                            default: throw RemoteClientError.invalidPayload
                            }
                        }
                    }
                    if !entry["delivery_id"].isNull { _ = try entry.identifier("delivery_id") }
                }
                if case .object(let fields) = value, fields["active_turn"]?.isNull == true { throw RemoteClientError.invalidPayload }
                if !value["active_turn"].isNull {
                    try value["active_turn"].closed(["id", "turn_number"])
                    _ = try value["active_turn"].identifier("id")
                    _ = try value["active_turn"].integer("turn_number", range: 1...9_007_199_254_740_991)
                }
                for key in ["context_tokens_used", "context_window_tokens"] where !value[key].isNull { _ = try value.integer(key) }
                if !value["context_usage_updated_at"].isNull { _ = try value.string("context_usage_updated_at") }
                return try session(value, host: host)
            }
            result.removedSessions = try removed.map { guard let id = SessionID(rawValue: $0) else { throw RemoteClientError.invalidPayload }; return id }
            let ids = result.sessions.map(\.id)
            guard Set(ids).count == ids.count, Set(ids).isDisjoint(with: result.removedSessions) else { throw RemoteClientError.invalidPayload }
        }
        if let (updates, removed) = try changes("tasks") {
            result.tasks = try updates.map { task in
                try task.closed(["id", "name", "updated_at", "session_ids"])
                let ids = try task.array("session_ids").map { value -> String in
                    guard case .string(let raw) = value else { throw RemoteClientError.invalidPayload }
                    return try RemoteWire.id(raw)
                }
                guard Set(ids).count == ids.count else { throw RemoteClientError.invalidPayload }
                return TaskRecord(id: try task.scoped("id"), title: try task.string("name", maximum: 256),
                                  status: .open, updatedAt: try date(task.string("updated_at")))
            }
            result.removedTasks = try removed.map { guard let id = TaskID(rawValue: $0) else { throw RemoteClientError.invalidPayload }; return id }
            let ids = result.tasks.map(\.id)
            guard Set(ids).count == ids.count, Set(ids).isDisjoint(with: result.removedTasks) else { throw RemoteClientError.invalidPayload }
        }
        if let (updates, removed) = try changes("interactions") {
            result.interactions = try updates.map(interaction)
            result.removedInteractions = try removed.map { guard let id = InteractionID(rawValue: $0) else { throw RemoteClientError.invalidPayload }; return id }
            let ids = result.interactions.map(\.id)
            guard Set(ids).count == ids.count, Set(ids).isDisjoint(with: result.removedInteractions) else { throw RemoteClientError.invalidPayload }
        }
        if case .object(let fields) = value, fields["attention"] != nil { result.attention = try attention(value.array("attention")) }
        if case .object(let fields) = value, fields["queues"] != nil {
            for update in try value.array("queues") {
                try update.closed(["session_id", "queue_revision", "entries"])
                let session: SessionID = try update.scoped("session_id")
                guard result.queues[session] == nil, !result.removedSessions.contains(session) else { throw RemoteClientError.invalidPayload }
                result.queues[session] = try queue(.object(["revision": update["queue_revision"], "entries": update["entries"]]), session: session)
            }
        }
        return result
    }
    static func date(_ string: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: string) else { throw RemoteClientError.invalidPayload }
        return date
    }
    static func enumeration<T: RawRepresentable>(_ wire: WireValue, _ key: String, as: T.Type = T.self) throws -> T where T.RawValue == String {
        guard let value = T(rawValue: try wire.string(key)) else { throw RemoteClientError.invalidPayload }
        return value
    }
    static func session(_ value: WireValue, host: HostID) throws -> SessionRecord {
        let agent = value["agent"]
        let id: SessionID = try value.scoped("id")
        let task: TaskID? = value["task_id"].isNull ? nil : try value.scoped("task_id")
        var record = SessionRecord(id: id, hostID: host, title: try value.optionalString("name", maximum: 256) ?? "Untitled",
            revision: try value.string("revision"), taskID: task, workspaceID: try value.scoped("workspace_id"),
            agentID: try agent.scoped("id"), agentName: try agent.string("name", maximum: 256), pluginID: try agent.string("proxy", maximum: 256),
            status: try enumeration(value, "status"), unread: value["unread"].isNull ? false : try value.boolean("unread"),
            // RemoteSession has no actual last-message/execution timestamp. Do not reinterpret updated_at as activity.
            updatedAt: try date(value.string("updated_at")))
        record.model = try value.optionalString("model", maximum: 256)
        record.thinking = try value.optionalString("thinking", maximum: 256)
        record.serviceTier = try value.optionalString("service_tier", maximum: 256)
        record.approvalMode = try value.optionalString("approval_mode", maximum: 256)
        if !value["queue"].isNull { record.queue = try queue(value["queue"], session: id) }
        return record
    }

    static func queue(_ value: WireValue, session: SessionID) throws -> SessionQueue {
        try value.closed(["revision", "entries"])
        let revision = try value.string("revision", maximum: 256)
        let entries = try value.array("entries", maximum: 64).map { entry in
            try entry.closed(["id", "session_id", "text", "created_at"], optional: ["items", "context_items", "composer_document", "delivery_id"])
            let id = try entry.identifier("id")
            let entrySession: SessionID = try entry.scoped("session_id")
            guard entrySession == session else { throw RemoteClientError.invalidPayload }
            let text = try entry.string("text")
            _ = try date(entry.string("created_at"))
            if case .object(let fields) = entry {
                for key in ["items", "context_items", "composer_document", "delivery_id"] where fields[key]?.isNull == true {
                    throw RemoteClientError.invalidPayload
                }
            }
            let items = entry["items"].isNull ? [] : try entry.array("items", maximum: 32)
            let attachments = try items.filter { item in
                let type = try item.string("type")
                switch type {
                case "text": try item.closed(["type", "text"]); _ = try item.string("text")
                case "attachment", "compiled_text": try item.closed(["type", "attachment_id"]); _ = try item.identifier("attachment_id")
                default: throw RemoteClientError.invalidPayload
                }
                return type == "attachment" || type == "compiled_text"
            }.count
            if !entry["context_items"].isNull {
                for item in try entry.array("context_items", maximum: 32) {
                    switch try item.string("type") {
                    case "pasted_text": try item.closed(["type", "text"]); _ = try item.string("text")
                    case "file_ref": try item.closed(["type", "handle_id"]); _ = try item.identifier("handle_id")
                    default: throw RemoteClientError.invalidPayload
                    }
                }
            }
            if !entry["composer_document"].isNull {
                let document = entry["composer_document"]
                try document.closed(["type", "nodes"])
                guard try document.string("type") == "document" else { throw RemoteClientError.invalidPayload }
                for node in try document.array("nodes") {
                    switch try node.string("type") {
                    case "text": try node.closed(["type", "text"]); _ = try node.string("text")
                    case "reference": try node.closed(["type", "handle_id"]); _ = try node.identifier("handle_id")
                    default: throw RemoteClientError.invalidPayload
                    }
                }
            }
            if !entry["delivery_id"].isNull { _ = try entry.identifier("delivery_id") }
            return QueuedMessage(id: id, text: text, attachmentCount: attachments)
        }
        guard Set(entries.map(\.id)).count == entries.count else { throw RemoteClientError.invalidPayload }
        return SessionQueue(revision: revision, entries: entries)
    }

    /// `catalog.agent`: `specialCatalogs` names the option ids for thinking,
    /// fast and approval; each option's string choices become menu entries.
    /// Fast's `enabledWhen` on the model option limits it to those models.
    static func agentOptions(_ value: WireValue) throws -> AgentConversationOptions {
        let options = try value.array("configOptions", maximum: 128)
        func option(_ id: String?) throws -> WireValue? {
            guard let id else { return nil }
            return try options.first { try $0.string("id", maximum: 256) == id }
        }
        func choices(_ option: WireValue?) throws -> [AgentOptionChoice] {
            guard let option, !option["choices"].isNull else { return [] }
            return try option.array("choices").compactMap { choice in
                guard case .string(let raw) = choice["value"], !raw.isEmpty, raw.utf16.count <= 256 else { return nil }
                return AgentOptionChoice(value: raw, label: try choice.string("displayName", maximum: 256))
            }
        }
        let special = value["specialCatalogs"]
        let modelOptionID = try special.optionalString("model", maximum: 256)
        let fastOption = try option(special.optionalString("fast", maximum: 256))
        var fastModels: Set<String>?
        if let fastOption, !fastOption["enabledWhen"].isNull, let modelOptionID {
            for condition in try fastOption.array("enabledWhen", maximum: 128) where try condition.string("optionId", maximum: 256) == modelOptionID {
                let models = try condition.array("oneOf").compactMap { value -> String? in
                    if case .string(let model) = value { return model }
                    return nil
                }
                fastModels = (fastModels ?? []).union(models)
            }
        }
        let approvalOption = try option(special.optionalString("approvalMode", maximum: 256))
        var approvalDefault: String?
        if let approvalOption, case .string(let value) = approvalOption["defaultValue"] { approvalDefault = value }
        return AgentConversationOptions(
            catalogRevision: try value.optionalString("catalogRevision", maximum: 256),
            thinking: try choices(option(special.optionalString("thinking", maximum: 256))),
            approval: try choices(approvalOption),
            approvalDefault: approvalDefault,
            supportsFast: fastOption != nil,
            fastModels: fastModels
        )
    }
    static func interaction(_ value: WireValue) throws -> InteractionRecord {
        let presentation = value["presentation"]
        let actions = try presentation.array("actions", maximum: 16).map { action in
            InteractionAction(id: try action.scoped("id"), label: try action.string("label", maximum: 256), tone: try enumeration(action, "tone"))
        }
        let inputs = try (presentation["inputs"].isNull ? [] : presentation.array("inputs", maximum: 16)).map { input in
            var mapped = InteractionInput(id: try input.identifier("id"), label: try input.string("label", maximum: 256), type: try enumeration(input, "type"))
            if !input["options"].isNull {
                mapped.options = try input.array("options", maximum: 32).map { option in
                    InteractionInputOption(value: try option.string("value"), label: try option.string("label", maximum: 256),
                        description: try option.optionalString("description"))
                }
                let values = mapped.options?.map(\.value) ?? []
                guard Set(values).count == values.count else { throw RemoteClientError.invalidPayload }
            }
            return mapped
        }
        return InteractionRecord(id: try value.scoped("id"), revision: try value.string("revision"), sessionID: try value.scoped("session_id"),
            turnID: try value.scoped("turn_id"), kind: try enumeration(value, "kind"), title: try presentation.string("title", maximum: 256),
            detail: try presentation.string("description"), risk: try enumeration(presentation, "risk"), actions: actions, inputs: inputs)
    }
    static func reading(_ value: WireValue, session: SessionID) throws -> ReadingTranslation {
        guard try value.identifier("session_id") == session.rawValue else { throw RemoteClientError.integrity }
        let length = try value.integer("text_length", range: 0...1_000_000)
        let hash = try value.string("text_sha256")
        let sourceHash = try value.string("source_sha256")
        try validateHash(hash); try validateHash(sourceHash)
        let inline = try value.optionalString("text")
        var integrity: TranslationIntegrityState = .descriptorPending
        var presentable: String?
        if let inline {
            if inline.utf16.count != length { integrity = .lengthMismatch }
            else if RemoteWire.hash(Data(inline.utf8)) != hash { integrity = .hashMismatch }
            else { integrity = .inlineVerified; presentable = inline }
        }
        return ReadingTranslation(id: try value.scoped("id"), sourceID: try value.optionalString("source_id"),
            targetLanguage: try value.string("target_language", maximum: 256), presentableText: presentable, textLength: length,
            textSHA256: hash, sourceSHA256: sourceHash, integrity: integrity)
    }
    nonisolated static func validateHash(_ hash: String) throws {
        guard hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw RemoteClientError.invalidPayload }
    }
    static func sentTranslation(_ value: WireValue) throws -> SentTranslation {
        let length = try value.integer("text_length", range: 0...1_000_000)
        let hash = try value.string("text_sha256"); try validateHash(hash)
        let text = try value.optionalString("text")
        let integrity: TranslationIntegrityState = text == nil ? .descriptorPending :
            (text!.utf16.count != length ? .lengthMismatch : (RemoteWire.hash(Data(text!.utf8)) != hash ? .hashMismatch : .inlineVerified))
        return SentTranslation(id: try value.scoped("id"), presentableText: integrity == .inlineVerified ? text : nil,
            textLength: length, textSHA256: hash, targetLanguage: try value.string("target_language", maximum: 256), integrity: integrity)
    }
    static func translationState(_ value: WireValue) throws -> TranslationSessionState {
        var automatic: [String: AutomaticProgress] = [:]
        for progress in try value.array("automatic") {
            let source = try progress.string("source_id")
            guard automatic[source] == nil else { throw RemoteClientError.invalidPayload }
            automatic[source] = AutomaticProgress(pending: try progress.boolean("pending"), error: try safeTranslationError(progress))
        }
        return TranslationSessionState(supported: true, enabled: try value.boolean("enabled"), configured: try value.boolean("configured"),
            sendingLanguage: try value.string("sending_language", maximum: 256), readingLanguage: try value.string("reading_language", maximum: 256),
            revision: try value.integer("revision"), configRevision: try value.integer("config_revision"),
            automaticRevision: try value.integer("automatic_revision"), automaticEpoch: try value.string("automatic_epoch"), automatic: automatic)
    }
    static func safeTranslationError(_ value: WireValue) throws -> String? {
        // Even display DTOs are untrusted; don't copy arbitrary Host errors into persistent UI state.
        try value.optionalString("error") == nil ? nil : "The Host could not complete this translation."
    }
    static func transcript(_ value: WireValue) throws -> TranscriptItem {
        let body: TranscriptBody
        switch try value.string("kind") {
        case "user":
            let attachments: [AttachmentID] = try (value["attachments"].isNull ? [] : value.array("attachments", maximum: 32)).map { try $0.scoped("id") }
            body = .user(text: try value.string("text"), deliveryID: try value.optionalString("delivery_id"), attachmentIDs: attachments,
                translation: value["translation"].isNull ? nil : try sentTranslation(value["translation"]))
        case "assistant": body = .assistant(text: try value.string("text"), delta: try value.boolean("delta"))
        case "command":
            let exit: Int? = value["exit_code"].isNull ? nil : try value.integer("exit_code", range: -Int.max...Int.max)
            body = .command(status: try enumeration(value, "status"), exitCode: exit)
        case "file-change": body = .fileChange(fileCount: try value.integer("file_count"))
        case "file-read": body = .fileRead
        case "file-search": body = .fileSearch(kind: try enumeration(value, "search_kind"), matchCount: value["match_count"].isNull ? nil : try value.integer("match_count"))
        case "web-search": body = .webSearch(resultCount: value["result_count"].isNull ? nil : try value.integer("result_count"))
        case "tool": body = .tool(name: try value.string("name", maximum: 256), status: try enumeration(value, "status"))
        case "agent": body = .agent(status: try enumeration(value, "status"), agentType: try value.optionalString("agent_type"),
            model: try value.optionalString("model"), background: value["background"].isNull ? false : try value.boolean("background"))
        case "notice": body = .notice(severity: try enumeration(value, "severity"), code: try value.string("code", maximum: 256))
        case "classifier-denied": body = .classifierDenied(consecutive: try value.integer("consecutive"), total: try value.integer("total"))
        case "circuit-breaker": body = .circuitBreaker(trigger: try enumeration(value, "trigger"), consecutive: try value.integer("consecutive"), total: try value.integer("total"))
        case "turn-end": body = .turnEnd(outcome: try enumeration(value, "outcome"))
        case "error": body = .error
        default: throw RemoteClientError.invalidPayload
        }
        return TranscriptItem(id: try value.scoped("id"), turnID: try value.scoped("turn_id"), turn: try value.integer("turn"),
            timestamp: Date(timeIntervalSince1970: Double(try value.integer("ts")) / 1000), body: body)
    }

    static func transcriptPage(_ values: [WireValue]) throws -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        var indices: [TranscriptItemID: Int] = [:]
        for value in values {
            var item = try transcript(value)
            if case .assistant(let text, let delta) = item.body {
                var complete = text
                if delta, let index = indices[item.id], case .assistant(let previous, _) = items[index].body {
                    complete = previous + text
                    item.timestamp = min(items[index].timestamp, item.timestamp)
                }
                guard complete.utf8.count <= RemoteWire.maxSnapshot else { throw RemoteClientError.bufferLimit }
                // A page is an authoritative replay baseline, not another live delta.
                item.body = .assistant(text: complete, delta: false)
            }
            if let index = indices[item.id] { items[index] = item }
            else { indices[item.id] = items.count; items.append(item) }
        }
        return items
    }

    static func directory(snapshot: WireValue, catalog: WireValue, scope: ClientScope, features: [KnownWireFeature]) throws -> DirectorySnapshotPayload {
        guard try snapshot.string("type") == "state.snapshot", try snapshot["host"].identifier("id") == scope.host.rawValue,
              try snapshot.string("catalog_revision") == catalog.string("catalog_revision"), try snapshot["host"].boolean("online") else {
            throw RemoteClientError.invalidPayload
        }
        let host = HostSummary(id: scope.host, name: try snapshot["host"].string("name", maximum: 256), online: true, version: try snapshot["host"].string("version"))
        let tasks = try snapshot.array("tasks").map { value in
            TaskRecord(id: try value.scoped("id"), title: try value.string("name", maximum: 256), status: .open, updatedAt: try date(value.string("updated_at")))
        }
        var sessions = try snapshot.array("sessions").map { try session($0, host: scope.host) }
        for attention in try snapshot.array("attention") {
            let id: SessionID = try attention.scoped("session_id")
            if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index].attention = try enumeration(attention, "kind") }
        }
        let agents = try catalog.array("agents").filter { try $0.string("readiness") == "ready" }.map { value in
            var agent = AgentRecord(id: try value.scoped("id"), name: try value.string("name", maximum: 256), pluginID: try value.string("proxy", maximum: 256))
            agent.defaultModel = try value["defaults"].optionalString("model", maximum: 256)
            if !value["models"].isNull {
                agent.models = try value.array("models").map { model in
                    let thinking = try model.array("supported_thinking", maximum: 32).map { value -> String in
                        guard case .string(let name) = value, !name.isEmpty, name.utf16.count <= 256 else {
                            throw RemoteClientError.invalidPayload
                        }
                        return name
                    }
                    return AgentModelRecord(id: try model.string("id", maximum: 256), label: try model.string("label", maximum: 256),
                        isDefault: try model.boolean("is_default"), supportedThinking: thinking)
                }
                let ids = agent.models?.map(\.id) ?? []
                guard Set(ids).count == ids.count else { throw RemoteClientError.invalidPayload }
            }
            return agent
        }
        let workspaces = try snapshot.array("workspaces").map { WorkspaceRecord(id: try $0.scoped("id"), name: try $0.string("name", maximum: 256)) }
        let capabilities = try BusinessCapability.allCases.map { capability in
            CapabilityGrant(capability: capability, state: snapshot["capabilities"][capability.rawValue].isNull ? .unsupported : try enumeration(snapshot["capabilities"][capability.rawValue], "state"))
        }
        guard Set(sessions.map(\.id)).count == sessions.count, Set(tasks.map(\.id)).count == tasks.count,
              Set(workspaces.map(\.id)).count == workspaces.count, Set(agents.map(\.id)).count == agents.count else { throw RemoteClientError.invalidPayload }
        return DirectorySnapshotPayload(authority: .legacyOpenDoingTasksOnly, host: host, tasks: tasks, sessions: sessions,
            interactions: try snapshot.array("interactions").map(interaction), workspaces: workspaces, agents: agents, capabilities: capabilities,
            negotiatedFeatures: features, cursor: SyncCursor(hostGeneration: try snapshot.scoped("host_generation"),
                // Wire snapshots carry the NEXT canonical sequence. Store cursors carry the LAST applied one.
                eventSequence: try snapshot.integer("event_sequence") - 1, revision: try snapshot.string("revision")), catalogRevision: try catalog.string("catalog_revision"))
    }
}
