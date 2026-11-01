import Foundation

/// Authenticated, opaque Host file reference. It contains no local path or URL.
public struct RemoteFileDescriptor: Sendable, Equatable {
    public let id: AttachmentID
    public let sessionID: SessionID
    public let name: String
    public let mime: String
    public let byteCount: Int
    public let revision: String
    public let previewable: Bool
    public let downloadable: Bool
    public let expiresAt: Date

    @MainActor
    init(_ wire: WireValue, session: SessionID) throws {
        id = try wire.scoped("id"); sessionID = try wire.scoped("session_id")
        guard sessionID == session else { throw RemoteClientError.integrity }
        name = try wire.string("name", maximum: 256); mime = try wire.string("mime", maximum: 256)
        byteCount = try wire.integer("size", range: 0...RemoteLimits.maxAttachmentBytes)
        revision = try wire.string("revision")
        previewable = try wire.boolean("previewable"); downloadable = try wire.boolean("downloadable")
        expiresAt = try RemoteMapping.date(wire.string("expires_at"))
    }
}

extension LiveGianClientService {
    public func fileDescriptor(scope: ClientScope, id: AttachmentID) -> RemoteFileDescriptor? {
        guard relayScope == scope else { return nil }
        return fileDescriptors[id]
    }
    func captureFiles(_ items: [WireValue], session: SessionID) throws {
        for item in items where (try? item.string("kind")) == "user" {
            for wire in try (item["attachments"].isNull ? [] : item.array("attachments", maximum: 32)) {
                let descriptor = try RemoteFileDescriptor(wire, session: session)
                guard fileDescriptors.count < 1024 || fileDescriptors[descriptor.id] != nil else { throw RemoteClientError.bufferLimit }
                fileDescriptors[descriptor.id] = descriptor
            }
        }
    }
}
