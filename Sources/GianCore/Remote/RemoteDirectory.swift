import Foundation

// Host contract a4a03f280869607ec93c835800075d0d0eb4005a;
// Host implementation 8664e4090f401c12d3549e92e82f1a4762317af4 (source only).

extension RemoteMapping {
    static func directoryPage(_ value: WireValue, scope: ClientScope, request: DirectoryPageRequest) throws -> DirectoryPagePayload {
        try value.closed(["version", "view", "as_of", "revision", "state", "entries", "next_cursor"])
        guard try value.integer("version", range: 1...1) == 1,
              try value.string("view") == request.view.rawValue else { throw RemoteClientError.invalidPayload }
        let asOf = Date(timeIntervalSince1970: Double(try value.integer("as_of")) / 1000)
        let revision = try value.string("revision")
        guard !revision.isEmpty else { throw RemoteClientError.invalidPayload }
        let state: DirectoryPageState
        switch try value.string("state") {
        case "complete": state = .complete
        case "incomplete": state = .incomplete
        case "cursor_invalid": state = .cursorInvalid
        default: throw RemoteClientError.invalidPayload
        }
        let next = try value.optionalString("next_cursor", maximum: 4096)
        let rows = try value.array("entries", maximum: min(64, request.limit))
        guard (state == .incomplete) == (next != nil), next.map({ !$0.isEmpty }) ?? true,
              state != .cursorInvalid || rows.isEmpty else { throw RemoteClientError.invalidPayload }
        let entries = try rows.map { try directoryEntry($0, host: scope.host, asOf: asOf) }
        guard Set(entries.map { $0.session.id }).count == entries.count,
              request.view != .tasks || entries.allSatisfy({ $0.task?.status == .open }) else { throw RemoteClientError.invalidPayload }
        return DirectoryPagePayload(view: request.view, asOf: asOf, revision: revision, state: state, entries: entries, nextCursor: next)
    }

    static func directoryEntry(_ value: WireValue, host: HostID, asOf: Date) throws -> DirectoryEntry {
        try value.closed(["id", "revision", "name", "workspace", "task", "agent", "status", "unread",
                          "waiting_for_user", "last_activity_at", "completed_at"])
        try value["workspace"].closed(["id", "name"])
        try value["agent"].closed(["id", "name", "proxy"])
        let workspace = WorkspaceRecord(id: try value["workspace"].scoped("id"), name: try value["workspace"].string("name", maximum: 256))
        let task: TaskRecord?
        if value["task"].isNull { task = nil }
        else {
            try value["task"].closed(["id", "name", "status"])
            let status: TaskStatus
            switch try value["task"].string("status") {
            case "open": status = .open
            case "done": status = .completed
            case "archived": status = .other
            default: throw RemoteClientError.invalidPayload
            }
            task = TaskRecord(id: try value["task"].scoped("id"), title: try value["task"].string("name", maximum: 256), status: status, updatedAt: asOf)
        }
        let activity: Date? = value["last_activity_at"].isNull ? nil : Date(timeIntervalSince1970: Double(try value.integer("last_activity_at")) / 1000)
        let status: SessionStatus = try enumeration(value, "status")
        let waiting = try value.boolean("waiting_for_user")
        let revision = try value.string("revision")
        let name = try value.optionalString("name", maximum: 256)
        guard !revision.isEmpty else { throw RemoteClientError.invalidPayload }
        // Membership already passed Host archive/authorization policy. A retained
        // completed_at is informational, including after a session is reopened.
        var session = SessionRecord(id: try value.scoped("id"), hostID: host,
            title: name ?? "Untitled", revision: revision,
            taskID: task?.id, workspaceID: workspace.id, agentID: try value["agent"].scoped("id"),
            agentName: try value["agent"].string("name", maximum: 256), pluginID: try value["agent"].string("proxy", maximum: 256),
            status: status, unread: try value.boolean("unread"), attention: waiting ? .interaction : (status == .running ? .running : nil),
            lastActivityAt: activity, activityIsMessageOrExecution: activity != nil, updatedAt: activity ?? .distantPast)
        session.completedAt = try value.optionalString("completed_at")
        return DirectoryEntry(session: session, workspace: workspace, task: task, searchName: name)
    }
}

extension LiveGianClientService {
    public func listDirectory(scope: ClientScope, request: DirectoryPageRequest) async -> DirectoryPageResponse {
        do {
            let connection = try requireConnection(scope)
            guard connection.features.contains(.sessionDirectoryV1) else { return .unsupported }
            try requireCapability(.sessionRead, scope: scope)
            let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...64).contains(request.limit), (request.view == .search) == (query != nil),
                  query.map({ !$0.isEmpty && $0.utf16.count <= 256 }) ?? true,
                  request.cursor.map({ !$0.isEmpty && $0.utf16.count <= 4096 }) ?? true else { throw RemoteClientError.invalidPayload }
            let captured = epoch
            let generation = directoryMembershipGeneration
            let canonicalInvalidation = directoryInvalidationGeneration
            directoryPageReads[request.view, default: 0] += 1
            let read = directoryPageReads[request.view]
            var params: [String: WireValue] = ["view": .string(request.view.rawValue), "limit": .int(request.limit)]
            if let query { params["query"] = .string(query) }
            if let cursor = request.cursor { params["cursor"] = .string(cursor) }
            let result = try await rpc(scope: scope, method: "directory.list", params: .object(params))
            try checkEpoch(captured)
            guard directoryMembershipGeneration == generation, directoryInvalidationGeneration == canonicalInvalidation,
                  directoryPageReads[request.view] == read else { throw RemoteClientError.cancelled }
            return .page(try RemoteMapping.directoryPage(result, scope: scope, request: request))
        } catch {
            let safe = note(error)
            return safe == .capabilityDenied ? .denied : .failed(safe.safeDescription)
        }
    }
}
