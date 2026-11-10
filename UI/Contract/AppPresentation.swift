import Foundation
import Observation
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
    @ObservationIgnored private var directoryInput: DirectoryInput?

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
        assign(\.conversation, StoreProjection.activeConversation(state) { input in
            if input != rowsInput {
                rows = StoreProjection.transcriptRows(input)
                rowsInput = input
            }
            return rows
        })
        assign(\.composer, state.composer)
        assign(\.workspaces, state.workspaces)
        assign(\.agents, state.agents)
        assign(\.openTasks, state.openTasks.map { TaskGroupItem(id: $0.id, title: $0.title, conversations: []) })
        assign(\.mutationsReady, ready)
        assign(\.directoryNegotiated, state.capabilities.directoryNegotiated)
        assign(\.canRetryUncertainCreate, StoreProjection.canRetryUncertainCreate(state, mutationsReady: ready))
        assign(\.diagnostic, StoreProjection.diagnostic(store.serviceDiagnostic))
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
