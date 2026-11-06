import Foundation

/// Local producer state, not metadata on live transcript/translation packets.
/// Separate streams may deliver old diagnostics after a fresh directory result.
struct AcceptedDirectory: Equatable {
    let scope: ClientScope
    let cursor: SyncCursor
    let catalogRevision: String

    func accepts(_ payload: DirectorySnapshotPayload, scope: ClientScope) -> Bool {
        self.scope == scope && payload.cursor.hostGeneration == cursor.hostGeneration
            && payload.cursor.revision == cursor.revision
            && payload.cursor.eventSequence <= cursor.eventSequence
            && payload.catalogRevision == catalogRevision
    }
}

@MainActor
protocol DirectoryReadinessReporting: AnyObject {
    var acceptedDirectory: AcceptedDirectory? { get }
}

/// Bumped when a negotiated directory hint retires in-flight directory reads.
/// Distinct from canonical replay and from snapshot invalidation.
@MainActor
protocol DirectoryMembershipEpoch: AnyObject {
    var directoryMembershipGeneration: Int { get }
}

enum SessionAccessResult: Equatable {
    case authorized, unavailable, retry
}

@MainActor
protocol SessionAccessRevalidating: AnyObject {
    func revalidateSessionAccess(scope: ClientScope, session: SessionID) async -> SessionAccessResult
}

extension LiveGianClientService: SessionAccessRevalidating {
    func revalidateSessionAccess(scope: ClientScope, session: SessionID) async -> SessionAccessResult {
        let captured = epoch
        let membership = directoryMembershipGeneration
        do {
            try requireCapability(.sessionRead, scope: scope)
            let response = try await rpc(scope: scope, method: "session.page", params: .object([
                "session_id": .string(session.rawValue), "turns": .int(1)
            ]))
            try checkEpoch(captured)
            guard membership == directoryMembershipGeneration, !Task.isCancelled,
                  try response.identifier("session_id") == session.rawValue else { return .retry }
            _ = try response.boolean("has_more")
            _ = try RemoteMapping.transcriptPage(response.array("items"))
            _ = try response.optionalString("cursor")
            if !response["translations"].isNull {
                try requireTranslation(scope)
                for record in try response.array("translations") {
                    guard try record.string("purpose") == "read" else { throw RemoteClientError.invalidPayload }
                    _ = try RemoteMapping.reading(record, session: session)
                }
            }
            return .authorized
        } catch {
            guard captured == epoch, membership == directoryMembershipGeneration, !Task.isCancelled else { return .retry }
            let failure = error as? RemoteClientError
            if failure == .deviceRevoked || failure == .notAuthorized {
                if let failure { diagnostic(.connectionClosed(failure), scope: scope) }
                return .retry
            }
            if failure == .capabilityDenied || failure == .server(code: "RESOURCE_NOT_FOUND", retryAfter: nil) { return .unavailable }
            return .retry
        }
    }
}

extension LiveGianClientService: DirectoryReadinessReporting, DirectoryMembershipEpoch {
    var acceptedDirectory: AcceptedDirectory? {
        guard snapshot != nil, let catalog, let cursor, let scope = relayScope,
              relay?.isOpen == true, !overflowed,
              let revision = try? catalog.string("catalog_revision") else { return nil }
        // `cursor` has already been mapped from NEXT to last-applied by Remote.
        return AcceptedDirectory(scope: scope, cursor: cursor, catalogRevision: revision)
    }
}
