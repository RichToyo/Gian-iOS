import Foundation

@MainActor
enum RemoteMapping {
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
        return SessionRecord(id: id, hostID: host, title: try value.optionalString("name", maximum: 256) ?? "Untitled",
            revision: try value.string("revision"), taskID: task, workspaceID: try value.scoped("workspace_id"),
            agentID: try agent.scoped("id"), agentName: try agent.string("name", maximum: 256), pluginID: try agent.string("proxy", maximum: 256),
            status: try enumeration(value, "status"), unread: value["unread"].isNull ? false : try value.boolean("unread"),
            // RemoteSession has no actual last-message/execution timestamp. Do not reinterpret updated_at as activity.
            updatedAt: try date(value.string("updated_at")))
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
    static func validateHash(_ hash: String) throws {
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
