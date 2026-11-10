import Foundation
import Testing
@testable import GianCore

/// Snapshot tasks and sessions are scripted; `directory.list` pages for Tasks
/// are served in order, and a page requested with `holdCursor` waits for the test.
@MainActor
final class TaskOrderService: ControlledService {
    var negotiated = false
    var snapshotTasks: [TaskRecord] = []
    var snapshotSessions: [SessionRecord] = []
    /// Set to the store's cursor so a later snapshot is not older than applied patches.
    var snapshotCursor: SyncCursor?
    var taskPages: [DirectoryPageResponse] = []
    var holdCursor: String?
    var held: CheckedContinuation<DirectoryPageResponse, Never>?

    override func refreshDirectory(scope: ClientScope) async -> DirectoryRefreshResponse {
        guard case .snapshot(var payload) = await base.refreshDirectory(scope: scope) else { return .failed("Missing fixture snapshot") }
        if negotiated { payload.negotiatedFeatures.append(.sessionDirectoryV1) }
        payload.tasks = snapshotTasks
        payload.sessions = snapshotSessions
        payload.interactions = []
        if let snapshotCursor { payload.cursor = snapshotCursor }
        return .snapshot(payload)
    }

    override func listDirectory(scope: ClientScope, request: DirectoryPageRequest) async -> DirectoryPageResponse {
        guard negotiated else { return .unsupported }
        if let holdCursor, request.cursor == holdCursor {
            self.holdCursor = nil
            return await withCheckedContinuation { held = $0 }
        }
        guard request.view == .tasks, !taskPages.isEmpty else { return directoryPage(request.view) }
        return taskPages.removeFirst()
    }
}

private func orderTask(_ id: String, _ title: String) -> TaskRecord {
    TaskRecord(id: PreviewFixtures.id(id, TaskID.self), title: title, status: .open, updatedAt: PreviewFixtures.instant)
}

/// `updated` and `activity` are offsets in seconds from the fixture instant.
private func orderSession(_ id: String, in task: TaskRecord, updated: TimeInterval, activity: TimeInterval = -60) -> SessionRecord {
    var session = makeSession(id: id, title: id, taskID: task.id, activity: PreviewFixtures.instant.addingTimeInterval(activity))
    session.updatedAt = PreviewFixtures.instant.addingTimeInterval(updated)
    return session
}

private func orderEntry(_ session: SessionRecord, in task: TaskRecord) -> DirectoryEntry {
    DirectoryEntry(session: session, workspace: WorkspaceRecord(id: session.workspaceID, name: "Harbor Repo"),
                   task: task, searchName: session.title)
}

@MainActor
private func shownRows(_ store: GianClientStore) -> [SessionID] {
    store.state.directory.tasks.flatMap { $0.conversations.map(\.id) }
}

@MainActor
struct TaskOrderTests {
    // IDs sort A < M < Z; the Host (Gian) lists Z first (never reordered, newest)
    // and then the hand-ordered A and M.
    let newest = orderTask("task-z", "Newest task")
    let first = orderTask("task-a", "Dragged first")
    let second = orderTask("task-m", "Dragged second")

    @Test func legacyTasksFollowHostOrderAndRowsKeepTheirPlace() async throws {
        let service = TaskOrderService()
        let z1 = orderSession("z-only", in: newest, updated: -3_600)
        // Activity order would list `recent` first; Gian lists the older one first.
        let older = orderSession("a-older", in: first, updated: -3 * 3_600, activity: -2 * 3_600)
        let recent = orderSession("a-recent", in: first, updated: -3_600, activity: -600)
        let m1 = orderSession("m-only", in: second, updated: -3_600)
        service.snapshotTasks = [newest, first, second]
        service.snapshotSessions = [z1, recent, m1, older]
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock)
        _ = try await signIn(store, clock: clock)
        #expect(store.state.directory.authority == .legacyOpenDoingTasksOnly)
        #expect(store.state.directory.tasks.map(\.id) == [newest.id, first.id, second.id])
        #expect(store.state.directory.tasks[1].conversations.map(\.id) == [older.id, recent.id])
        #expect(store.state.openTasks.map(\.id) == [newest.id, first.id, second.id])

