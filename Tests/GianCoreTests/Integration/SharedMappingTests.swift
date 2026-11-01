import Foundation
import Testing
@testable import GianCore

@MainActor
struct SharedMappingTests {
    @Test func hostChoiceValuesAndDescriptionsArePreserved() throws {
        let inputID = "00000000-0000-7000-8000-000000000071"
        let wire = WireValue.object([
            "id": .string("00000000-0000-7000-8000-000000000072"), "revision": .string("r1"),
            "session_id": .string("00000000-0000-7000-8000-000000000073"),
            "turn_id": .string("00000000-0000-7000-8000-000000000074"), "kind": .string("question"),
            "presentation": .object([
                "title": .string("Choose"), "description": .string("Fictional question"), "risk": .string("low"),
                "actions": .array([]), "inputs": .array([.object([
                    "id": .string(inputID), "label": .string("Mode"), "type": .string("single_select"),
                    "options": .array([.object(["value": .string("exact-wire-value"), "label": .string("Readable label"),
                        "description": .string("Host supplied detail")])]),
                ])]),
            ]),
        ])
        let record = try RemoteMapping.interaction(wire)
        #expect(record.inputs[0].options == [InteractionInputOption(value: "exact-wire-value", label: "Readable label",
            description: "Host supplied detail")])
        let reopened = try JSONDecoder().decode(InteractionRecord.self, from: JSONEncoder().encode(record))
        #expect(reopened == record)
    }

    @Test func legacyStoredInputsAndAgentsDecodeWithoutNewOptionalMetadata() throws {
        let input = try WireValue.object(["id": .string("fixture-input"), "label": .string("Question"), "type": .string("text")]).encoded()
        #expect(try JSONDecoder().decode(InteractionInput.self, from: input).options == nil)
        let agent = try WireValue.object(["id": .string(PreviewFixtures.agentID.rawValue), "name": .string("Agent"),
            "pluginID": .string("fixture")]).encoded()
        let decoded = try JSONDecoder().decode(AgentRecord.self, from: agent)
        #expect(decoded.models == nil)
        #expect(decoded.defaultModel == nil)
    }

    @Test func catalogModelsRemainHostSuppliedAndHomeNavigationRetainsDraft() async throws {
        let fixture = RemoteFixture()
        let socket = FixtureRelaySocket(fixture)
        guard case .object(var catalog) = socket.catalog,
              let rawAgents = catalog["agents"], case .array(var agents) = rawAgents,
              let rawAgent = agents.first, case .object(var agent) = rawAgent else {
            Issue.record("Missing fictional catalog"); return
        }
        agent["defaults"] = .object(["model": .string("host-model")])
        agent["models"] = .array([.object(["id": .string("host-model"), "label": .string("Host model"),
            "is_default": .bool(true), "supported_thinking": .strings(["high"])])])
        agents[0] = .object(agent); catalog["agents"] = .array(agents)
        let payload = try RemoteMapping.directory(snapshot: socket.snapshot, catalog: .object(catalog), scope: fixture.scope,
            features: [])
        #expect(payload.agents[0].models?.first?.id == "host-model")
        #expect(payload.agents[0].defaultModel == "host-model")
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: PreviewGianClientService(script: .legacyContract), clock: clock)
        _ = try await signIn(store, clock: clock)
        _ = await store.dispatch(.openNewChat)
        _ = await store.dispatch(.editDraftText("Retain this draft"))
        let draft = store.state.composer.draft
        #expect((await store.dispatch(.returnHome)).isApplied)
        #expect(store.state.navigation.destination == .home)
        _ = await store.dispatch(.openNewChat)
        #expect(store.state.composer.draft == draft)
    }
}
