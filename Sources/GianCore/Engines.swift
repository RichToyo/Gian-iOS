import CryptoKit
import Foundation

enum SHA256Hex {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum AttachmentRules {
    static func safeFilename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255
            && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    static func accepts(byteCount: Int) -> Bool {
        byteCount > 0 && byteCount <= RemoteLimits.maxAttachmentBytes
    }
}

enum PairingQR {
    private static let noncePattern = #"^[-_A-Za-z0-9]{16,256}$"#
    private static let blockedNames: Set<String> = [
        "password", "access_token", "device_code", "client_secret", "github_token",
    ]

    static func parse(payload: String, server: ServerAddress) -> Result<HostPairingQR, RejectionCode> {
        guard let components = URLComponents(string: payload),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil
        else { return .failure(.pairingQRInvalid) }
        guard host == server.origin.host?.lowercased(), components.port == server.origin.port else {
            return .failure(.pairingServerMismatch)
        }
        let path = components.path
        guard path.isEmpty || path == "/" || path == "/pair" else { return .failure(.pairingQRInvalid) }
        let queryItems = components.queryItems ?? []
        let fragmentItems = fragmentItems(components.fragment)
        if containsBlocked(queryItems) || containsBlocked(fragmentItems) { return .failure(.pairingQRInvalid) }
        let nonces = values(named: "nonce", in: queryItems) + values(named: "nonce", in: fragmentItems)
        guard nonces.count == 1, let nonce = nonces.first,
              nonce.range(of: noncePattern, options: .regularExpression) != nil
        else { return .failure(.pairingQRInvalid) }
        return .success(HostPairingQR(grantNonce: nonce))
    }

    private static func fragmentItems(_ fragment: String?) -> [URLQueryItem] {
        guard let fragment, !fragment.isEmpty else { return [] }
        return URLComponents(string: "https://nonce.invalid/?\(fragment)")?.queryItems ?? []
    }

    private static func values(named name: String, in items: [URLQueryItem]) -> [String] {
        items.compactMap { $0.name == name ? $0.value : nil }
    }

    private static func containsBlocked(_ items: [URLQueryItem]) -> Bool {
        items.contains { blockedNames.contains($0.name.lowercased()) }
    }
}

enum CanonicalSequence {
    enum Advance: Equatable {
        case next
        case gap
        case needsSnapshot
    }

    /// Matches remote-web: after the initial -1 sentinel, only last + 1 advances.
    /// A duplicate sequence is a gap once a canonical baseline is established.
    static func advance(last: Int?, incoming: Int) -> Advance {
        guard let last else { return .needsSnapshot }
        guard incoming >= 0, last >= -1 else { return .gap }
        if last == -1 { return .next }
        guard last < Int.max else { return .gap }
        if incoming == last + 1 { return .next }
        return .gap
    }
}

enum TranscriptLog {
    /// Live chunks have already passed the transport's per-connection sequence
    /// gate. Equal text in two different frames is two chunks, not a duplicate.
    static func applyingLive(existing: [TranscriptItem], item: TranscriptItem) -> [TranscriptItem]? {
        let index = existing.firstIndex { $0.id == item.id }
        let previous = index.map { existing[$0] }
        if let previous, previous.turnID != item.turnID || previous.turn != item.turn { return nil }
        var next = item
        if let previous { next.timestamp = min(previous.timestamp, item.timestamp) }
        if case .assistant(let chunk, let delta) = item.body {
            if let previous {
                guard case .assistant(let text, _) = previous.body else { return nil }
                if delta, text.utf8.count + chunk.utf8.count > 2 * 1024 * 1024 { return nil }
                next.body = .assistant(text: delta ? text + chunk : chunk, delta: false)
            } else {
                next.body = .assistant(text: chunk, delta: false)
            }
        }
        if let index, next == existing[index] { return existing }
        var merged = existing
        if let index, next.timestamp == existing[index].timestamp {
            merged[index] = next
            return merged
        }
        if let index { merged.remove(at: index) }
        var lower = 0
        var upper = merged.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if ordered(merged[middle], next) { lower = middle + 1 }
            else { upper = middle }
        }
        merged.insert(next, at: lower)
        return merged
    }

    static func mergePage(baseline: [TranscriptItem], current: [TranscriptItem], page: [TranscriptItem]) -> [TranscriptItem] {
        let original = baseline.reduce(into: [TranscriptItemID: TranscriptItem]()) { $0[$1.id] = $1 }
        let changedDuringRequest = current.filter { original[$0.id] != $0 }
        return merge(existing: merge(existing: current, incoming: page), incoming: changedDuringRequest)
    }

