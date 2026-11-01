import Foundation

@MainActor
protocol TranscriptFileProviding: AnyObject {
    func fileDescriptor(scope: ClientScope, id: AttachmentID) -> RemoteFileDescriptor?
}

extension LiveGianClientService: TranscriptFileProviding {}

struct VerifiedTranscriptDownload {
    let scope: ClientScope
    let descriptor: RemoteFileDescriptor
    let sha256: String
    let bytes: Data
}

extension GianClientStore {
    private func referencesFile(_ id: AttachmentID, session: SessionID, scope: ClientScope) -> Bool {
        guard (sessions + searchHits).contains(where: { $0.id == session && $0.authorized && !$0.archived }) else { return false }
        return memory.bundle(for: scope).transcripts[session]?.contains(where: { item in
            if case .user(_, _, let ids, _) = item.body { return ids.contains(id) }
            return false
        }) == true
    }

    /// A Host-issued file reference, never an upload handle or a Host-local path.
    /// Its DTO deliberately has no SHA; the download metadata supplies that.
    public func transcriptFileDescriptor(for id: AttachmentID) -> RemoteFileDescriptor? {
        expireAuthorizationIfNeeded()
        guard let scope = readyScope() else { return nil }
        let current = (service as? any TranscriptFileProviding)?.fileDescriptor(scope: scope, id: id)
        let retained = verifiedTranscriptDownloads[id].flatMap { $0.scope == scope ? $0.descriptor : nil }
        guard let descriptor = current ?? retained, descriptor.id == id,
              referencesFile(id, session: descriptor.sessionID, scope: scope) else { return nil }
        return descriptor
    }

    func transcriptFileData(for id: AttachmentID, scope: ClientScope) -> Data? {
        guard let receipt = verifiedTranscriptDownloads[id], receipt.scope == scope,
              receipt.descriptor.expiresAt > clock.now(),
              referencesFile(id, session: receipt.descriptor.sessionID, scope: scope),
              let descriptor = transcriptFileDescriptor(for: id), descriptor == receipt.descriptor,
              receipt.bytes.count == descriptor.byteCount, SHA256Hex.digest(receipt.bytes) == receipt.sha256 else { return nil }
        return receipt.bytes
    }

    func downloadTranscriptFile(_ id: AttachmentID) async -> GianDispatchResult {
        guard let scope = readyScope(), let descriptor = transcriptFileDescriptor(for: id) else { return reject(.notFound) }
        guard descriptor.expiresAt > clock.now() else { transcriptFileStates[id] = .expired; return .applied }
        if transcriptFileData(for: id, scope: scope) != nil { transcriptFileStates[id] = .cached; return .applied }
        guard mutationsAllowed() else { return reject(.mutationsDisabled) }
        guard descriptor.downloadable else { transcriptFileStates[id] = .unavailable; return .applied }
        if let code = requireCapability(.fileDownload) { return reject(code) }
        guard transcriptFileStates[id] != .downloading else { return reject(.operationInFlight) }
        guard transcriptFileStates.count < 256 || transcriptFileStates[id] != nil else { return reject(.mutationsDisabled) }
        transcriptDownloadSequence += 1
        let request = transcriptDownloadSequence
        transcriptDownloadRequests[id] = request
        transcriptFileStates[id] = .downloading
        let token = epoch
        // Empty expected hash is deliberate: the authenticated file-ref DTO has
        // none. Remote selects kind=file and verifies its AEAD metadata and bytes.
        let response = await service.downloadAttachment(scope: scope,
            request: AttachmentDownloadRequest(attachmentID: id, sha256: ""))
        guard transcriptDownloadRequests[id] == request else { return reject(.staleOperation) }
        transcriptDownloadRequests[id] = nil
        guard responseIsCurrent(token), readyScope() == scope,
              let current = (service as? any TranscriptFileProviding)?.fileDescriptor(scope: scope, id: id),
              current == descriptor, current.expiresAt > clock.now(),
              referencesFile(id, session: current.sessionID, scope: scope) else {
            transcriptFileStates[id] = nil
            return reject(.staleOperation)
        }
        switch response {
        case .downloaded(let sha, let bytes):
            guard bytes.count == descriptor.byteCount, bytes.count <= 32 * 1024 * 1024,
                  SHA256Hex.digest(bytes) == sha else {
                transcriptFileStates[id] = .hashMismatch
                return .applied
            }
            verifiedTranscriptDownloads[id] = VerifiedTranscriptDownload(scope: scope, descriptor: descriptor, sha256: sha, bytes: bytes)
            var total = verifiedTranscriptDownloads.values.reduce(0) { $0 + $1.bytes.count }
            for candidate in verifiedTranscriptDownloads.keys.sorted(by: { $0.rawValue < $1.rawValue }) where candidate != id {
                if total <= 32 * 1024 * 1024, verifiedTranscriptDownloads.count <= 128 { break }
                total -= verifiedTranscriptDownloads.removeValue(forKey: candidate)?.bytes.count ?? 0
                transcriptFileStates[candidate] = nil
            }
            transcriptFileStates[id] = .cached
        case .expired: transcriptFileStates[id] = .expired
        case .unavailable: transcriptFileStates[id] = .unavailable
        case .failed(let message): transcriptFileStates[id] = .failed(message)
        case .uploaded: transcriptFileStates[id] = .failed("The Host returned an invalid file download response.")
        }
        return .applied
    }

    func clearTranscriptFileCache() {
        verifiedTranscriptDownloads.removeAll()
        transcriptFileStates.removeAll()
        transcriptDownloadRequests.removeAll()
    }
}
