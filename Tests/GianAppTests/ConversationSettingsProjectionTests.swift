import XCTest
@testable import GianCore
@testable import Gian

/// The composer's ⋯ shows the Host's current settings with the Agent's
/// choices; Fast follows the model; raw effort values get readable names.
final class ConversationSettingsProjectionTests: XCTestCase {
    private func id<Kind>(_ raw: String, _ type: ScopedID<Kind>.Type) -> ScopedID<Kind> {
        ScopedID<Kind>(rawValue: raw)!
    }

    private func state(model: String?, thinking: String?, fast: Bool, approval: String?) -> GianClientState {
        let agentID = id("agent-codex", AgentID.self)
        var agent = AgentRecord(id: agentID, name: "Codex", pluginID: "codex")
        agent.models = [
            AgentModelRecord(id: "sol", label: "GPT-6-Sol", isDefault: true, supportedThinking: ["low", "xhigh"]),
            AgentModelRecord(id: "luna", label: "GPT-6-Luna", isDefault: false, supportedThinking: ["low", "xhigh"]),
        ]
        var session = SessionRecord(
            id: id("session-1", SessionID.self), hostID: id("host-1", HostID.self), title: "Pier", revision: "r1",
            taskID: nil, workspaceID: id("ws-1", WorkspaceID.self), agentID: agentID, agentName: "Codex",
            pluginID: "codex", status: .running, updatedAt: Date(timeIntervalSince1970: 0)
        )
        session.model = model
        session.thinking = thinking
        session.serviceTier = fast ? "fast" : nil
        session.approvalMode = approval
        var state = GianClientState.signedOut()
        state.agents = [agent]
        state.conversation = ConversationProjection(session: session, items: [], cursor: nil, hasOlder: false, hydratedFromCache: false)
        state.agentOptions[agentID] = AgentConversationOptions(
            thinking: [AgentOptionChoice(value: "low", label: "low"), AgentOptionChoice(value: "xhigh", label: "xhigh")],
            approval: [AgentOptionChoice(value: "ask", label: "Ask for approval"), AgentOptionChoice(value: "auto", label: "Approve for me")],
            approvalDefault: "ask",
            supportsFast: true,
            fastModels: ["sol"]
        )
        return state
    }

    func testShowsHostSettingsWithReadableChoices() throws {
        let settings = try XCTUnwrap(StoreProjection.conversationSettings(
            state(model: nil, thinking: "xhigh", fast: true, approval: "auto"), mutationsReady: true))
        XCTAssertEqual(settings.model, "sol", "No model set means the Agent default")
        XCTAssertEqual(settings.thinking.map(\.label), ["Light", "Extra High"])
        XCTAssertEqual(settings.currentThinking, "xhigh")
        XCTAssertEqual(settings.fast, .available(isOn: true))
        XCTAssertEqual(settings.currentApproval, "auto")
        XCTAssertTrue(settings.isEnabled)
    }

    func testFastFollowsTheModelAndApprovalFallsBackToDefault() throws {
        let settings = try XCTUnwrap(StoreProjection.conversationSettings(
            state(model: "luna", thinking: nil, fast: false, approval: nil), mutationsReady: false))
        XCTAssertEqual(settings.fast, .unsupportedModel)
        XCTAssertEqual(settings.currentApproval, "ask")
        XCTAssertFalse(settings.isEnabled)
    }
}
