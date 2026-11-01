import XCTest
@testable import GianCore
@testable import Gian

final class ComposerRecoveryProjectionTests: XCTestCase {
    private func id<Kind>(_ raw: String, _ type: ScopedID<Kind>.Type) -> ScopedID<Kind> {
        guard let value = ScopedID<Kind>(rawValue: raw) else {
            XCTFail("invalid test id \(raw)")
            fatalError("invalid test id")
        }
        return value
    }

    private func negotiatedUncertainCreate() -> GianClientState {
        var state = GianClientState.signedOut()
        let commandID = id("command-create", CommandID.self)
        var intent = DurableSendIntent(
            draftID: state.composer.draft.id,
            stage: .create,
            creationID: commandID
        )
        intent.createRequest = SessionCreateRequest(
            commandID: commandID,
            catalogRevision: "catalog-1",
            workspaceID: id("workspace-1", WorkspaceID.self),
            agentID: id("agent-1", AgentID.self),
            taskID: nil,
            model: nil
        )
        state.composer.send = .uncertain(intent)
        state.capabilities = CapabilityProjection(
            grants: [],
            negotiatedFeatures: [.sessionDirectoryV1]
        )
        return state
    }

    func testUncertainCreateRetryRequiresFrozenRequestNegotiationAndReadiness() {
        let state = negotiatedUncertainCreate()

        XCTAssertTrue(StoreProjection.canRetryUncertainCreate(state, mutationsReady: true))
        XCTAssertFalse(StoreProjection.canRetryUncertainCreate(state, mutationsReady: false))

        var unnegotiated = state
        unnegotiated.capabilities = .empty
        XCTAssertFalse(StoreProjection.canRetryUncertainCreate(unnegotiated, mutationsReady: true))
    }

    func testUncertainCreateRetryRejectsMissingOrMismatchedFrozenInput() {
        let state = negotiatedUncertainCreate()

        var missingRequest = state
        var missingIntent = missingRequest.composer.send.intent!
        missingIntent.createRequest = nil
        missingRequest.composer.send = .uncertain(missingIntent)
        XCTAssertFalse(StoreProjection.canRetryUncertainCreate(missingRequest, mutationsReady: true))

        var mismatchedCommand = state
        var mismatchedIntent = mismatchedCommand.composer.send.intent!
        mismatchedIntent.creationID = id("command-other", CommandID.self)
        mismatchedCommand.composer.send = .uncertain(mismatchedIntent)
        XCTAssertFalse(StoreProjection.canRetryUncertainCreate(mismatchedCommand, mutationsReady: true))

        var changedDraft = state
        changedDraft.composer.draft.id = id("draft-other", DraftID.self)
        XCTAssertFalse(StoreProjection.canRetryUncertainCreate(changedDraft, mutationsReady: true))
    }

    func testUncertainSendWithFrozenRequestNeverOffersCreateRetry() {
        var state = negotiatedUncertainCreate()
        let commandID = id("command-send", CommandID.self)
        let sessionID = id("session-1", SessionID.self)
        var intent = DurableSendIntent(
            draftID: state.composer.draft.id,
            stage: .send,
            sendID: commandID,
            sessionID: sessionID
        )
        intent.sendRequest = SessionSendRequest(
            commandID: commandID,
            sessionID: sessionID,
            text: "Original user text",
            attachmentIDs: [],
            busy: nil,
            translation: nil
        )
        state.composer.send = .uncertain(intent)

        XCTAssertFalse(StoreProjection.canRetryUncertainCreate(state, mutationsReady: true))
    }

    func testTasklessFirstSendRequiresNegotiationAndActualReadiness() {
        let taskID = id("task-1", TaskID.self)

        XCTAssertFalse(StoreProjection.newChatRemoteReady(
            taskID: nil,
            directoryNegotiated: false,
            mutationsReady: true
        ))
        XCTAssertTrue(StoreProjection.newChatRemoteReady(
            taskID: nil,
            directoryNegotiated: true,
            mutationsReady: true
        ))
        XCTAssertFalse(StoreProjection.newChatRemoteReady(
            taskID: nil,
            directoryNegotiated: true,
            mutationsReady: false
        ))
        XCTAssertTrue(StoreProjection.newChatRemoteReady(
            taskID: taskID,
            directoryNegotiated: false,
            mutationsReady: true
        ))
    }
}
