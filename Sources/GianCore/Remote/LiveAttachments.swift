import Foundation

struct RemoteDownloadBuffer {
    let size: Int
    let hash: String
    var bytes = Data()
    var sequence = 0
    init(metadata: WireValue, expectedHash: String?) throws {
        size = try metadata.integer("size", range: 0...RemoteLimits.maxAttachmentBytes)
        hash = try metadata.string("sha256"); try RemoteMapping.validateHash(hash)
        guard expectedHash == nil || hash == expectedHash else { throw RemoteClientError.integrity }
    }
    mutating func append(_ chunk: WireValue) throws {
        guard try chunk.integer("transfer_sequence") == sequence, try chunk.integer("offset") == bytes.count else { throw RemoteClientError.integrity }
        let data = try RemoteWire.unbase64(chunk.string("bytes", maximum: RemoteWire.maxFrame), maximum: 192 * 1024)
        guard !data.isEmpty, bytes.count + data.count <= size else { throw RemoteClientError.bufferLimit }
        bytes.append(data); sequence += 1
    }
    func finish(_ message: WireValue) throws -> Data {
        guard try message.integer("size") == size, bytes.count == size,
              try message.string("sha256") == hash, RemoteWire.hash(bytes) == hash else { throw RemoteClientError.integrity }
        return bytes
    }
}

extension LiveGianClientService {
    func cancelTransfer(id: String, scope: ClientScope) async {
        guard relayScope == scope, let remote = relay, remote.isOpen else { return }
        let cancellation = Task { @MainActor in
            try? await remote.send(.object(["type": .string("transfer.cancel"), "transfer_id": .string(id), "reason": .string("client_cancelled")]))
        }
        await cancellation.value
    }
    public func uploadAttachment(scope: ClientScope, request: AttachmentUploadRequest) async -> AttachmentTransferResponse {
        // The actual attachment.begin requires a session_id. No taskless/draft upload endpoint exists.
        guard let session = request.sessionID else { return .unavailable("The Host requires an existing conversation for uploads.") }
        let transferID = newID()
        let uploadID = newID()
        do {
            try requireCapability(.attachmentUpload, scope: scope)
            guard !request.bytes.isEmpty, request.bytes.count <= RemoteLimits.maxAttachmentBytes,
                  request.filename.utf16.count <= 256, !request.filename.isEmpty, request.mime.utf16.count <= 256, !request.mime.isEmpty,
                  !request.filename.contains("/"), !request.filename.contains("\\"), !request.filename.contains("\0"),
                  RemoteWire.hash(request.bytes) == request.sha256, transfers.count < 4 else { throw RemoteClientError.integrity }
            guard inflightTransferBytes + request.bytes.count <= 64 * 1024 * 1024 else { throw RemoteClientError.bufferLimit }
            inflightTransferBytes += request.bytes.count
            defer { inflightTransferBytes -= request.bytes.count }
            let remote = try requireConnection(scope)
            let mailbox = RemoteMailbox(limit: 8)
            guard transfers[transferID] == nil else { throw RemoteClientError.bufferLimit }
            transfers[transferID] = RemoteTransfer(mailbox: mailbox)
            defer { if transfers[transferID]?.mailbox === mailbox { transfers.removeValue(forKey: transferID) } }
            try await remote.send(.object(["type": .string("attachment.begin"), "transfer_id": .string(transferID), "upload_id": .string(uploadID),
                "session_id": .string(session.rawValue), "name": .string(request.filename), "mime": .string(request.mime),
                "size": .int(request.bytes.count), "sha256": .string(request.sha256)]))
            let first = try await mailbox.next()
            guard try first.string("type") == "transfer.ack", try first.integer("contiguous_offset") == 0,
                  (1...4).contains(try first.integer("window_chunks")) else { throw RemoteClientError.integrity }
            var offset = 0
            var sequence = 0
            while offset < request.bytes.count {
                try Task.checkCancellation()
                let end = min(offset + RemoteWire.chunkBytes, request.bytes.count)
                try await remote.send(.object(["type": .string("attachment.chunk"), "transfer_id": .string(transferID), "transfer_sequence": .int(sequence),
                    "offset": .int(offset), "bytes": .string(RemoteWire.base64(request.bytes.subdata(in: offset..<end)))]), content: true)
                // Stop-and-wait is within every negotiated 1...4 chunk window and bounds memory.
                let ack = try await mailbox.next()
                guard try ack.string("type") == "transfer.ack", try ack.integer("contiguous_offset") == end,
                      (1...4).contains(try ack.integer("window_chunks")) else { throw RemoteClientError.integrity }
                offset = end; sequence += 1
            }
            try await remote.send(.object(["type": .string("attachment.complete"), "transfer_id": .string(transferID), "upload_id": .string(uploadID)]))
            let result = try await mailbox.next()
            guard try result.string("type") == "attachment.result", try result.identifier("upload_id") == uploadID,
                  try result.integer("size") == request.bytes.count, try result.string("sha256") == request.sha256,
                  try result.string("name") == request.filename, try result.string("mime") == request.mime else { throw RemoteClientError.integrity }
            guard try RemoteMapping.date(result.string("expires_at")) > clock.now() else { throw RemoteClientError.expired }
            return .uploaded(remoteID: try result.scoped("attachment_id"), sha256: request.sha256)
        } catch {
            let safe = note(error)
            await cancelTransfer(id: transferID, scope: scope)
            if safe == .expired { return .expired }
            return .failed(safe.safeDescription)
        }
    }
    public func downloadAttachment(scope: ClientScope, request: AttachmentDownloadRequest) async -> AttachmentTransferResponse {
        if let descriptor = fileDescriptor(scope: scope, id: request.attachmentID) {
            guard descriptor.downloadable else { return .unavailable(RemoteClientError.capabilityDenied.safeDescription) }
            guard descriptor.expiresAt > clock.now() else { return .expired }
            // Transcript attachment IDs are remote_file_refs, not upload attachment handles.
            return await download(scope: scope, handle: request.attachmentID.rawValue,
                expectedHash: request.sha256.isEmpty ? nil : request.sha256, kind: "file")
        }
        return await download(scope: scope, handle: request.attachmentID.rawValue, expectedHash: request.sha256, kind: "attachment")
    }

