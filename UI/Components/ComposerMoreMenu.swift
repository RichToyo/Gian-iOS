import SwiftUI
import GianCore

/// The composer's ⋯ menu: only options that can change while a conversation
/// runs — Model, Thinking, Fast, Approval and Translate. Repository, Agent and
/// Task are fixed at creation and live in the toolbar instead. Rows are an
/// icon plus the current value (the Agent's logo marks Model), with no
/// headers or explanations, to stay short on the folded Duo. Changes apply
/// from the next turn; every selection dispatches through a typed callback.
struct ComposerMoreMenu: View {
    @Environment(\.agentLogoImages) private var agentLogos
    @Environment(\.colorScheme) private var colorScheme

    var settings: ConversationSettingsPresentation? = nil
    var translation: SessionTranslationPresentation? = nil
    /// Mirrors the store's mutation gate for the automatic-translation toggle.
    var translationEnabled: Bool = true

    var onSelectModel: (String?) -> Void = { _ in }
    var onSelectThinking: (String?) -> Void = { _ in }
    var onSetFast: (Bool) -> Void = { _ in }
    var onSelectApproval: (String?) -> Void = { _ in }
    var onToggleAutomaticTranslation: (Bool) -> Void = { _ in }

    /// Nothing to offer: the caller hides the ⋯ button.
    var isEmpty: Bool {
        (settings?.isEmpty ?? true) && translation == nil
    }

    var body: some View {
        Menu {
            if let settings, !settings.isEmpty {
                conversationSection(settings)
            }
            if let translation {
                translationSection(translation)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(GianTheme.Colors.label)
                .frame(width: GianTheme.Metrics.minHitTarget, height: GianTheme.Metrics.minHitTarget)
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel("More options")
    }

    @ViewBuilder
    private func conversationSection(_ settings: ConversationSettingsPresentation) -> some View {
        Section {
            if !settings.models.isEmpty {
                ChoiceMenu(
                    title: "Model",
                    icon: Image(uiImage: AgentLogoArt.menuIcon(
                        for: settings.agent, name: settings.agentName, in: agentLogos, scheme: colorScheme
                    )),
                    choices: settings.models.map { (Optional($0.value), $0.label) },
                    selected: settings.model,
                    titleStyle: .value,
                    onSelect: onSelectModel
                )
            }
            if !settings.thinking.isEmpty {
                ChoiceMenu(
                    title: "Thinking", systemImage: "brain",
                    choices: [(String?.none, "Default")] + settings.thinking.map { (Optional($0.value), $0.label) },
                    selected: settings.currentThinking,
                    titleStyle: .value,
                    onSelect: onSelectThinking
                )
            }
            // Fast appears only where the current model offers it.
            if case .available(let isOn) = settings.fast {
                Toggle(isOn: Binding(get: { isOn }, set: onSetFast)) {
                    Label("Fast", systemImage: "hare")
                }
            }
            if !settings.approval.isEmpty {
                ChoiceMenu(
                    title: "Approval", systemImage: "checkmark.shield",
                    choices: settings.approval.map { (Optional($0.value), $0.label) },
                    selected: settings.currentApproval,
                    titleStyle: .value,
                    onSelect: onSelectApproval
                )
            }
            if let notice = settings.notice {
                Text(notice)
            }
        }
        .disabled(!settings.isEnabled)
    }

    /// One row: on/off where the Host has translation set up, grayed out
    /// where it doesn't.
    private func translationSection(_ state: SessionTranslationPresentation) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { state.capability == .configured && state.isAutomatic },
                set: onToggleAutomaticTranslation
            )) {
                Label("Translate", systemImage: "translate")
            }
            .disabled(state.capability != .configured || !translationEnabled)
        }
    }
}
