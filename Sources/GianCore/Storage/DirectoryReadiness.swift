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

extension LiveGianClientService: DirectoryReadinessReporting, DirectoryMembershipEpoch {
    var acceptedDirectory: AcceptedDirectory? {
        guard snapshot != nil, let catalog, let cursor, let scope = relayScope,
              relay?.isOpen == true, !overflowed,
              let revision = try? catalog.string("catalog_revision") else { return nil }
        // `cursor` has already been mapped from NEXT to last-applied by Remote.
        return AcceptedDirectory(scope: scope, cursor: cursor, catalogRevision: revision)
    }
}
