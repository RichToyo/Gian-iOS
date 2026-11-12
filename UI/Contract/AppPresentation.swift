import Foundation
import Observation
import SwiftUI
import GianCore

/// Store state projected into separately observed presentation values. The
/// store publishes one `state` value, so a view reading it re-renders on every
/// change anywhere (a keystroke, a streamed chunk). Screens read these values
/// instead: each is reassigned only when it actually changes, so a change
/// re-renders only the screens that show it. Transcript rows and the directory
/// are rebuilt only when their inputs change.
@MainActor
@Observable
final class AppPresentation {
    private(set) var phase: ClientPhase
    private(set) var hosts: [HostItem] = []
    private(set) var directory: DirectoryPresentation
    private(set) var navigation: NavigationState
    private(set) var conversation: ActiveConversationPresentation?
    private(set) var composer: ComposerProjection
    private(set) var workspaces: [WorkspaceRecord] = []
    private(set) var agents: [AgentRecord] = []
    private(set) var openTasks: [TaskGroupItem] = []
    private(set) var mutationsReady = false
    private(set) var directoryNegotiated = false
    private(set) var canRetryUncertainCreate = false
    private(set) var diagnostic: DiagnosticPresentation = .none
    private(set) var storageError: String?
    private(set) var serverOutcomeUnconfirmed = false
    private(set) var invalidationUnconfirmed = false
    private(set) var selectedAgentModels: [AgentModelRecord] = []
    private(set) var conversationSettings: ConversationSettingsPresentation?
    private(set) var newChatSettings: ConversationSettingsPresentation?
    private(set) var serverAddress = "—"
    private(set) var pairing = PairingState()
    private(set) var agentLogos: [String: AgentLogoImages] = [:]
    private(set) var logoTrigger: AgentLogoTrigger
    private(set) var optionsTrigger: AgentOptionsTrigger
    private(set) var restorationHint: RestorationHintSelection

    struct PairingState: Equatable {
        var isWaiting = false
        var didPair = false
        var notice: String?
    }

    @ObservationIgnored private var rowsInput: StoreProjection.TranscriptRowsInput?
    @ObservationIgnored private var rows: [TranscriptRow] = []
    /// New transcript content is revealed a step at a time (see TranscriptPacing).
    @ObservationIgnored private var pacing = TranscriptPacing()
    @ObservationIgnored private var pacingStep: Task<Void, Never>?
    @ObservationIgnored private var directoryInput: DirectoryInput?
    /// The chat title's status inputs as shown, and newer ones while they settle.
    @ObservationIgnored private var shownStatus = ConversationStatusInputs.quiet
    @ObservationIgnored private var settlingStatus: ConversationStatusInputs?
    @ObservationIgnored private var statusSettle: Task<Void, Never>?

    private struct DirectoryInput: Equatable {
        let directory: DirectoryProjection
        let view: DirectoryView
        let awaitingUser: [InteractionRecord]
    }

    init(store: GianClientStore) {
        let state = store.state
        phase = state.phase
        directory = StoreProjection.directory(state)
        navigation = state.navigation
        composer = state.composer
        logoTrigger = AgentLogoTrigger(store)
        optionsTrigger = AgentOptionsTrigger(store)
        restorationHint = RestorationHintSelection(state)
        sync(store)
    }

    /// The store's presentation, built once. SwiftUI evaluates a view's
    /// `@State` initial value on every init of the view, and building a
    /// presentation reads the store: inside the parent's body, that made the
    /// parent depend on the store, so every store change (each streamed chunk)
    /// re-ran the app's root and built a full presentation only to drop it.
    static func shared(for store: GianClientStore) -> AppPresentation {
        built.removeAll { $0.store == nil || $0.presentation == nil }
        if let presentation = built.first(where: { $0.store === store })?.presentation { return presentation }
        let presentation = AppPresentation(store: store)
        built.append(Built(store: store, presentation: presentation))
        return presentation
    }

    /// Kept alive by the view state holding it.
    private final class Built {
        weak var store: GianClientStore?
        weak var presentation: AppPresentation?

        init(store: GianClientStore, presentation: AppPresentation) {
            self.store = store
            self.presentation = presentation
        }
    }

    private static var built: [Built] = []

    /// Re-syncs after every store change until cancelled. Changes made in one
    /// main-actor turn are coalesced into one sync. Only the store is tracked
    /// (not this object's own values, which the sync reads to compare).
    func track(_ store: GianClientStore) async {
        // One registration can report more than once; the stream keeps at most
        // one pending sync either way.
        let (changes, changed) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        func observe() {
            withObservationTracking {
                _ = store.state
                _ = store.mutationsReady
                _ = store.serviceDiagnostic
                _ = store.serverOutcomeUnconfirmed
                _ = store.authorizationInvalidationUnconfirmed
            } onChange: {
                changed.yield()
            }
            sync(store)
        }
        observe()
        for await _ in changes {
            observe()
        }
    }

