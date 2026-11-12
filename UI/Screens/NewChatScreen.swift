import SwiftUI
import GianCore

/// Direct-compose new chat: text and attachments compose immediately and the
/// first Send creates the conversation as one recoverable operation — there is
/// no separate Create step. Repository, Agent and Task are fixed once the
/// conversation exists, so they are toolbar menus (on iPhone Duo, in the
/// vertical bar under Close), not composer options; the empty canvas
/// summarizes the choices. The composer's ⋯ holds only options that can
/// change while a conversation runs. A single available Agent or repository
/// is selected automatically; changing Agent resets the model.
///
/// Presented inside a NavigationStack (cover on compact, detail column on
/// wide), so the title, Close and route menus live in system bars.
///
/// Property declaration order is the synthesized memberwise argument order;
/// call sites (AdaptiveRoot) must match it exactly.
struct NewChatScreen: View {
    @Environment(\.globalActionsAtBottom) private var globalActionsAtBottom
    @Environment(\.titlesLeading) private var titlesLeading

    let workspaces: [WorkspaceRecord]
    let agents: [AgentRecord]
    /// Open tasks only — the legacy Host requires one for creation.
    let openTasks: [TaskGroupItem]
    let composer: ComposerProjection
    var translation: SessionTranslationPresentation? = nil
    /// Model catalog of the currently selected Agent; empty means the Host
    /// provides none and no model picker renders.
    var selectedAgentModels: [AgentModelRecord] = []
    /// Authoritative mutation gate from the store; send/pick disable until
    /// ready while the draft stays editable.
    var mutationsReady: Bool = true
    /// Explicit Host negotiation is required only for taskless first send.
    var directoryNegotiated: Bool = false
    /// Exact uncertain-create eligibility projected from Core state.
    var canRetryUncertainCreate: Bool = false
    var thumbnail: (AttachmentID) -> Image? = { _ in nil }

    var onSelectWorkspace: (WorkspaceID) -> Void = { _ in }
    var onSelectAgent: (AgentID) -> Void = { _ in }
    var onSelectModel: (String?) -> Void = { _ in }
    var onSelectTask: (TaskID?) -> Void = { _ in }
    var onEditDraft: (String) -> Void = { _ in }
    var onSend: () -> Void = {}
    var onRetryTranslationSend: () -> Void = {}
    var onSendOriginal: () -> Void = {}
    var onCancelTranslationSend: () -> Void = {}
    var onRecoverUncertain: () -> Void = {}
    var onRetryUncertainCreate: () -> Void = {}
    var onRemoveAttachment: (AttachmentID) -> Void = { _ in }
    var onRetryAttachmentUpload: (AttachmentID) -> Void = { _ in }
    var onToggleAutomaticTranslation: (Bool) -> Void = { _ in }
    var onClose: () -> Void = {}
    var attachmentPicker: AttachmentPickerButton
    /// Options for the composer's ⋯ (model, thinking, fast, approval).
    var settings: ConversationSettingsPresentation? = nil
    var onSelectThinking: (String?) -> Void = { _ in }
    var onSetFast: (Bool) -> Void = { _ in }
    var onSelectApproval: (String?) -> Void = { _ in }
    /// Reads the selected Agent's `catalog.agent` options.
    var onLoadOptions: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    /// The Host the conversation will be created on, shown under the title.
    var host: HostItem? = nil

    var body: some View {
        routeSummary
            .frame(maxWidth: GianTheme.Metrics.formWidth)
            .padding(GianTheme.Metrics.paddingLarge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaBar(edge: .bottom) {
                composerArea
            }
            .background(GianTheme.Colors.background)
            .navigationTitle("New chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", action: onClose)
                        .accessibilityLabel("Close")
                }
                ScreenTitleItem(leading: titlesLeading) {
                    HostScopedTitle(title: "New chat", host: host, keepsWholeTitle: true)
                }
                GlobalToolbarActions(showsNewChat: false, atBottom: globalActionsAtBottom, onNewChat: {}, onSettings: onOpenSettings)
                if !globalActionsAtBottom {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
                // Task first: it decides what the conversation is for and is
                // the one the Host may require. Kept visible longest when the
                // vertical bar runs out of room (e.g. with the keyboard up).
                ToolbarItem(placement: .topBarTrailing) {
                    ChoiceMenu(
                        title: "Task", systemImage: "checklist",
                        choices: [(TaskID?.none, "No task")] + openTasks.map { (Optional($0.id), $0.title) },
                        selected: composer.selection.taskID,
                        searchableThreshold: 10,
                        onSelect: onSelectTask
                    )
                }
                .highVisibilityPriority()
                ToolbarItem(placement: .topBarTrailing) {
                    ChoiceMenu(
                        title: "Repository", systemImage: "folder",
                        choices: workspaces.map { (Optional($0.id), $0.name) },
                        selected: composer.selection.workspaceID,
                        searchableThreshold: 10,
                        onSelect: { if let id = $0 { onSelectWorkspace(id) } }
                    )
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ChoiceMenu(
                        title: "Agent", systemImage: "cpu",
                        choices: agents.map { (Optional($0.id), $0.name) },
                        selected: composer.selection.agentID,
                        searchableThreshold: 10,
                        onSelect: { if let id = $0 { onSelectAgent(id) } }
                    )
                }
            }
            .onAppear(perform: selectSingleOptions)
            .task(id: composer.selection.agentID) { onLoadOptions() }
    }

