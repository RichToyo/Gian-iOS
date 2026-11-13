import Foundation
import Testing
@testable import GianCore

/// Stop is the safety valve: it must not be held by the checks that gate edits.
@MainActor
struct StopTests {
    @Test func stopStaysAvailableWhileTheChatSyncs() async throws {
        let (store, _, clock) = makeHarness()
        _ = try await signIn(store, clock: clock)
        #expect((await store.dispatch(.selectConversation(PreviewFixtures.sessionID))).isApplied)
        // As while a running turn's chat is re-read: edits wait, Stop doesn't.
        store.state.conversation?.transcriptSync = .syncing
        #expect(!store.mutationsReady)
        #expect(store.stopReady)
        #expect((await store.dispatch(.stop)).isApplied)
        if case .succeeded = store.state.pendingStop {} else { Issue.record("Stop was not sent: \(store.state.pendingStop)") }
    }

    @Test func stopWaitsForAConnection() async throws {
        let (store, _, clock) = makeHarness()
        _ = try await signIn(store, clock: clock)
        #expect((await store.dispatch(.selectConversation(PreviewFixtures.sessionID))).isApplied)
        store.state.connection = .offline
        #expect(!store.stopReady)
        #expect(await store.dispatch(.stop) == .rejected(.mutationsDisabled))
    }
}
