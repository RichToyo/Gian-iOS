import Foundation
import Testing
@testable import GianCore

/// The Host's unread flag only clears in Gian on the Mac; a conversation read
/// on this device shows as read until something newer happens in it.
@MainActor
struct ReadMarkTests {
    @Test func aConversationReadHereShowsReadUntilItChanges() async throws {
        let (store, _, clock) = makeHarness()
        _ = try await signIn(store, clock: clock)
        let id = PreviewFixtures.sessionID
        setHostUnread(store, id, activity: PreviewFixtures.instant.addingTimeInterval(-60))
        #expect(try shown(store, id).unread)

        #expect((await store.dispatch(.selectConversation(id))).isApplied)
        #expect((await store.dispatch(.returnHome)).isApplied)
        // The Host still says unread.
        let seen = setHostUnread(store, id)
        #expect(try !shown(store, id).unread)

        // A reply after it was read is news again.
        setHostUnread(store, id, activity: seen.addingTimeInterval(60))
        #expect(try shown(store, id).unread)
    }

    @Test func aReplyWhileTheConversationIsOnScreenIsRead() async throws {
        let (store, _, clock) = makeHarness()
        _ = try await signIn(store, clock: clock)
        let id = PreviewFixtures.sessionID
        #expect((await store.dispatch(.selectConversation(id))).isApplied)
        let seen = setHostUnread(store, id)
        setHostUnread(store, id, activity: seen.addingTimeInterval(120))
        #expect((await store.dispatch(.returnHome)).isApplied)
        #expect(try !shown(store, id).unread)
    }

    @Test func readMarksSurviveAReopen() async throws {
        let directory = try temporaryStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let service = PreviewGianClientService(script: .legacyContract)
        let id = PreviewFixtures.sessionID
        do {
            let original = try GianClientStore(service: service, clock: clock,
                ids: SequenceIDGenerator(), storage: SQLiteGianStorage(directory: directory))
            _ = try await signIn(original, clock: clock)
            #expect((await original.dispatch(.selectConversation(id))).isApplied)
            #expect((await original.dispatch(.returnHome)).isApplied)
            setHostUnread(original, id)
            #expect((original.flushStorage()).isApplied)
        }
        let reopened = try GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(),
            storage: SQLiteGianStorage(directory: directory))
        #expect(reopened.restoreAuthorizedSession(authorization: fictionalAuthorization(clock: clock)).isApplied)
        #expect(reopened.sessions.first { $0.id == id }?.unread == true)
        #expect(try !shown(reopened, id).unread)
    }

    @Test func marksCoverOnlyWhatWasSeen() {
        let id = PreviewFixtures.sessionID
        var session = makeSession(id: "read", title: "read", taskID: nil, activity: PreviewFixtures.instant)
        session.id = id
        var marks = ReadMarks()
        #expect(!marks.covers(id, activity: PreviewFixtures.instant))
        let first = marks.noteRead(session)
        let again = marks.noteRead(session)
        #expect(first && !again)
        #expect(marks.covers(id, activity: PreviewFixtures.instant))
        // Within the tolerance for the Host's own timing, still seen.
        #expect(marks.covers(id, activity: PreviewFixtures.instant.addingTimeInterval(2)))
        #expect(!marks.covers(id, activity: PreviewFixtures.instant.addingTimeInterval(30)))
        // Without a known activity time, read until one appears.
        session.activityIsMessageOrExecution = false
        let other = PreviewFixtures.id("other", SessionID.self)
        session.id = other
        let unknown = marks.noteRead(session)
        #expect(unknown)
        #expect(marks.covers(other, activity: nil))
        #expect(!marks.covers(other, activity: PreviewFixtures.instant))
    }

    @Test func marksKeepTheNewest() {
        var stored: [SessionID: Date] = [:]
        for index in 0..<(ReadMarks.limit + 10) {
            stored[PreviewFixtures.id("s\(index)", SessionID.self)] = PreviewFixtures.instant.addingTimeInterval(Double(index))
        }
        let marks = ReadMarks(stored)
        #expect(marks.marks.count == ReadMarks.limit)
        #expect(marks.marks[PreviewFixtures.id("s0", SessionID.self)] == nil)
        #expect(marks.marks[PreviewFixtures.id("s\(ReadMarks.limit + 9)", SessionID.self)] != nil)
    }

    /// Sets the Host's flag to unread (and the activity, if given) as an
    /// update from the Host would, and returns the conversation's activity.
    @discardableResult
    private func setHostUnread(_ store: GianClientStore, _ id: SessionID, activity: Date? = nil) -> Date {
        guard let index = store.sessions.firstIndex(where: { $0.id == id }) else {
            Issue.record("No session \(id)")
            return .distantPast
        }
        store.sessions[index].unread = true
        if let activity {
            store.sessions[index].lastActivityAt = activity
            store.sessions[index].activityIsMessageOrExecution = true
        }
        store.reproject()
        return ReadMarks.activity(store.sessions[index])
    }

    private func shown(_ store: GianClientStore, _ id: SessionID) throws -> ConversationSummary {
        let directory = store.state.directory
        let rows = directory.tasks.flatMap(\.conversations) + directory.repos + directory.repositories.flatMap(\.conversations)
        return try #require(rows.first { $0.id == id })
    }
}