    static func merge(existing: [TranscriptItem], incoming: [TranscriptItem]) -> [TranscriptItem] {
        var byID: [TranscriptItemID: TranscriptItem] = [:]
        var order: [TranscriptItemID] = []
        for var item in existing + incoming {
            // Pages are full canonical items, never append operations.
            if case .assistant(let text, _) = item.body { item.body = .assistant(text: text, delta: false) }
            if let prior = byID[item.id], prior.turnID != item.turnID { continue }
            if byID[item.id] == nil { order.append(item.id) }
            byID[item.id] = item
        }
        let merged = order.compactMap { byID[$0] }
        return merged.sorted(by: ordered)
    }

    private static func ordered(_ lhs: TranscriptItem, _ rhs: TranscriptItem) -> Bool {
        if lhs.turn != rhs.turn { return lhs.turn < rhs.turn }
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return lhs.id.rawValue < rhs.id.rawValue
    }
}

enum BannerReducer {
    struct Signal: Equatable {
        var sessionID: SessionID
        var title: String
        var summary: String
    }

    static func reduce(
        existing: [BannerItem],
        signal: Signal,
        currentSessionID: SessionID?,
        foreground: Bool,
        now: Date,
        mint: () -> BannerID
    ) -> [BannerItem] {
        guard foreground, signal.sessionID != currentSessionID else { return existing }
        if let index = existing.firstIndex(where: { $0.sessionID == signal.sessionID }) {
            var copy = existing
            copy[index].summary = signal.summary
            copy[index].eventCount += 1
            copy[index].latestAt = now
            return copy
        }
        return existing + [
            BannerItem(
                id: mint(),
                sessionID: signal.sessionID,
                title: signal.title,
                summary: signal.summary,
                eventCount: 1,
                latestAt: now
            ),
        ]
    }
}

enum TranslationIntegrity {
    /// `text_length` is a UTF-16 length. The digest is SHA-256 over UTF-8 bytes.
    static func classify(text: String?, expectedLength: Int, expectedSHA256: String) -> (TranslationIntegrityState, String?) {
        guard expectedLength >= 0, expectedLength <= 2 * 1024 * 1024,
              expectedSHA256.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
            return (.hashMismatch, nil)
        }
        guard let text else { return (.descriptorPending, nil) }
        guard text.utf8.count <= 8 * 1024 * 1024 else { return (.lengthMismatch, nil) }
        if text.utf16.count != expectedLength { return (.lengthMismatch, nil) }
        let digest = SHA256Hex.digest(Data(text.utf8))
        if digest != expectedSHA256.lowercased() { return (.hashMismatch, nil) }
        return (.inlineVerified, text)
    }
}

enum TranslationReducer {
    static func applyState(
        current: TranslationSessionState,
        incoming: TranslationSessionState,
        authoritative: Bool
    ) -> TranslationSessionState {
        if current.supported
            && (incoming.revision < current.revision || incoming.configRevision < current.configRevision) {
            return current
        }
        let sameEpoch = incoming.automaticEpoch == current.automaticEpoch
        let acceptAutomatic = !current.supported
            || (sameEpoch && incoming.automaticRevision >= current.automaticRevision)
            || (authoritative && (current.automaticEpoch.isEmpty || !sameEpoch))
        var next = incoming
        next.supported = true
        let checked = incoming.records.map {
            verifiedRecord(id: $0.id, sourceID: $0.sourceID, targetLanguage: $0.targetLanguage,
                text: $0.presentableText, textLength: $0.textLength, textSHA256: $0.textSHA256,
                sourceSHA256: $0.sourceSHA256, paged: $0.integrity == .pagedVerified)
        }
        next.records = merge(existing: current.records, incoming: checked)
        next.reading = current.reading
        next.notice = ""
        if !acceptAutomatic {
            next.automatic = current.automatic
            next.automaticRevision = current.automaticRevision
            next.automaticEpoch = current.automaticEpoch
        }
        return next
    }

    static func applyAutomatic(
        current: TranslationSessionState,
        sourceID: String,
        pending: Bool,
        error: String?,
        revision: Int,
        epoch: String
    ) -> TranslationSessionState {
        var next = current
        if current.automaticEpoch.isEmpty {
            // A delta must not establish the epoch. Only an authoritative state read does.
        } else if epoch != current.automaticEpoch || revision < current.automaticRevision {
            return current
        } else {
            next.automaticRevision = max(current.automaticRevision, revision)
            next.automaticEpoch = epoch
        }
        if !pending && (error == nil || error?.isEmpty == true) {
            next.automatic.removeValue(forKey: sourceID)
        } else {
            next.automatic[sourceID] = AutomaticProgress(pending: pending, error: error)
        }
        return next
    }

