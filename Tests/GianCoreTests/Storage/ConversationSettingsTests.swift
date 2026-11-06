import Foundation
import Testing
@testable import GianCore

/// Model, thinking, Fast and approval: decoded from the Host's record,
/// changed with `session.update` (mid-run, next turn), and chosen for a new
/// chat (create-time fields plus a post-create approval update).
@MainActor
struct ConversationSettingsTests {
    private func harness() async throws -> (GianClientStore, ControlledService) {
        let service = ControlledService()
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: InMemoryGianStorage())
        _ = try await signIn(store, clock: clock)
        return (store, service)
    }

    @Test func sessionRecordDecodesConversationSettings() throws {
        let wire = WireValue.object([
            "id": .string("00000000-0000-7000-8000-000000000071"), "revision": .string("r7"), "name": .string("Pier"),
            "task_id": .null, "workspace_id": .string("00000000-0000-7000-8000-000000000072"),
            "agent": .object(["id": .string("00000000-0000-7000-8000-000000000073"), "name": .string("Codex"), "proxy": .string("codex")]),
            "model": .string("gpt-6-sol"), "thinking": .string("xhigh"), "service_tier": .string("fast"),
            "approval_mode": .string("auto"), "status": .string("running"),
            "queue": .object(["revision": .string("q"), "entries": .array([])]),
            "updated_at": .string("2026-06-09T10:13:20Z"),
        ])
        let record = try RemoteMapping.session(wire, host: PreviewFixtures.hostID)
        #expect(record.model == "gpt-6-sol")
        #expect(record.thinking == "xhigh")
        #expect(record.serviceTier == "fast")
        #expect(record.approvalMode == "auto")

        var legacy = wire
        if case .object(var fields) = legacy {
            for key in ["model", "thinking", "service_tier", "approval_mode"] { fields[key] = nil }
            legacy = .object(fields)
        }
        let bare = try RemoteMapping.session(legacy, host: PreviewFixtures.hostID)
        #expect(bare.model == nil && bare.thinking == nil && bare.serviceTier == nil && bare.approvalMode == nil)
    }

    @Test func agentCatalogNamesThinkingFastAndApprovalOptions() throws {
        func select(_ id: String, _ choices: [(String, String)], defaultValue: WireValue = .null) -> WireValue {
            .object(["id": .string(id), "displayName": .string(id), "binding": .string("turn"), "control": .string("select"),
                "required": .bool(false), "defaultValue": defaultValue,
                "choices": .array(choices.map { .object(["value": .string($0.0), "displayName": .string($0.1)]) })])
        }
        var fast = select("service_tier", [])
        if case .object(var fields) = fast {
            fields["control"] = .string("boolean")
            fields["choices"] = nil
            fields["enabledWhen"] = .array([.object(["optionId": .string("model"), "oneOf": .array([.string("gpt-6-sol")])])])
            fast = .object(fields)
        }
        let wire = WireValue.object([
            "catalogRevision": .string("c1"),
            "configOptions": .array([
                select("model", [("gpt-6-sol", "Sol"), ("gpt-6-luna", "Luna")]),
                select("effort", [("low", "Light"), ("xhigh", "Extra High")]),
                fast,
                select("approval_mode", [("ask", "Ask for approval"), ("auto", "Approve for me")], defaultValue: .string("ask")),
            ]),
            "input": .array([]),
            "specialCatalogs": .object(["model": .string("model"), "thinking": .string("effort"),
                "fast": .string("service_tier"), "approvalMode": .string("approval_mode")]),
            "resolveSupported": .bool(true),
        ])
        let options = try RemoteMapping.agentOptions(wire)
        #expect(options.thinking == [AgentOptionChoice(value: "low", label: "Light"), AgentOptionChoice(value: "xhigh", label: "Extra High")])
        #expect(options.approval.map(\.value) == ["ask", "auto"])
        #expect(options.approvalDefault == "ask")
        #expect(options.fastAvailable(forModel: "gpt-6-sol"))
        #expect(!options.fastAvailable(forModel: "gpt-6-luna"))

        let claudeLike = WireValue.object(["configOptions": .array([]), "input": .array([]), "resolveSupported": .bool(false)])
        let none = try RemoteMapping.agentOptions(claudeLike)
        #expect(none.thinking.isEmpty && none.approval.isEmpty && !none.supportsFast)
    }

    @Test func updateStoresTheHostRecordSoTheNextUpdateUsesItsRevision() async throws {
        let (store, service) = try await harness()
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        let original = try #require(store.state.conversation?.session.revision)

        #expect((await store.dispatch(.setConversationThinking("high"))).isApplied)
        #expect(service.updateRequests.last?.sessionRevision == original)
        #expect(service.updateRequests.last?.change == .thinking("high"))
        let session = try #require(store.state.conversation?.session)
        #expect(session.thinking == "high")
        #expect(session.revision != original)

        #expect((await store.dispatch(.setConversationApprovalMode("auto"))).isApplied)
        #expect(service.updateRequests.last?.sessionRevision == session.revision)
        #expect(store.state.conversation?.session.approvalMode == "auto")
        #expect(!store.state.settingsUpdatePending)
    }

    @Test func rejectedUpdateKeepsTheRecordAndExplains() async throws {
        let (store, service) = try await harness()
        _ = await store.dispatch(.selectConversation(PreviewFixtures.sessionID))
        let before = try #require(store.state.conversation?.session)
        service.updateResponse = .rejected(message: "Revision mismatch")

        #expect(!(await store.dispatch(.setConversationFast(true))).isApplied)
        #expect(store.state.conversation?.session == before)
        #expect(store.state.settingsNotice != nil)
    }

    @Test func newChatSendsThinkingAndFastThenAppliesApproval() async throws {
        let (store, service) = try await harness()
        await prepareComposer(store)
        #expect((await store.dispatch(.loadAgentOptions(PreviewFixtures.agentID))).isApplied)
        // Fast is limited to Ada Swift in the preview catalog.
        _ = await store.dispatch(.selectModel("ada-swift"))
        _ = await store.dispatch(.selectThinking("high"))
        _ = await store.dispatch(.selectFast(true))
        _ = await store.dispatch(.selectApprovalMode("auto"))

        #expect((await store.dispatch(.send)).isApplied)
        let create = try #require(service.sessionCreateRequests.last)
        #expect(create.model == "ada-swift")
        #expect(create.thinking == "high")
        #expect(create.serviceTier == "fast")
        let approval = try #require(service.updateRequests.last)
        #expect(approval.change == .approvalMode("auto"))
        #expect(approval.sessionID.rawValue.hasPrefix("session-created"))
        #expect(approval.sessionRevision == "rev-new")
        #expect(service.base.sendCount == 1)
    }

    /// The post-create approval update can answer after a Host switch. Its
    /// record belongs to the previous Host and must not enter the new one,
    /// where every later commit would fail the scope check.
    @Test func lateApprovalUpdateAfterHostSwitchStaysWithItsHost() async throws {
        let (store, service) = try await harness()
        let lighthouse = HostSummary(id: PreviewFixtures.id("host-lighthouse", HostID.self), name: "Lighthouse",
                                     online: true, version: "0.6.9")
        service.extraHosts = [lighthouse]
        store.state.hosts.append(lighthouse)
        let harbor = try clientScope(store)
        await prepareComposer(store)
        _ = await store.dispatch(.selectApprovalMode("auto"))
        service.holdNextUpdate = true

        let send = Task { await store.dispatch(.send) }
        for _ in 0..<100 where service.update == nil { await Task.yield() }
        let request = try #require(service.updateRequests.last)
        #expect((await store.dispatch(.selectHost(lighthouse.id))).isApplied)
        service.update?.resume(returning: await service.base.updateSession(scope: harbor, request: request))
        #expect(await send.value == .rejected(.staleOperation))

        #expect(store.state.currentHostID == lighthouse.id)
        #expect(store.sessions.allSatisfy { $0.hostID == lighthouse.id })
        #expect(store.flushStorage().isApplied)
        #expect(!store.storageWritesBlocked)
        #expect(store.state.connection == .online)
        #expect(service.base.sendCount == 0)
    }

    @Test func fastIsDroppedForModelsWithoutIt() async throws {
        let (store, service) = try await harness()
        await prepareComposer(store)
        _ = await store.dispatch(.loadAgentOptions(PreviewFixtures.agentID))
        _ = await store.dispatch(.selectModel("ada-swift"))
        _ = await store.dispatch(.selectFast(true))
        _ = await store.dispatch(.selectModel("ada-large"))
        #expect(store.state.composer.selection.fast == nil)

        _ = await store.dispatch(.send)
        #expect(service.sessionCreateRequests.last?.serviceTier == nil)
    }
}
