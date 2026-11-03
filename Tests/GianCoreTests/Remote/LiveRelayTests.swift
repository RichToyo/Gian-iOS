import Foundation
import Testing
@testable import GianCore

@MainActor
struct LiveRelayTests {
    func connected() async throws -> (RemoteFixture, FixtureRelaySocket) {
        let fixture = RemoteFixture()
        try await fixture.connectAndClaim()
        let socket = FixtureRelaySocket(fixture)
        fixture.transport.socket = socket
        guard case .snapshot(let directory) = await fixture.service.refreshDirectory(scope: fixture.scope) else { throw RemoteClientError.invalidPayload }
        #expect(directory.authority == .legacyOpenDoingTasksOnly)
        #expect(directory.sessions.count == 1)
        #expect(directory.agents.count == 1)
        return (fixture, socket)
    }
    @Test func realEncryptedLoginPairSubscribeAndSend() async throws {
        let (fixture, socket) = try await connected()
        let cached = try #require(try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account))
        #expect(cached.hosts.count == 1)
        #expect(cached.hosts[0].validation == .cached)
        #expect(!cached.hosts[0].host.online)
        #expect(cached.identity.account.provider == .controller)
        let session = SessionID(rawValue: fixture.sessionID)!
        let page = await fixture.service.pageTranscript(scope: fixture.scope, sessionID: session, cursor: nil)
        #expect(!page.failed)
        #expect(socket.commands.contains("session.subscribe"))
        let command = CommandID(rawValue: fixture.service.newID())!
        let result = await fixture.service.sendMessage(scope: fixture.scope, request: SessionSendRequest(commandID: command, sessionID: session,
            text: "fixture", attachmentIDs: [], busy: .fail, translation: nil))
        guard case .succeeded(let success) = result else { Issue.record("Expected actual command.result, not ACK"); await fixture.service.disconnect(); return }
        #expect(success.deliveryID != nil)
        #expect(success.session?.id == session)
        #expect(await fixture.service.searchSessions(scope: fixture.scope, query: "older").supported == false)
        await fixture.service.disconnect()
    }
    @Test func lostAckIsUnknownAndCanonicalStatusPreventsDuplicateSend() async throws {
        let (fixture, socket) = try await connected()
        socket.loseSendResult = true
        let command = CommandID(rawValue: fixture.service.newID())!
        let request = SessionSendRequest(commandID: command, sessionID: SessionID(rawValue: fixture.sessionID)!, text: "fixture", attachmentIDs: [], busy: .fail, translation: nil)
        #expect(await fixture.service.sendMessage(scope: fixture.scope, request: request) == .unknownOutcome(command))
        let replacement = FixtureRelaySocket(fixture)
        replacement.ledger = socket.ledger
        fixture.transport.socket = replacement
        guard case .snapshot = await fixture.service.refreshDirectory(scope: fixture.scope) else { Issue.record("Expected fresh reconnect snapshot"); return }
        guard case .succeeded = await fixture.service.sendMessage(scope: fixture.scope, request: request) else { Issue.record("Expected ledger recovery"); return }
        #expect(socket.commands.filter { $0 == "session.send" }.count == 1)
        #expect(!replacement.commands.contains("session.send"))
        await fixture.service.disconnect()
    }
    @Test func capabilityDenialDoesNotSendAndTasklessCreationIsUnsupported() async throws {
        let (fixture, socket) = try await connected()
        socket.sendDenied = true
        _ = await fixture.service.refreshDirectory(scope: fixture.scope)
        let command = CommandID(rawValue: fixture.service.newID())!
        let result = await fixture.service.sendMessage(scope: fixture.scope, request: SessionSendRequest(commandID: command,
            sessionID: SessionID(rawValue: fixture.sessionID)!, text: "fixture", attachmentIDs: [], busy: nil, translation: nil))
        guard case .failed = result else { Issue.record("Denied capability must fail closed"); return }
        #expect(!socket.commands.contains("session.send"))
        let created = await fixture.service.createSession(scope: fixture.scope, request: SessionCreateRequest(commandID: command, catalogRevision: "catalog-r1",
            workspaceID: WorkspaceID(rawValue: fixture.workspaceID)!, agentID: AgentID(rawValue: fixture.agentID)!, taskID: nil, model: nil))
        guard case .failed = created else { Issue.record("Taskless create must be unsupported"); return }
        #expect(!socket.commands.contains("session.create"))
        await fixture.service.disconnect()
    }
    /// A session event drops the snapshot until the next directory read; a
    /// message sent meanwhile (a new chat's first one) still goes out.
    @Test func sendingRightAfterASessionEventIsNotRefused() async throws {
        let (fixture, socket) = try await connected()
        fixture.service.invalidateDirectoryRead()
        let command = CommandID(rawValue: fixture.service.newID())!
        let result = await fixture.service.sendMessage(scope: fixture.scope, request: SessionSendRequest(commandID: command,
            sessionID: SessionID(rawValue: fixture.sessionID)!, text: "fixture", attachmentIDs: [], busy: .fail, translation: nil))
        guard case .succeeded = result else { Issue.record("Expected the send to go out, got \(result)"); await fixture.service.disconnect(); return }
        #expect(socket.commands.contains("session.send"))
        await fixture.service.disconnect()
    }
    @Test func encryptedAttachmentRoundTripAndExpiredReference() async throws {
        let (fixture, socket) = try await connected()
        let bytes = Data("fixture upload".utf8)
        let local = AttachmentID(rawValue: fixture.service.newID())!
        let uploaded = await fixture.service.uploadAttachment(scope: fixture.scope, request: AttachmentUploadRequest(localID: local,
            sessionID: SessionID(rawValue: fixture.sessionID)!, filename: "fixture.txt", mime: "text/plain", sha256: RemoteWire.hash(bytes), bytes: bytes))
        guard case .uploaded = uploaded else { Issue.record("Expected verified upload result"); return }
        #expect(socket.upload == bytes)
        let request = AttachmentDownloadRequest(attachmentID: local, sha256: RemoteWire.hash(socket.fileBytes))
        #expect(await fixture.service.downloadAttachment(scope: fixture.scope, request: request) == .downloaded(sha256: request.sha256, bytes: socket.fileBytes))
        socket.expiredDownload = true
        #expect(await fixture.service.downloadAttachment(scope: fixture.scope, request: request) == .expired)
        await fixture.service.disconnect()
    }
    @Test func translationWaitsForSettlementAndDoesNotRepeatPaidRequest() async throws {
        let (fixture, socket) = try await connected()
        let request = TranslationRequest(requestID: TranslationRequestID(rawValue: fixture.service.newID())!, sessionID: SessionID(rawValue: fixture.sessionID)!,
            purpose: .send, text: "fixture", sourceID: nil)
        guard case .settled(_, let record, nil) = await fixture.service.requestTranslation(scope: fixture.scope, request: request) else { Issue.record("Expected settled translation"); return }
        #expect(record?.presentableText == "Translated fixture")
        socket.translationRecord = nil
        #expect(await fixture.service.requestTranslation(scope: fixture.scope, request: request) == .unknown(request.requestID))
        #expect(socket.commands.filter { $0 == "translation.request" }.count == 1)
        #expect(await fixture.service.pageTranslationText(scope: fixture.scope, request: TranslationTextPageRequest(sessionID: request.sessionID,
            recordID: TranslationRecordID(rawValue: "00000000-0000-7000-8000-000000000031")!, offset: 0)) == .notFound)
        await fixture.service.disconnect()
    }
    @Test func downloadIntegrityAndMailboxCancellationAreFailClosed() async throws {
        let bytes = Data("fixture".utf8)
        let hash = RemoteWire.hash(bytes)
        var buffer = try RemoteDownloadBuffer(metadata: .object(["size": .int(bytes.count), "sha256": .string(hash)]), expectedHash: hash)
        #expect(throws: RemoteClientError.self) { try buffer.append(.object(["transfer_sequence": .int(1), "offset": .int(0), "bytes": .string(RemoteWire.base64(bytes))])) }
        try buffer.append(.object(["transfer_sequence": .int(0), "offset": .int(0), "bytes": .string(RemoteWire.base64(bytes))]))
        #expect(throws: RemoteClientError.self) { try buffer.finish(.object(["size": .int(bytes.count), "sha256": .string(String(repeating: "0", count: 64))])) }
        let mailbox = RemoteMailbox()
        let task = Task { try await mailbox.next() }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled waiter must not succeed") } catch {}
    }
    @Test func signedButMismatchedHandshakeAndUnsupportedHelloCannotAuthorize() async throws {
        for mismatch in [true, false] {
            let fixture = RemoteFixture()
            try await fixture.connectAndClaim()
            let socket = FixtureRelaySocket(fixture)
            socket.tamperAcceptNonce = mismatch
            socket.helloMinor = mismatch ? 3 : 4
            fixture.transport.socket = socket
            guard case .failed = await fixture.service.refreshDirectory(scope: fixture.scope) else { Issue.record("Invalid negotiation must fail closed"); return }
            #expect(try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account)?.hosts.isEmpty == true)
            await fixture.service.disconnect()
        }
    }
    @Test func transportLeaseExpiryDoesNotInventGrantExpiry() async throws {
        let (fixture, _) = try await connected()
        fixture.clock.instant = fixture.clock.instant.addingTimeInterval(601)
        let cached = try #require(try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account))
        #expect(cached.hosts.count == 1)
        #expect(cached.hosts[0].validation == .cached)
        // No account deadline either: a paired Host grant has no local expiry.
        fixture.clock.instant = fixture.clock.instant.addingTimeInterval(30 * 86_400)
        #expect(try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account)?.hosts.count == 1)
        await fixture.service.disconnect()
    }
    @Test func onlyFreshHandshakeCanReturnOnlineEvidence() async throws {
        let (fixture, _) = try await connected()
        fixture.transport.socket = FixtureRelaySocket(fixture)
        let fresh = try await fixture.service.revalidateAuthorization(scope: fixture.scope)
        #expect(fresh.hosts.count == 1)
        #expect(fresh.hosts[0].validation == .online)
        let cached = try #require(try fixture.service.loadCachedAuthorization(server: fixture.server, account: fixture.account))
        #expect(cached.hosts[0].validation == .cached)
        await fixture.service.disconnect()
    }
    @Test func unconfirmedRevokePersistsLocalTombstone() async throws {
        let (fixture, _) = try await connected()
        do { try await fixture.service.revoke(scope: fixture.scope); Issue.record("Fixture server did not confirm revocation") } catch {}
        let replacement = LiveGianClientService(transport: fixture.transport, secrets: fixture.secrets, authorizationInvalidations: fixture.invalidations, clock: fixture.clock)
        let restored = try #require(try replacement.loadCachedAuthorization(server: fixture.server, account: fixture.account))
        #expect(restored.hosts.isEmpty)
    }
    @Test func transcriptReferencesUseFileProtocolRatherThanUploadHandles() async throws {
        let (fixture, socket) = try await connected()
        let fileID = "00000000-0000-7000-8000-000000000050"
        socket.pageItems = [.object(["kind": .string("user"), "id": .string("00000000-0000-7000-8000-000000000051"),
            "turn_id": .string("00000000-0000-7000-8000-000000000052"), "turn": .int(1), "ts": .int(fixture.milliseconds), "text": .string("fixture"),
            "attachments": .array([.object(["id": .string(fileID), "session_id": .string(fixture.sessionID), "name": .string("fixture.txt"), "mime": .string("text/plain"),
                "size": .int(socket.fileBytes.count), "revision": .string("file-r1"), "previewable": .bool(true), "downloadable": .bool(true), "expires_at": .string("2030-01-01T00:00:00Z")])])])]
        let page = await fixture.service.pageTranscript(scope: fixture.scope, sessionID: SessionID(rawValue: fixture.sessionID)!, cursor: nil)
        #expect(!page.failed)
        let id = AttachmentID(rawValue: fileID)!
        #expect(fixture.service.fileDescriptor(scope: fixture.scope, id: id)?.name == "fixture.txt")
        #expect(await fixture.service.downloadAttachment(scope: fixture.scope, request: AttachmentDownloadRequest(attachmentID: id, sha256: ""))
            == .downloaded(sha256: RemoteWire.hash(socket.fileBytes), bytes: socket.fileBytes))
        #expect(socket.downloadKinds == ["file"])
        #expect(await fixture.service.previewFile(scope: fixture.scope, handleID: fileID)
            == .downloaded(sha256: RemoteWire.hash(socket.fileBytes), bytes: socket.fileBytes))
        #expect(socket.commands.contains("file.preview"))
        await fixture.service.disconnect()
    }
    @Test func successfulCommandWithUnknownDeliveryIsStillUnknown() async throws {
        let (fixture, socket) = try await connected()
        socket.sendDeliveryState = "unknown"
        let command = CommandID(rawValue: fixture.service.newID())!
        #expect(await fixture.service.sendMessage(scope: fixture.scope, request: SessionSendRequest(commandID: command,
            sessionID: SessionID(rawValue: fixture.sessionID)!, text: "fixture", attachmentIDs: [], busy: nil, translation: nil)) == .unknownOutcome(command))
        #expect(await fixture.service.queryCommand(scope: fixture.scope, commandID: command) == .unknownOutcome(command))
        await fixture.service.disconnect()
    }
}
