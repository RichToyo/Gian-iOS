import SwiftUI
import GianCore

/// Direct-compose new chat: text and attachments compose immediately and the
/// first Send creates the conversation as one recoverable operation — there is
/// no separate Create step. Agent, workspace, task and model pickers sit
/// nearby and dispatch selection actions. The model picker lists only the
/// selected Agent's actual Host catalog; changing Agent resets the model.
///
/// Property declaration order is the synthesized memberwise argument order;
/// call sites (AdaptiveRoot) must match it exactly.
struct NewChatScreen: View {
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

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 0)
            pickers
            if composer.selection.taskID == nil && !directoryNegotiated {
                Label("This Host requires an open task for the first send.", systemImage: "checklist")
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, GianTheme.Metrics.paddingMedium)
                    .padding(.bottom, GianTheme.Metrics.paddingSmall)
            }
            if let translation {
                TranslationToggle(state: translation, onToggleAutomatic: onToggleAutomaticTranslation)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, GianTheme.Metrics.paddingMedium)
                    .padding(.bottom, 4)
            }
            ComposerView(
                draft: Binding(
                    get: { composer.draft.text },
                    set: onEditDraft
                ),
                attachments: composer.draft.attachments,
                sendPhase: SendPhasePresentation(composer.send),
                notice: ComposerNoticePresentation(composer.notice),
                placeholder: "Message…",
                remoteReady: StoreProjection.newChatRemoteReady(
                    taskID: composer.selection.taskID,
                    directoryNegotiated: directoryNegotiated,
                    mutationsReady: mutationsReady
                ),
                thumbnail: thumbnail,
                canRetryUncertainCreate: canRetryUncertainCreate,
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
            .padding(.horizontal, GianTheme.Metrics.paddingMedium)
            .padding(.bottom, GianTheme.Metrics.paddingSmall)
        }
        .background(GianTheme.Colors.background)
    }

    private var header: some View {
        HStack {
            Text("New chat")
                .font(GianTheme.Typography.navTitle)
                .foregroundStyle(GianTheme.Colors.label)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.body.weight(.medium))
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    .gianHitTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, GianTheme.Metrics.paddingLarge)
        .padding(.vertical, GianTheme.Metrics.paddingSmall)
    }

    /// Nearby workspace / Agent / task selection as compact menus.
    private var pickers: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: GianTheme.Metrics.paddingSmall) {
                Menu {
                    ForEach(workspaces) { workspace in
                        Button(workspace.name) { onSelectWorkspace(workspace.id) }
                    }
                } label: {
                    pickerChip(
                        icon: "folder",
                        label: selectedWorkspaceName ?? "Repository"
                    )
                }

                Menu {
                    ForEach(agents) { agent in
                        Button(agent.name) { onSelectAgent(agent.id) }
                    }
                } label: {
                    pickerChip(icon: "cpu", label: selectedAgentName ?? "Agent")
                }

                Menu {
                    Button("No task") { onSelectTask(nil) }
                    ForEach(openTasks) { task in
                        Button(task.title) { onSelectTask(task.id) }
                    }
                } label: {
                    pickerChip(icon: "checklist", label: selectedTaskTitle ?? "Task")
                }
                if !selectedAgentModels.isEmpty {
                    Menu {
                        Button("Default model") { onSelectModel(nil) }
                        ForEach(selectedAgentModels) { model in
                            Button(model.isDefault ? "\(model.label) (default)" : model.label) {
                                onSelectModel(model.id)
                            }
                        }
                    } label: {
                        pickerChip(icon: "sparkles", label: selectedModelLabel ?? "Model")
                    }
                }
            }
            .padding(.horizontal, GianTheme.Metrics.paddingMedium)
        }
        .padding(.bottom, GianTheme.Metrics.paddingSmall)
    }

    private var selectedWorkspaceName: String? {
        guard let id = composer.selection.workspaceID else { return nil }
        return workspaces.first { $0.id == id }?.name
    }

    private var selectedAgentName: String? {
        guard let id = composer.selection.agentID else { return nil }
        return agents.first { $0.id == id }?.name
    }

    private var selectedTaskTitle: String? {
        guard let id = composer.selection.taskID else { return nil }
        return openTasks.first { $0.id == id }?.title
    }

    private var selectedModelLabel: String? {
        guard let model = composer.selection.model else { return nil }
        return selectedAgentModels.first { $0.id == model }?.label ?? model
    }

    private func pickerChip(icon: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
            Text(label)
                .font(GianTheme.Typography.caption.weight(.medium))
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8))
        }
        .foregroundStyle(GianTheme.Colors.label)
        .padding(.horizontal, GianTheme.Metrics.paddingMedium)
        .frame(minHeight: 36)
        .background(GianTheme.Colors.card, in: Capsule())
        .overlay(Capsule().stroke(GianTheme.Colors.separator, lineWidth: 0.5))
    }
}
