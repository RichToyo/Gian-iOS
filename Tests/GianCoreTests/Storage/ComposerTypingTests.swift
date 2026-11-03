import Foundation
import Testing
@testable import GianCore

@MainActor
struct ComposerTypingTests {
    /// Regression: every keystroke runs `rememberDraft()`, which used to read
    /// `state` inside `state.drafts.removeAll { ... }` and trap with a runtime
    /// exclusivity violation as soon as a remembered draft existed.
    @Test func typingAfterSignInUpdatesTheRememberedDraft() async throws {
        let service = ControlledService()
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock, storage: InMemoryGianStorage())
        _ = try await signIn(store, clock: clock)
        #expect(store.state.composer.draft.hostID != nil)

        for text in ["a", "ab", "abc"] {
            let result = await store.dispatch(.editDraftText(text))
            #expect(result.isApplied)
        }

        let draftID = store.state.composer.draft.id
        #expect(store.state.drafts.filter { $0.id == draftID }.map(\.text) == ["abc"])
    }
}
