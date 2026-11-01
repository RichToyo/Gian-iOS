import Foundation

public enum CanonicalBody: Sendable, Equatable {
    case session(SessionRecord)
    case interaction(InteractionRecord)
    case attention(sessionID: SessionID, kind: AttentionKind?)
}

public enum TranslationInbound: Sendable, Equatable {
    case state(TranslationSessionState, authoritativeBaseline: Bool)
    case automatic(sourceID: String, pending: Bool, error: String?, revision: Int, epoch: String)
    case upsert(ReadingTranslation)
}

public enum InboundEvent: Sendable, Equatable {
    case directory(DirectorySnapshotPayload)
    case directoryChanged(generation: HostGenerationID, revision: String)
    case sessionMetadata(SessionRecord, interactions: [InteractionRecord])
    case sessionUnavailable(SessionID)
    case canonical(sequence: Int, generation: HostGenerationID, body: CanonicalBody)
    case transcript(sessionID: SessionID, item: TranscriptItem)
    case translation(sessionID: SessionID, update: TranslationInbound)
    case snapshotRequired(SnapshotRequiredReason)
    case commandStatus(CommandStatusResponse)
}

public struct InboundEnvelope: Sendable, Equatable {
    public var scope: ClientScope
    public var event: InboundEvent
    /// Ephemeral service connection generation, not a canonical event sequence.
    /// Production events must match the coordinator's current expected epoch.
    public var serviceEpoch: Int?

    public init(scope: ClientScope, event: InboundEvent) {
        self.scope = scope
        self.event = event
        self.serviceEpoch = nil
    }

    public init(scope: ClientScope, event: InboundEvent, serviceEpoch: Int?) {
        self.scope = scope
        self.event = event
        self.serviceEpoch = serviceEpoch
    }
}
