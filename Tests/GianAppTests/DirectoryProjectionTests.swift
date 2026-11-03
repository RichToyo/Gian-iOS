import XCTest
@testable import GianCore
@testable import Gian

final class DirectoryProjectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_781_000_000)

    private func id<Kind>(_ raw: String, _ type: ScopedID<Kind>.Type) -> ScopedID<Kind> {
        guard let value = ScopedID<Kind>(rawValue: raw) else {
            XCTFail("invalid test id \(raw)")
            fatalError("invalid test id")
        }
        return value
    }

    private func summary(
        _ rawID: String,
        repo: String? = "Harbor Repo",
        taskID: TaskID? = nil,
        activity: Date? = nil
    ) -> ConversationSummary {
        ConversationSummary(
            id: id(rawID, SessionID.self),
            title: "Title \(rawID)",
            agentName: "Kimi",
            pluginID: "kimi.plugin",
            repositoryName: repo,
            status: .done,
            unread: false,
            attention: nil,
            lastActivityAt: activity,
            taskID: taskID,
            hostID: id("host-1", HostID.self)
        )
    }

    func testRepositoriesUseWorkspaceIdentityInsteadOfTitleOrFlatMembership() {
        let firstWorkspace = id("workspace-first", WorkspaceID.self)
        let secondWorkspace = id("workspace-second", WorkspaceID.self)
        var state = GianClientState.signedOut()
        state.directory.repos = [summary("flat-decoy", activity: now)]
        state.directory.repositories = [
            RepositorySection(
                id: firstWorkspace,
                title: "Same repository name",
                conversations: [summary("session-first", activity: now)]
            ),
            RepositorySection(
                id: secondWorkspace,
                title: "Same repository name",
                conversations: [summary("session-second", activity: now.addingTimeInterval(-60))]
            ),
        ]

        let directory = StoreProjection.directory(state)

        XCTAssertEqual(directory.repos.map(\.id), [firstWorkspace, secondWorkspace])
        XCTAssertEqual(directory.repos.map(\.repoName), ["Same repository name", "Same repository name"])
        XCTAssertEqual(directory.repos.map { $0.conversations.map(\.id) }, [
            [id("session-first", SessionID.self)],
            [id("session-second", SessionID.self)],
        ])
        XCTAssertFalse(directory.repos.flatMap(\.conversations).contains { $0.id == id("flat-decoy", SessionID.self) })
    }

    func testTasksUseOnlyCoreSectionsAndDoNotManufactureTasklessGroup() {
        let taskID = id("task-open", TaskID.self)
        let assignedID = id("session-assigned", SessionID.self)
        let tasklessID = id("session-taskless", SessionID.self)
        var state = GianClientState.signedOut()
        state.directory.tasks = [
            TaskSection(
                id: taskID,
                title: "Open task",
                conversations: [summary("session-assigned", taskID: taskID)]
            )
        ]
        state.directory.repositories = [
            RepositorySection(
                id: id("workspace-1", WorkspaceID.self),
                title: "Harbor Repo",
                conversations: [summary("session-taskless")]
            )
        ]

        let directory = StoreProjection.directory(state)

        XCTAssertEqual(directory.tasks.map(\.id), [taskID])
        XCTAssertEqual(directory.tasks.flatMap(\.conversations).map(\.id), [assignedID])
        XCTAssertEqual(directory.repos.flatMap(\.conversations).map(\.id), [tasklessID])
        XCTAssertFalse(directory.tasks.contains { $0.title == "Unassigned" })
    }

    func testPendingInteractionShowsWaitingEvenWithoutSessionAttention() {
        let taskID = id("task-open", TaskID.self)
        var state = GianClientState.signedOut()
        state.directory.tasks = [
            TaskSection(
                id: taskID,
                title: "Open task",
                conversations: [
                    summary("session-approval", taskID: taskID),
                    summary("session-resolved", taskID: taskID),
                    summary("session-quiet", taskID: taskID),
                ]
            )
        ]
        func interaction(_ session: String, phase: InteractionPhase) -> InteractionRecord {
            InteractionRecord(
                id: id("interaction-\(session)", InteractionID.self),
                revision: "1",
                sessionID: id(session, SessionID.self),
                turnID: id("turn-1", TurnID.self),
                kind: .approval,
                title: "Allow",
                detail: "",
                risk: .low,
                actions: [],
                phase: phase
            )
        }
        state.interactions = [
            interaction("session-approval", phase: .pending),
            interaction("session-resolved", phase: .resolvedHere),
        ]

        let badges = StoreProjection.directory(state).tasks.flatMap(\.conversations).map(\.badge)

        XCTAssertEqual(badges, [.waiting, .idle, .idle])
    }

    func testSearchRetainsHostMessageMatchWithoutLocalTitleFiltering() {
        var state = GianClientState.signedOut()
        state.directory.searchQuery = "needle in an old message"
        state.directory.searchResults = [summary("session-message-match")]
        state.directory.searchPage = DirectoryPageStatus(phase: .complete, isStale: false)

        let directory = StoreProjection.directory(state)

        XCTAssertEqual(directory.searchResults.map(\.id), [id("session-message-match", SessionID.self)])
        XCTAssertFalse(directory.searchResults[0].title.contains(state.directory.searchQuery))
    }

    func testEveryPageStatusIsProjectedExactly() {
        let phases: [DirectoryPagePhase] = [
            .idle, .loading, .incomplete, .complete, .cursorInvalid, .failed, .denied, .unsupported,
        ]
        for phase in phases {
            var state = GianClientState.signedOut()
            let status = DirectoryPageStatus(
                phase: phase,
                hasMore: phase == .incomplete,
                isStale: true,
                error: "Fixture detail"
            )
            state.directory.tasksPage = status
            state.directory.reposPage = status
            state.directory.searchPage = status

            let directory = StoreProjection.directory(state)

            XCTAssertEqual(directory.tasksPage, status, "Tasks phase \(phase)")
            XCTAssertEqual(directory.reposPage, status, "Repos phase \(phase)")
            XCTAssertEqual(directory.searchPage, status, "Search phase \(phase)")
        }
    }

    func testDeniedAndUnsupportedPagesHideRetainedRows() {
        var state = GianClientState.signedOut()
        state.directory.tasks = [
            TaskSection(id: id("task-1", TaskID.self), title: "Task", conversations: [summary("session-task")])
        ]
        state.directory.repositories = [
            RepositorySection(
                id: id("workspace-1", WorkspaceID.self),
                title: "Harbor Repo",
                conversations: [summary("session-repo")]
            )
        ]
        state.directory.searchResults = [summary("session-search")]
        state.directory.tasksPage = DirectoryPageStatus(phase: .denied, error: "Denied")
        state.directory.reposPage = DirectoryPageStatus(phase: .unsupported)
        state.directory.searchPage = DirectoryPageStatus(phase: .denied, error: "Denied")

        let directory = StoreProjection.directory(state)

        XCTAssertTrue(directory.tasks.isEmpty)
        XCTAssertTrue(directory.repos.isEmpty)
        XCTAssertTrue(directory.searchResults.isEmpty)
        XCTAssertEqual(directory.tasksPage.phase, .denied)
        XCTAssertEqual(directory.reposPage.phase, .unsupported)
        XCTAssertEqual(directory.searchPage.phase, .denied)
    }

    func testEmptyIncompletePageKeepsContinuationAndIsNotEmptyHistory() {
        var state = GianClientState.signedOut()
        state.directory.searchQuery = "older text"
        state.directory.searchPage = DirectoryPageStatus(
            phase: .incomplete,
            hasMore: true,
            isStale: false
        )

        let directory = StoreProjection.directory(state)

        XCTAssertTrue(directory.searchResults.isEmpty)
        XCTAssertEqual(directory.searchPage.phase, .incomplete)
        XCTAssertTrue(directory.searchPage.hasMore)
        XCTAssertNotEqual(directory.searchPage.phase, .complete)
    }
}
