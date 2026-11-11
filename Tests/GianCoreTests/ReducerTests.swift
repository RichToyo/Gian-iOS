import Foundation
import Testing
@testable import GianCore

@MainActor
struct ReducerTests {
    @Test func sevenDayWindowAndExceptions() {
        let now = PreviewFixtures.instant
        let cutoff = now.addingTimeInterval(-RemoteLimits.recentActivity)
        #expect(RemoteLimits.recentActivity == 604_800)
        let open = TaskRecord(id: PreviewFixtures.taskID, title: "Paint the harbor", status: .open, updatedAt: now)
        let done = TaskRecord(
            id: PreviewFixtures.id("task-done", TaskID.self),
            title: "Done pier",
            status: .completed,
            updatedAt: now
        )
        let sessions = [
            makeSession(id: "session-exact", title: "Exact", taskID: nil, activity: cutoff, real: true, now: now),
            makeSession(id: "session-early", title: "Early", taskID: nil, activity: cutoff.addingTimeInterval(-1), real: true, now: now),
            makeSession(id: "session-running", title: "Running late", taskID: nil, status: .running, activity: cutoff.addingTimeInterval(-10), real: true, now: now),
            makeSession(id: "session-pending", title: "Pending late", taskID: nil, status: .pending, activity: cutoff.addingTimeInterval(-10), real: true, now: now),
            makeSession(id: "session-viewed", title: "Only viewed", taskID: PreviewFixtures.taskID, status: .new, activity: now, real: false, now: now),
            makeSession(id: "session-archived", title: "Archived log", taskID: PreviewFixtures.taskID, status: .running, archived: true, activity: now, real: true, now: now),
            makeSession(id: "session-closed-attention", title: "Completed attention", taskID: nil, attention: .completed, activity: cutoff.addingTimeInterval(-10), real: true, now: now),
            makeSession(id: "session-failed-attention", title: "Failed attention", taskID: nil, attention: .failed, activity: cutoff.addingTimeInterval(-10), real: true, now: now),
            makeSession(id: "session-interaction", title: "Needs a person", taskID: nil, attention: .interaction, activity: cutoff.addingTimeInterval(-10), real: false, now: now),
            makeSession(id: "session-open-task", title: "Mooring notes", taskID: PreviewFixtures.taskID, status: .new, activity: now, real: true, now: now),
            makeSession(id: "session-done-task", title: "Finished work", taskID: done.id, activity: now, real: true, now: now),
            makeSession(id: "session-unauthorized", title: "Hidden", taskID: PreviewFixtures.taskID, authorized: false, activity: now, real: true, now: now),
        ]
        let full = DirectoryFilter.project(
            now: now,
            authority: .fullAuthorizedDirectory,
            tasks: [open, done],
            sessions: sessions,
            workspaces: [WorkspaceRecord(id: PreviewFixtures.workspaceID, name: "Harbor Repo")],
            query: "Old",
            searchCandidates: [makeSession(id: "session-old-log", title: "Old log", taskID: nil, activity: cutoff.addingTimeInterval(-10), real: true, now: now)]
        )
        let titles = directoryTitles(full)
        #expect(titles.repos == Set(["Exact", "Running late", "Pending late", "Needs a person", "Mooring notes", "Finished work"]))
        #expect(!titles.repos.contains("Failed attention"))
        #expect(!titles.repos.contains("Early"))
        #expect(!titles.repos.contains("Only viewed"))
        #expect(!titles.repos.contains("Archived log"))
        #expect(!titles.repos.contains("Completed attention"))
        #expect(titles.tasks == Set(["Mooring notes", "Only viewed"]))
        #expect(full.tasks.map(\.title) == ["Paint the harbor"])
        #expect(full.reposSupport == .supported)
        #expect(full.searchSupport == .supported)
        #expect(full.searchResults.map(\.title) == ["Old log"])

        let legacy = DirectoryFilter.project(
            now: now,
            authority: .legacyOpenDoingTasksOnly,
            tasks: [open, done],
            sessions: sessions,
            workspaces: [WorkspaceRecord(id: PreviewFixtures.workspaceID, name: "Harbor Repo")],
            query: "Old",
            searchCandidates: [makeSession(id: "session-old-log", title: "Old log", taskID: nil, activity: now, real: true, now: now)]
        )
        #expect(legacy.repos.isEmpty)
        #expect(legacy.reposSupport == .unsupported(.reposDirectory))
        #expect(legacy.searchSupport == .unsupported(.olderSearch))
        #expect(legacy.searchResults.isEmpty)
        #expect(legacy.limitations.map(\.surface) == [.reposDirectory, .olderSearch, .tasklessFirstSend])
        let legacyTitles = directoryTitles(legacy)
        #expect(legacyTitles.tasks == Set(["Mooring notes", "Only viewed"]))
        #expect(!legacyTitles.tasks.contains("Finished work"))
        #expect(!legacyTitles.repos.contains("Exact"))
    }