    private var requiresTask: Bool {
        composer.selection.taskID == nil && !directoryNegotiated
    }

    /// Who the message goes to and where, as chosen in the toolbar menus.
    private var routeSummary: some View {
        VStack(spacing: GianTheme.Metrics.paddingMedium) {
            if let agent = selectedAgent {
                AgentAvatar(
                    logo: AgentLogo(pluginID: agent.pluginID, agentName: agent.name),
                    name: agent.name,
                    size: GianTheme.Metrics.avatarLarge
                )
                Text("New chat with \(agent.name)")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(GianTheme.Colors.label)
            } else {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.largeTitle)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                Text("New chat")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(GianTheme.Colors.label)
            }

            Text(routeDetail)
                .font(GianTheme.Typography.caption)
                .foregroundStyle(GianTheme.Colors.secondaryLabel)

            if requiresTask {
                Label("Choose an open task before the first message.", systemImage: "checklist")
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
    }

    private var routeDetail: String {
        let parts = [selectedTaskTitle, selectedWorkspaceName].compactMap { $0 }
        if parts.isEmpty { return "Choose a task and repository." }
        return parts.joined(separator: " · ")
    }

    private var composerArea: some View {
        ComposerView(
            draft: Binding(
                get: { composer.draft.text },
                set: onEditDraft
            ),
            attachments: composer.draft.attachments,
            sendPhase: SendPhasePresentation(composer.send),
            notice: ComposerNoticePresentation(composer.notice),
            remoteReady: StoreProjection.newChatRemoteReady(
                taskID: composer.selection.taskID,
                directoryNegotiated: directoryNegotiated,
                mutationsReady: mutationsReady
            ),
            thumbnail: thumbnail,
            canRetryUncertainCreate: canRetryUncertainCreate,
            moreMenu: ComposerMoreMenu(
                settings: settings,
                translation: translation,
                translationEnabled: mutationsReady,
                onSelectModel: onSelectModel,
                onSelectThinking: onSelectThinking,
                onSetFast: onSetFast,
                onSelectApproval: onSelectApproval,
                onToggleAutomaticTranslation: onToggleAutomaticTranslation
            ),
            onSend: onSend,
            onRetryTranslationSend: onRetryTranslationSend,
            onSendOriginal: onSendOriginal,
            onCancelTranslation: onCancelTranslationSend,
            onRecoverUncertain: onRecoverUncertain,
            onRetryUncertainCreate: onRetryUncertainCreate,
            onRemoveAttachment: onRemoveAttachment,
            onRetryAttachmentUpload: onRetryAttachmentUpload,
            attachmentPicker: attachmentPicker
        )
        .frame(maxWidth: GianTheme.Metrics.readableWidth)
        .padding(.horizontal, GianTheme.Metrics.paddingMedium)
        .padding(.bottom, GianTheme.Metrics.paddingSmall)
        .frame(maxWidth: .infinity)
    }

    /// With exactly one choice there is nothing to decide.
    private func selectSingleOptions() {
        if composer.selection.agentID == nil, agents.count == 1 {
            onSelectAgent(agents[0].id)
        }
        if composer.selection.workspaceID == nil, workspaces.count == 1 {
            onSelectWorkspace(workspaces[0].id)
        }
    }

    private var selectedAgent: AgentRecord? {
        guard let id = composer.selection.agentID else { return nil }
        return agents.first { $0.id == id }
    }

    private var selectedWorkspaceName: String? {
        guard let id = composer.selection.workspaceID else { return nil }
        return workspaces.first { $0.id == id }?.name
    }

    private var selectedTaskTitle: String? {
        guard let id = composer.selection.taskID else { return nil }
        return openTasks.first { $0.id == id }?.title
    }

    private var selectedModelLabel: String? {
        guard let model = composer.selection.model else { return nil }
        return selectedAgentModels.first { $0.id == model }?.label ?? model
    }
}