    /// Host-issued file handles only. Never accepts or resolves a Host-local path.
    public func downloadFile(scope: ClientScope, handleID: String) async -> AttachmentTransferResponse {
        await download(scope: scope, handle: handleID, expectedHash: nil, kind: "file")
    }

    public func previewFile(scope: ClientScope, handleID: String) async -> AttachmentTransferResponse {
        do {
            try requireCapability(.fileRead, scope: scope)
            _ = try RemoteWire.id(handleID)
            let result = try await rpc(scope: scope, method: "file.preview", params: .object(["handle_id": .string(handleID)]))
            guard try result["file"].identifier("id") == handleID,
                  try result.integer("preview_max_bytes") == 1024 * 1024 else { throw RemoteClientError.integrity }
            let session: SessionID = try result["file"].scoped("session_id")
            let descriptor = try RemoteFileDescriptor(result["file"], session: session)
            guard descriptor.previewable, descriptor.byteCount <= 1024 * 1024 else { throw RemoteClientError.bufferLimit }
            guard descriptor.expiresAt > clock.now() else { throw RemoteClientError.expired }
            guard fileDescriptors.count < 1024 || fileDescriptors[descriptor.id] != nil else { throw RemoteClientError.bufferLimit }
            fileDescriptors[descriptor.id] = descriptor
            return await download(scope: scope, handle: handleID, expectedHash: nil, kind: "file",
                transfer: try result.identifier("transfer_id"), maximumBytes: 1024 * 1024)
        } catch {
            let safe = note(error)
            if safe == .expired { return .expired }
            return .failed(safe.safeDescription)
        }
    }

    private func download(scope: ClientScope, handle: String, expectedHash: String?, kind: String,
                          transfer: String? = nil, maximumBytes: Int = RemoteLimits.maxAttachmentBytes) async -> AttachmentTransferResponse {
        let transferID = transfer ?? newID()
        do {
            try requireCapability(kind == "file" ? .fileDownload : .attachmentRead, scope: scope)
            _ = try RemoteWire.id(handle)
            if let expectedHash { try RemoteMapping.validateHash(expectedHash) }
            guard transfers.count < 4 else { throw RemoteClientError.bufferLimit }
            let remote = try requireConnection(scope)
            let mailbox = RemoteMailbox(limit: 8)
            guard transfers[transferID] == nil else { throw RemoteClientError.bufferLimit }
            transfers[transferID] = RemoteTransfer(mailbox: mailbox)
            defer { if transfers[transferID]?.mailbox === mailbox { transfers.removeValue(forKey: transferID) } }
            try await remote.send(.object(["type": .string("download.request"), "transfer_id": .string(transferID),
                "kind": .string(kind), "handle_id": .string(handle)]))
            let metadata = try await mailbox.next()
            guard try metadata.string("type") == "download.metadata" else { throw RemoteClientError.invalidPayload }
            // Metadata is authenticated by the pinned Host's AEAD channel. Final bytes
            // must match that complete descriptor, never just a truncated prefix.
            var buffer = try RemoteDownloadBuffer(metadata: metadata, expectedHash: expectedHash)
            guard buffer.size <= maximumBytes else { throw RemoteClientError.bufferLimit }
            guard inflightTransferBytes + buffer.size <= 64 * 1024 * 1024 else { throw RemoteClientError.bufferLimit }
            inflightTransferBytes += buffer.size
            defer { inflightTransferBytes -= buffer.size }
            while true {
                let message = try await mailbox.next()
                let type = try message.string("type")
                if type == "download.complete" { return .downloaded(sha256: buffer.hash, bytes: try buffer.finish(message)) }
                guard type == "attachment.chunk" else { throw RemoteClientError.invalidPayload }
                try buffer.append(message)
                try await remote.send(.object(["type": .string("transfer.ack"), "transfer_id": .string(transferID),
                    "contiguous_offset": .int(buffer.bytes.count), "window_chunks": .int(4)]))
            }
        } catch {
            let safe = note(error)
            await cancelTransfer(id: transferID, scope: scope)
            if safe == .expired { return .expired }
            return .failed(safe.safeDescription)
        }
    }
}