    @Test func tasksHideCompletedConversationsWithoutFilteringReposOrSearch() {
        let now = PreviewFixtures.instant
        let task = TaskRecord(id: PreviewFixtures.taskID, title: "Open task", status: .open, updatedAt: now)
        var finished = makeSession(id: "finished", title: "Finished", taskID: task.id, status: .new, activity: now, real: true, now: now)
        finished.completedAt = "2026-01-01T00:00:00Z"
        let idle = makeSession(id: "idle", title: "Idle", taskID: task.id, status: .done, activity: now, real: true, now: now)
        let running = makeSession(id: "running", title: "Running", taskID: task.id, status: .running, activity: now, real: true, now: now)
        for authority in [DirectoryAuthority.fullAuthorizedDirectory, .legacyOpenDoingTasksOnly] {
            let projection = DirectoryFilter.project(now: now, authority: authority, tasks: [task], sessions: [finished, idle, running],
                workspaces: [], query: "Finished", searchCandidates: [finished])
            #expect(Set(projection.tasks.first?.conversations.map(\.title) ?? []) == Set(["Idle", "Running"]))
            if authority == .fullAuthorizedDirectory {
                #expect(projection.repos.contains { $0.title == "Finished" })
                #expect(projection.searchResults.map(\.title) == ["Finished"])
            }
        }
    }

    @Test func translationRevisionsAndIntegrity() {
        let hello = "hello"
        let digest = SHA256Hex.digest(Data(hello.utf8))
        #expect(digest == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        #expect(hello.utf16.count == 5)

        let current = translationState(revision: 5, configRevision: 3, automaticRevision: 4, epoch: "epoch-1")
        let olderRevision = translationState(revision: 4, configRevision: 9, language: "fr")
        #expect(TranslationReducer.applyState(current: current, incoming: olderRevision, authoritative: true) == current)
        let olderConfig = translationState(revision: 6, configRevision: 2, language: "fr")
        #expect(TranslationReducer.applyState(current: current, incoming: olderConfig, authoritative: true) == current)

        let newer = translationState(revision: 6, configRevision: 3, automaticRevision: 1, epoch: "epoch-1", language: "fr")
        let advanced = TranslationReducer.applyState(current: current, incoming: newer, authoritative: false)
        #expect(advanced.revision == 6)
        #expect(advanced.sendingLanguage == "fr")
        #expect(advanced.automaticRevision == 4)
        #expect(advanced.automaticEpoch == "epoch-1")

        let replaced = TranslationReducer.applyState(
            current: current,
            incoming: translationState(revision: 5, configRevision: 3, automaticRevision: 1, epoch: "epoch-2", language: "de"),
            authoritative: true
        )
        #expect(replaced.automaticEpoch == "epoch-2")
        #expect(replaced.automaticRevision == 1)
        #expect(replaced.sendingLanguage == "de")

        var watched = current
        watched.automatic["line"] = AutomaticProgress(pending: true)
        let olderDelta = TranslationReducer.applyAutomatic(
            current: watched,
            sourceID: "line",
            pending: false,
            error: nil,
            revision: 3,
            epoch: "epoch-1"
        )
        #expect(olderDelta == watched)
        let otherEpoch = TranslationReducer.applyAutomatic(
            current: watched,
            sourceID: "line",
            pending: true,
            error: nil,
            revision: 9,
            epoch: "epoch-2"
        )
        #expect(otherEpoch == watched)
        let unbound = translationState(revision: 1, configRevision: 1)
        let delta = TranslationReducer.applyAutomatic(
            current: unbound,
            sourceID: "line",
            pending: true,
            error: nil,
            revision: 2,
            epoch: "epoch-new"
        )
        #expect(delta.automaticEpoch.isEmpty)
        #expect(delta.automaticRevision == 0)

        let recordID = PreviewFixtures.id("translation-1", TranslationRecordID.self)
        let verified = TranslationReducer.verifiedRecord(
            id: recordID,
            sourceID: "item-1",
            targetLanguage: "es",
            text: hello,
            textLength: 5,
            textSHA256: digest,
            sourceSHA256: digest,
            paged: false
        )
        #expect(verified.presentableText == hello)
        #expect(verified.integrity == .inlineVerified)
        let mismatch = TranslationReducer.verifiedRecord(
            id: recordID,
            sourceID: nil,
            targetLanguage: "es",
            text: hello,
            textLength: 5,
            textSHA256: "00",
            sourceSHA256: digest,
            paged: false
        )
        #expect(mismatch.presentableText == nil)
        #expect(mismatch.integrity == .hashMismatch)
        let short = TranslationReducer.verifiedRecord(
            id: recordID,
            sourceID: nil,
            targetLanguage: "es",
            text: hello,
            textLength: 4,
            textSHA256: digest,
            sourceSHA256: digest,
            paged: false
        )
        #expect(short.presentableText == nil)
        #expect(short.integrity == .lengthMismatch)
        let descriptor = TranslationReducer.verifiedRecord(
            id: recordID,
            sourceID: nil,
            targetLanguage: "es",
            text: nil,
            textLength: 5,
            textSHA256: digest,
            sourceSHA256: digest,
            paged: false
        )
        #expect(descriptor.presentableText == nil)
        #expect(descriptor.integrity == .descriptorPending)

        var withText = translationState(revision: 1, configRevision: 1)
        withText.records = [verified]
        var descriptorState = translationState(revision: 2, configRevision: 1)
        descriptorState.records = [descriptor]
        let kept = TranslationReducer.applyState(current: withText, incoming: descriptorState, authoritative: true)
        #expect(kept.records.first?.presentableText == hello)
        #expect(kept.records.first?.integrity == .inlineVerified)
        var second = verified
        second.id = PreviewFixtures.id("aaa-newer-translation", TranslationRecordID.self)
        withText.records = [verified, second]
        descriptorState.records = []
        let ordered = TranslationReducer.applyState(current: withText, incoming: descriptorState, authoritative: true)
        #expect(ordered.records.map(\.id) == [verified.id, second.id])
    }