        // New activity does not move a row.
        var running = older
        running.status = .running; running.updatedAt = clock.now(); running.lastActivityAt = clock.now()
        var activity = CanonicalStatePatch(); activity.sessions = [running]
        var cursor = try #require(store.state.sync.cursor)
        #expect(store.applyStatePatch(sequence: cursor.eventSequence + 1, generation: cursor.hostGeneration,
                                      baseRevision: cursor.revision, revision: "order-activity", patch: activity).isApplied)
        #expect(store.state.directory.tasks[1].conversations.map(\.id) == [older.id, recent.id])

        // A task created on the desktop lands on top; a new conversation joins
        // the bottom of its task even though it was updated longest ago.
        let created = orderTask("task-b", "Created on desktop")
        let b1 = orderSession("b-only", in: created, updated: -60)
        let late = orderSession("a-late", in: first, updated: -5 * 3_600)
        var additions = CanonicalStatePatch(); additions.sessions = [late, b1]; additions.tasks = [created]
        cursor = try #require(store.state.sync.cursor)
        #expect(store.applyStatePatch(sequence: cursor.eventSequence + 1, generation: cursor.hostGeneration,
                                      baseRevision: cursor.revision, revision: "order-additions", patch: additions).isApplied)
        #expect(store.state.directory.tasks.map(\.id) == [created.id, newest.id, first.id, second.id])
        #expect(store.state.directory.tasks[2].conversations.map(\.id) == [older.id, recent.id, late.id])

        // A fresh snapshot carries the desktop's latest order (here a drag put
        // "Dragged first" on top); rows keep theirs despite new update times.
        var touched = [z1, recent, m1, older, late, b1]
        for index in touched.indices { touched[index].updatedAt = clock.now().addingTimeInterval(Double(-index)) }
        service.snapshotTasks = [first, created, newest, second]
        service.snapshotSessions = touched
        service.snapshotCursor = store.state.sync.cursor
        #expect(await store.dispatch(.refreshDirectory).isApplied)
        #expect(store.state.directory.tasks.map(\.id) == [first.id, created.id, newest.id, second.id])
        #expect(store.state.directory.tasks[0].conversations.map(\.id) == [older.id, recent.id, late.id])
        #expect(store.state.openTasks.map(\.id) == [first.id, created.id, newest.id, second.id])
    }

    @Test func directoryPagesKeepGianTaskOrderAndNeverReshuffleShownRows() async throws {
        let storageDirectory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: storageDirectory) }
        let service = TaskOrderService()
        service.negotiated = true
        service.snapshotTasks = [newest, first, second]
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock, storage: try SQLiteGianStorage(directory: storageDirectory))
        _ = try await signIn(store, clock: clock)
        #expect(store.state.directory.authority == .negotiatedDirectoryV1)
        #expect(store.state.directory.tasks.isEmpty)

        // Pages come in Host ID order. The second Z row sorts before the first by
        // ID and by update time, but it was seen later, so it goes below.
        let zFirst = orderSession("zz-first-page", in: newest, updated: -3_600)
        let zLater = orderSession("za-second-page", in: newest, updated: -5 * 3_600)
        let a1 = orderSession("a-second-page", in: first, updated: -3_600)
        let m1 = orderSession("m-first-page", in: second, updated: -3_600)
        service.taskPages = [directoryPage(.tasks, [orderEntry(m1, in: second), orderEntry(zFirst, in: newest)],
                                           state: .incomplete, cursor: "order-page-2")]
        service.holdCursor = "order-page-2"
        let load = Task { await store.loadDirectory(.tasks, reset: true) }
        while service.held == nil { await Task.yield() }
        #expect(store.state.directory.tasks.map(\.id) == [newest.id, second.id])
        let shownBefore = shownRows(store)
        #expect(shownBefore == [zFirst.id, m1.id])

        service.held?.resume(returning: directoryPage(.tasks, [orderEntry(a1, in: first), orderEntry(zLater, in: newest)]))
        #expect(await load.value.isApplied)
        #expect(store.state.directory.tasks.map(\.id) == [newest.id, first.id, second.id])
        #expect(store.state.directory.tasks[0].conversations.map(\.id) == [zFirst.id, zLater.id])
        #expect(shownRows(store).filter(shownBefore.contains) == shownBefore)
        let settled = shownRows(store)

        // A refresh returns the same rows in another order with new activity;
        // the later Z row is now the one updated longest ago.
        var busier = [zLater, m1, a1, zFirst]
        for index in busier.indices {
            busier[index].updatedAt = clock.now().addingTimeInterval(Double(index - busier.count))
            busier[index].lastActivityAt = clock.now()
        }
        service.taskPages = [directoryPage(.tasks, [orderEntry(busier[2], in: first), orderEntry(busier[0], in: newest),
                                                    orderEntry(busier[1], in: second), orderEntry(busier[3], in: newest)])]
        #expect(await store.loadDirectory(.tasks, reset: true).isApplied)
        #expect(store.state.directory.tasks.map(\.id) == [newest.id, first.id, second.id])
        #expect(shownRows(store) == settled)

        // The order survives a relaunch; seeding again would put the later Z row first.
        #expect(store.persist())
        let restored = GianClientStore(service: TaskOrderService(), clock: clock,
                                       storage: try SQLiteGianStorage(directory: storageDirectory))
        #expect(restored.restoreAuthorizedSession(authorization: fictionalAuthorization(clock: clock)).isApplied)
        #expect(restored.state.directory.tasks.map(\.id) == [newest.id, first.id, second.id])
        #expect(shownRows(restored) == settled)
    }

    @Test func conversationOrderSeedsTogetherOldestUpdateFirstAndStaysBounded() {
        var order = ConversationOrder()
        let b = orderSession("seed-b", in: first, updated: -60)
        let a = orderSession("seed-a", in: first, updated: -600)
        order.note([b, a])
        #expect(order.ids == [a.id, b.id])
        let c = orderSession("seed-c", in: first, updated: -6_000)
        order.note([c, b, a])
        #expect(order.ids == [a.id, b.id, c.id])
        #expect([c, b, a].sorted(by: order.precedes).map(\.id) == [a.id, b.id, c.id])
        #expect(ConversationOrder(order.persisted ?? []) == order)
        #expect(ConversationOrder().persisted == nil)

        #expect(ConversationOrder([b.id, a.id, b.id]).ids == [b.id, a.id])
        let many = (0..<(ConversationOrder.limit + 10)).map { PreviewFixtures.id("bounded-\($0)", SessionID.self) }
        #expect(ConversationOrder(many).ids == Array(many.suffix(ConversationOrder.limit)))
    }
}