    static func verifiedRecord(
        id: TranslationRecordID,
        sourceID: String?,
        targetLanguage: String,
        text: String?,
        textLength: Int,
        textSHA256: String,
        sourceSHA256: String,
        paged: Bool
    ) -> ReadingTranslation {
        let (integrity, presentable) = TranslationIntegrity.classify(
            text: text,
            expectedLength: textLength,
            expectedSHA256: textSHA256
        )
        let settled: TranslationIntegrityState
        if paged && integrity == .inlineVerified {
            settled = .pagedVerified
        } else {
            settled = integrity
        }
        return ReadingTranslation(
            id: id,
            sourceID: sourceID,
            targetLanguage: targetLanguage,
            presentableText: presentable,
            textLength: textLength,
            textSHA256: textSHA256.lowercased(),
            sourceSHA256: sourceSHA256.lowercased(),
            integrity: settled
        )
    }

    private static func merge(existing: [ReadingTranslation], incoming: [ReadingTranslation]) -> [ReadingTranslation] {
        var byID: [TranslationRecordID: ReadingTranslation] = [:]
        for record in existing { byID[record.id] = record }
        for record in incoming {
            if let prior = byID[record.id],
               prior.presentableText != nil,
               prior.textSHA256 == record.textSHA256,
               record.presentableText == nil {
                var kept = record
                kept.presentableText = prior.presentableText
                kept.integrity = prior.integrity
                byID[record.id] = kept
            } else {
                byID[record.id] = record
            }
        }
        return byID.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }
}

enum DirectoryFilter {
    struct Projection: Equatable {
        var tasks: [TaskSection]
        var repos: [ConversationSummary]
        var reposSupport: SurfaceSupport
        var searchSupport: SurfaceSupport
        var searchResults: [ConversationSummary]
        var limitations: [LegacyLimitation]
    }

    static func project(
        now: Date,
        authority: DirectoryAuthority,
        tasks: [TaskRecord],
        sessions: [SessionRecord],
        workspaces: [WorkspaceRecord],
        query: String?,
        searchCandidates: [SessionRecord]
    ) -> Projection {
        var names: [WorkspaceID: String] = [:]
        for workspace in workspaces { names[workspace.id] = workspace.name }
        let visibleTasks = tasks
            .filter { $0.status == .open }
            .sorted { $0.id.rawValue < $1.id.rawValue }
            .map { task in
                TaskSection(
                    id: task.id,
                    title: task.title,
                    conversations: sessions
                        .filter { $0.taskID == task.id && $0.authorized && !$0.archived }
                        .map { summary($0, names: names) }
                        .sorted(by: sortRows)
                )
            }
        let legacy = authority == .legacyOpenDoingTasksOnly
        let repos = legacy ? [] : sessions.filter(includeInRepos(now: now)).map { summary($0, names: names) }.sorted(by: sortRows)
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let results: [ConversationSummary]
        if legacy || trimmed.isEmpty {
            results = []
        } else {
            results = searchCandidates
                .filter { $0.authorized && !$0.archived && matches($0, query: trimmed, names: names) }
                .map { summary($0, names: names) }
                .sorted(by: sortRows)
        }
        return Projection(
            tasks: visibleTasks,
            repos: repos,
            reposSupport: legacy ? .unsupported(.reposDirectory) : .supported,
            searchSupport: legacy ? .unsupported(.olderSearch) : .supported,
            searchResults: results,
            limitations: legacy ? LegacyCopy.limitations : []
        )
    }

    private static func includeInRepos(now: Date) -> (SessionRecord) -> Bool {
        let cutoff = now.addingTimeInterval(-RemoteLimits.recentActivity)
        return { session in
            guard session.authorized, !session.archived else { return false }
            if session.status == .running || session.status == .pending { return true }
            switch session.attention {
            case .running, .interaction:
                return true
            case .completed, .failed, .none:
                break
            }
            guard session.activityIsMessageOrExecution, let at = session.lastActivityAt else { return false }
            return at >= cutoff
        }
    }

    private static func matches(_ session: SessionRecord, query: String, names: [WorkspaceID: String]) -> Bool {
        let haystack = [session.title, names[session.workspaceID] ?? ""].joined(separator: " ")
        return haystack.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    static func summary(_ session: SessionRecord, names: [WorkspaceID: String]) -> ConversationSummary {
        ConversationSummary(
            id: session.id,
            title: session.title,
            agentName: session.agentName,
            pluginID: session.pluginID,
            repositoryName: names[session.workspaceID],
            status: session.status,
            unread: session.unread,
            attention: session.attention,
            lastActivityAt: session.activityIsMessageOrExecution ? session.lastActivityAt : nil,
            taskID: session.taskID,
            hostID: session.hostID
        )
    }

    private static func sortRows(_ lhs: ConversationSummary, _ rhs: ConversationSummary) -> Bool {
        let left = lhs.lastActivityAt ?? .distantPast
        let right = rhs.lastActivityAt ?? .distantPast
        if left != right { return left > right }
        return lhs.id.rawValue < rhs.id.rawValue
    }
}