    @Test func itemsStampedTheSameInstantKeepTheOrderTheyArrivedIn() throws {
        let at = PreviewFixtures.instant
        // Ids that sort the other way round from their arrival.
        let text = transcriptItem(id: "zz-text", turn: 1, text: "Looking", at: at)
        var tool = transcriptItem(id: "aa-tool", turn: 1, text: "", at: at)
        tool.body = .command(status: .running, exitCode: nil)
        let live = try #require(TranscriptLog.applyingLive(existing: [text], item: tool))
        #expect(live.map(\.id.rawValue) == ["zz-text", "aa-tool"])
        #expect(TranscriptLog.merge(existing: [], incoming: [text, tool]).map(\.id.rawValue) == ["zz-text", "aa-tool"])
        #expect(TranscriptLog.merge(existing: live, incoming: [tool, text]).map(\.id.rawValue) == ["zz-text", "aa-tool"])
    }

    @Test func transcriptDedupOrderAndSequence() {
        let older = transcriptItem(id: "item-b", turn: 1, text: "First", at: PreviewFixtures.instant)
        var newer = transcriptItem(id: "item-a", turn: 2, text: "Second", at: PreviewFixtures.instant.addingTimeInterval(10))
        let duplicate = transcriptItem(id: "item-a", turn: 2, text: "Second revised", at: newer.timestamp)
        let merged = TranscriptLog.merge(existing: [newer], incoming: [older, duplicate])
        #expect(merged.map(\.id.rawValue) == ["item-b", "item-a"])
        if case .user(let text, _, _, _) = merged[1].body {
            #expect(text == "Second revised")
        } else {
            #expect(Bool(false))
        }
        newer = duplicate
        #expect(TranscriptLog.merge(existing: [newer], incoming: [newer]).count == 1)

        #expect(CanonicalSequence.advance(last: nil, incoming: 1) == .needsSnapshot)
        #expect(CanonicalSequence.advance(last: -1, incoming: 0) == .next)
        #expect(CanonicalSequence.advance(last: -1, incoming: 1) == .next)
        #expect(CanonicalSequence.advance(last: Int.max, incoming: 0) == .gap)
        #expect(CanonicalSequence.advance(last: 4, incoming: 5) == .next)
        #expect(CanonicalSequence.advance(last: 4, incoming: 4) == .gap)
        #expect(CanonicalSequence.advance(last: 4, incoming: 6) == .gap)
    }

    @Test func uuidV7AndAttachmentBounds() {
        let first = UUIDv7.generate(date: PreviewFixtures.instant, counter: 1)
        let second = UUIDv7.generate(date: PreviewFixtures.instant, counter: 2)
        #expect(isUUIDv7(first))
        #expect(isUUIDv7(second))
        #expect(first != second)
        let generator = SequenceIDGenerator()
        let minted = generator.next(at: PreviewFixtures.instant)
        #expect(isUUIDv7(minted))
        #expect(AttachmentRules.accepts(byteCount: RemoteLimits.maxAttachmentBytes))
        #expect(!AttachmentRules.accepts(byteCount: RemoteLimits.maxAttachmentBytes + 1))
        #expect(!AttachmentRules.accepts(byteCount: 0))
    }
}
