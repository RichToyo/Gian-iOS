import Foundation

// The Host publishes Q&A and approval cards (`interaction.updated`, the
// `interactions` patch collection and snapshot `interactions`) only for chats in
// an open task that are neither archived nor completed. Every other chat this
// device may open (no task, a closed task, a reopened chat) learns of its cards
// only from `session.subscribe`. The Host announces each update of such a chat,
// including the switch to `pending` just before it registers a card, as a
// `sessions.remove_ids` patch. These re-read the subscribed chat then, and when
// a directory page says it waits for the user while no card is known.

extension LiveGianClientService {
    /// Changes whenever something arrives that could make an in-flight read of
    /// `session` stale or unauthorized: its removal, a newer copy of it, one of
    /// its cards, or a removed task or card that may belong to it. Directory
    /// hints and other sessions' changes leave it alone: the Host sends a hint
    /// for every event it broadcasts.
    func sessionFence(_ session: SessionID) -> Int { max(sessionFences[session] ?? 0, sessionFenceFloor) }

    func advanceSessionFences(_ sessions: [SessionID]) {
        for session in sessions {
            sessionFenceClock += 1
            sessionFences[session] = sessionFenceClock
        }
        if sessionFences.count > 1_024 { advanceAllSessionFences() }
    }

    func advanceAllSessionFences() {
        sessionFenceClock += 1
        sessionFenceFloor = sessionFenceClock
        sessionFences.removeAll()
    }

    /// Re-reads the subscribed chat's metadata and cards shortly. Requests that
    /// arrive meanwhile share it; one that arrives during the read runs another.
    func requestSubscriptionRefresh(scope: ClientScope) {
        guard relay?.features.contains(.sessionDirectoryV1) == true, subscribedSession != nil else { return }
        guard subscriptionRefresh == nil else { subscriptionRefreshQueued = true; return }
        let captured = epoch
        subscriptionRefresh = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.epoch == captured { self.subscriptionRefresh = nil } }
            var delay = self.subscriptionRefreshDelay
            var retries = 0
            while self.epoch == captured {
                do { try await Task.sleep(for: delay) } catch { return }
                guard self.epoch == captured else { return }
                self.subscriptionRefreshQueued = false
                let again = await self.refreshSubscription(scope: scope, epoch: captured)
                guard self.epoch == captured else { return }
                if self.subscriptionRefreshQueued {
                    retries = 0; delay = self.subscriptionRefreshDelay
                    continue
                }
                // Bounded: a chat that stays pending without a card is retried
                // four times over about 9 s, then waits for the next update.
                guard again, retries < 4 else { return }
                retries += 1
                delay = self.subscriptionRefreshDelay * (1 << retries)
            }
        }
    }

    func stopSubscriptionRefresh() {
        subscriptionRefresh?.cancel(); subscriptionRefresh = nil
        subscriptionRefreshQueued = false
        subscribedCards.removeAll(); waitingRefreshRevision = nil
    }

    /// Returns whether to look again soon: the Host says the chat waits for the
    /// user but listed no card yet, or another subscribe was still in flight.
    func refreshSubscription(scope: ClientScope, epoch captured: Int) async -> Bool {
        guard let session = subscribedSession, capabilities != nil else { return false }
        // Never overtake another subscribe: the Host keeps the latest one sent.
        guard subscribesInFlight == 0 else { return true }
        do {
            try requireCapability(.sessionRead, scope: scope)
            return try await subscribe(scope: scope, sessionID: session, epoch: captured, fence: sessionFence(session))
        } catch {
            let safe = error is CancellationError ? RemoteClientError.cancelled : (error as? RemoteClientError) ?? .transport
            guard captured == epoch else { return false }
            if safe == .capabilityDenied || safe == .server(code: "RESOURCE_NOT_FOUND", retryAfter: nil) {
                sessionBecameUnavailable(session, scope: scope)
            }
            // A cancelled read was superseded by another subscribe or by an
            // update of this chat, which asks for its own refresh if it needs one.
            return false
        }
    }

    func sessionBecameUnavailable(_ session: SessionID, scope: ClientScope) {
        directoryMembershipGeneration += 1
        advanceSessionFences([session])
        emit(.sessionUnavailable(session), scope: scope)
    }

    /// A directory page lists the subscribed chat as waiting for the user while
    /// the Host never sent it a card: a chat outside an open task.
    func noteDirectoryEntries(_ entries: [DirectoryEntry], scope: ClientScope) {
        guard let session = subscribedSession, subscribedCards.isEmpty,
              let entry = entries.first(where: { $0.session.id == session }),
              entry.session.attention == .interaction, waitingRefreshRevision != entry.session.revision else { return }
        waitingRefreshRevision = entry.session.revision
        requestSubscriptionRefresh(scope: scope)
    }
}
