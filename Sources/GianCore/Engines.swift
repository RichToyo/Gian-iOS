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

    static func parse(payload: String, server: ServerAddress) -> Result<HostPairingInvitation, RejectionCode> {
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
        return .success(.grantNonce(nonce))
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

/// A Host's one-time pairing code: 8 Crockford base32 characters shown as
/// `XXXX-XXXX`. Mirrors the protocol's normalization (case-insensitive, I/L
/// read as 1, O as 0, U refused).
public enum PairingCode {
    public static let length = 8
    static let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// The characters a person typed, mapped and filtered (at most 8).
    public static func characters(from input: String) -> String {
        let mapped = input.uppercased().map { character -> Character in
            switch character {
            case "I", "L": "1"
            case "O": "0"
            default: character
            }
        }
        return String(mapped.filter { alphabet.contains($0) }.prefix(length))
    }

    /// `XXXX-XXXX`, or nil unless the input is exactly one complete code.
    public static func canonical(_ input: String) -> String? {
        let cleaned = input.uppercased().filter { $0 != "-" && !$0.isWhitespace }
        guard !cleaned.contains("U") else { return nil }
        let code = characters(from: cleaned)
        guard code.count == length, code.count == cleaned.count else { return nil }
        return "\(code.prefix(4))-\(code.suffix(4))"
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
        // After everything that started no later, so items stamped the same
        // instant keep the order they arrived in (as Gian shows them).
        var lower = 0
        var upper = merged.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if startsBefore(next, merged[middle]) { upper = middle }
            else { lower = middle + 1 }
        }
        merged.insert(next, at: lower)
        return merged
    }

    /// Whether items changed live during a page read can win over the page
    /// (as in `mergePage`) without hiding a missed middle. Assistant text
    /// streams as deltas: a live copy that extends the page's, or that the
    /// page's extends (chunks still in flight), is the same text. Text begun
    /// after the read is whole. Anything else may sit on a gap.
    static func liveChangesExtend(baseline: [TranscriptItem], current: [TranscriptItem], page: [TranscriptItem]) -> Bool {
        let original = baseline.reduce(into: [TranscriptItemID: TranscriptItem]()) { $0[$1.id] = $1 }
        let read = page.reduce(into: [TranscriptItemID: TranscriptItem]()) { $0[$1.id] = $1 }
        return current.allSatisfy { item in
            guard original[item.id] != item, case .assistant(let live, _) = item.body else { return true }
            guard let copy = read[item.id] else { return original[item.id] == nil }
            guard case .assistant(let paged, _) = copy.body else { return false }
            return live.utf8.starts(with: paged.utf8) || paged.utf8.starts(with: live.utf8)
        }
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
            if let prior = byID[item.id] {
                if prior.turnID != item.turnID { continue }
                // An item sorts by when it started, as on the live path; a
                // page's completion copy must not move it later in its turn.
                item.timestamp = min(prior.timestamp, item.timestamp)
            } else {
                order.append(item.id)
            }
            byID[item.id] = item
        }
        // By turn and start; items that started the same instant keep the
        // order they were first seen in.
        return order.compactMap { byID[$0] }.enumerated().sorted { lhs, rhs in
            if startsBefore(lhs.element, rhs.element) { return true }
            if startsBefore(rhs.element, lhs.element) { return false }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func startsBefore(_ lhs: TranscriptItem, _ rhs: TranscriptItem) -> Bool {
        if lhs.turn != rhs.turn { return lhs.turn < rhs.turn }
        return lhs.timestamp < rhs.timestamp
    }
}

/// In-app notifications, queued in the order they arrive: one per
/// conversation (its latest event replaces an earlier one), at most a few, and
/// never for the conversation on screen or while the app is in the background.
enum BannerReducer {
    static let limit = 3
    static let staleAfter: TimeInterval = 30

    struct Signal: Equatable {
        var sessionID: SessionID
        var title: String
        var kind: BannerEvent
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
        let banner = BannerItem(id: mint(), sessionID: signal.sessionID, title: signal.title,
                                kind: signal.kind, summary: signal.summary, latestAt: now)
        // Ones still queued after a while are no longer news.
        let current = existing.filter { $0.sessionID != signal.sessionID && now.timeIntervalSince($0.latestAt) < staleAfter }
        return Array((current + [banner]).suffix(limit))
    }
}

/// When a conversation's state is worth a notification. Like Gian's attention
/// events, only changes count — a turn completing after work, the Agent
/// starting to wait on the user, a turn failing — never a state that was
/// already so when it was first seen, and never transcript activity.
enum ConversationAlerts {
    enum State: Equatable {
        case idle, working, waiting, failed, completed
    }

    static func state(of session: SessionRecord, waitingOn pending: [InteractionRecord]) -> State {
        if !pending.isEmpty || session.attention == .interaction || session.status == .pending { return .waiting }
        if session.attention == .failed || session.status == .error { return .failed }
        if session.attention == .running || session.status == .running { return .working }
        if session.attention == .completed || session.status == .done { return .completed }
        return .idle
    }

    /// What a change from `old` to `new` announces, if anything.
    static func announcement(from old: State?, to new: State) -> BannerEvent? {
        guard let old, old != new else { return nil }
        switch new {
        case .waiting: return .waiting
        case .failed: return .failed
        case .completed: return old == .working || old == .waiting ? .completed : nil
        case .idle, .working: return nil
        }
    }

    /// Gian's labels for the events.
    static func summary(_ kind: BannerEvent, waitingOn pending: [InteractionRecord]) -> String {
        switch kind {
        case .completed: return "Turn complete"
        case .failed: return "Turn failed"
        case .waiting:
            switch pending.last?.kind {
            case .approval: return "Approval needed"
            case .exitPlanMode: return "Plan review needed"
            case .question, .nativeChoice, nil: return "Answer needed"
            }
        }
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
        var result = existing
        for record in incoming {
            if let index = result.firstIndex(where: { $0.id == record.id }) {
                let prior = result[index]
                if prior.presentableText != nil,
                   prior.textSHA256 == record.textSHA256,
                   record.presentableText == nil {
                    var kept = record
                    kept.presentableText = prior.presentableText
                    kept.integrity = prior.integrity
                    result[index] = kept
                } else {
                    result[index] = record
                }
            } else {
                result.append(record)
            }
        }
        return result
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
        searchCandidates: [SessionRecord],
        conversationOrder: ConversationOrder = ConversationOrder()
    ) -> Projection {
        var names: [WorkspaceID: String] = [:]
        for workspace in workspaces { names[workspace.id] = workspace.name }
        // `tasks` is already in the Host's (Gian's) order and is not re-sorted.
        let visibleTasks = tasks
            .filter { $0.status == .open }
            .map { task in
                TaskSection(
                    id: task.id,
                    title: task.title,
                    conversations: sessions
                        .filter { $0.taskID == task.id && $0.authorized && !$0.archived && $0.completedAt == nil }
                        .sorted(by: conversationOrder.precedes)
                        .map { summary($0, names: names) }
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
                .filter { $0.authorized && !$0.archived && titleMatches($0.title, query: trimmed) }
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

    static func titleMatches(_ title: String, query: String) -> Bool {
        func normalize(_ value: String) -> String {
            value.map { String($0).precomposedStringWithCompatibilityMapping.lowercased() }.joined()
        }
        let needle = normalize(query)
        return !needle.isEmpty && normalize(title).contains(needle)
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