    private func sync(_ store: GianClientStore) {
        let state = store.state
        let ready = store.mutationsReady
        assign(\.phase, state.phase)
        assign(\.hosts, StoreProjection.hosts(state))
        assign(\.directory, projectedDirectory(state))
        assign(\.navigation, state.navigation)
        var transcriptWaits = false
        var conversation = StoreProjection.activeConversation(state) { input in
            var shown = input
            if let session = state.conversation?.session.id {
                let visible = pacing.visible(input.items, session: session, interactions: input.interactions)
                transcriptWaits = visible.waiting
                shown = input.showing(visible.items)
            }
            if shown != rowsInput {
                rows = StoreProjection.transcriptRows(shown)
                rowsInput = shown
            }
            return rows
        }
        if transcriptWaits { scheduleRevealStep(store) } else { pacingStep?.cancel(); pacingStep = nil }
        let status = ConversationStatusInputs(session: conversation?.id, connectivity: ConnectivityPresentation(state.connection),
            diagnostic: StoreProjection.diagnostic(store.serviceDiagnostic), transcriptSync: conversation?.transcriptSync ?? .idle)
        if state.foreground == .foreground { settleStatus(status) } else {
            // The background (inactive included) disconnects on purpose and
            // coming back reconnects: rather than come back offline, the title
            // keeps what it showed, taking only changes that apply at once.
            shownStatus = ConversationStatusInputs.next(shown: shownStatus, latest: status).now
            holdStatus()
        }
        conversation?.connectivity = shownStatus.connectivity
        conversation?.transcriptSync = shownStatus.transcriptSync
        assign(\.conversation, conversation)
        assign(\.composer, state.composer)
        assign(\.workspaces, state.workspaces)
        assign(\.agents, state.agents)
        assign(\.openTasks, state.openTasks.map { TaskGroupItem(id: $0.id, title: $0.title, conversations: []) })
        assign(\.mutationsReady, ready)
        assign(\.directoryNegotiated, state.capabilities.directoryNegotiated)
        assign(\.canRetryUncertainCreate, StoreProjection.canRetryUncertainCreate(state, mutationsReady: ready))
        assign(\.diagnostic, shownStatus.diagnostic)
        assign(\.storageError, state.storageError)
        assign(\.serverOutcomeUnconfirmed, store.serverOutcomeUnconfirmed)
        assign(\.invalidationUnconfirmed, store.authorizationInvalidationUnconfirmed)
        assign(\.selectedAgentModels, state.composer.selection.agentID.flatMap { id in
            state.agents.first { $0.id == id }?.models
        } ?? [])
        assign(\.conversationSettings, StoreProjection.conversationSettings(state, mutationsReady: ready))
        assign(\.newChatSettings, StoreProjection.newChatSettings(state, mutationsReady: ready))
        assign(\.serverAddress, state.server?.absoluteString ?? "—")
        assign(\.pairing, PairingState(
            isWaiting: state.pendingPairing != nil,
            didPair: { if case .paired = state.pairingOutcome { true } else { false } }(),
            notice: StoreProjection.pairingNotice(state.pairingOutcome)
        ))
        assign(\.agentLogos, state.agentLogos)
        assign(\.logoTrigger, AgentLogoTrigger(store))
        assign(\.optionsTrigger, AgentOptionsTrigger(store))
        assign(\.restorationHint, RestorationHintSelection(state))
    }

    /// Reveals the next step of the transcript after the pacing interval. Steps
    /// keep coming while anything is waiting.
    private func scheduleRevealStep(_ store: GianClientStore) {
        guard pacingStep == nil else { return }
        pacingStep = Task { [weak self, weak store] in
            try? await Task.sleep(for: TranscriptPacing.interval)
            guard let self, let store, !Task.isCancelled else { return }
            self.pacingStep = nil
            let step = store.state.conversation.map { self.pacing.advance($0.items) } ?? .none
            switch step {
            // A new row settles in.
            case .newRow: withAnimation(.easeOut(duration: 0.25)) { self.sync(store) }
            // A growing message glides through the step's interval, so its
            // steps read as one movement rather than a staircase.
            case .grew: withAnimation(.linear(duration: TranscriptPacing.interval / .seconds(1))) { self.sync(store) }
            // Everything at once (a burst) and nothing new apply as they are.
            case .all, .none: self.sync(store)
            }
        }
    }

    /// The chat title shows a status change once it has lasted
    /// `ConversationStatusInputs.settle`, so a quick sync or reconnect never
    /// flickers in it. Only the title reads these inputs.
    private func settleStatus(_ latest: ConversationStatusInputs) {
        let (now, settling) = ConversationStatusInputs.next(shown: shownStatus, latest: latest)
        shownStatus = now
        guard settling else { holdStatus(); return }
        // Newer details of the status already settling don't restart it.
        let restarts = settlingStatus?.status?.label != latest.status?.label
        settlingStatus = latest
        guard restarts || statusSettle == nil else { return }
        statusSettle?.cancel()
        statusSettle = Task { [weak self] in
            try? await Task.sleep(for: ConversationStatusInputs.settle)
            guard let self, !Task.isCancelled, let settled = self.settlingStatus else { return }
            self.shownStatus = settled
            self.settlingStatus = nil
            self.statusSettle = nil
            if var current = self.conversation, current.id == settled.session {
                current.connectivity = settled.connectivity
                current.transcriptSync = settled.transcriptSync
                self.assign(\.conversation, current)
            }
            self.assign(\.diagnostic, settled.diagnostic)
        }
    }

    private func holdStatus() {
        settlingStatus = nil
        statusSettle?.cancel(); statusSettle = nil
    }

    private func projectedDirectory(_ state: GianClientState) -> DirectoryPresentation {
        let input = DirectoryInput(
            directory: state.directory,
            view: state.navigation.directoryView,
            awaitingUser: state.interactions.filter { $0.phase == .pending }
        )
        guard input != directoryInput else { return directory }
        directoryInput = input
        return StoreProjection.directory(state)
    }

    /// Observers are notified on every assignment, equal or not.
    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppPresentation, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}
