import SwiftUI
import GianCore

/// The composer's ⋯ menu: only options that can change while a conversation
/// runs — Model, Thinking, Fast, Approval and Translate. Repository, Agent and
/// Task are fixed at creation and live in the toolbar instead. Rows are an
/// icon plus the current value (the Agent's logo marks Model), with no
/// headers or explanations, to stay short on the folded Duo. Model, Thinking
/// and Approval open a `ChoiceList` (checkmark at the end of the row; iOS
/// menus can only put it at the start); Fast and Translate show On/Off.
/// Changes apply from the next turn; every selection dispatches through a
/// typed callback.
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

    private enum Setting: String, Identifiable {
        case model, thinking, approval
        var id: String { rawValue }
    }

    @State private var openSetting: Setting?

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
        .popover(item: $openSetting) { setting in
            if let settings { choices(setting, settings) }
        }
    }

    @ViewBuilder
    private func conversationSection(_ settings: ConversationSettingsPresentation) -> some View {
        Section {
            if !settings.models.isEmpty {
                Button { openSetting = .model } label: {
                    Label {
                        Text(label(of: settings.model, in: settings.models) ?? "Model")
                    } icon: {
                        Image(uiImage: AgentLogoArt.menuIcon(
                            for: settings.agent, name: settings.agentName, in: agentLogos, scheme: colorScheme
                        ))
                    }
                }
            }
            if !settings.thinking.isEmpty {
                Button { openSetting = .thinking } label: {
                    Label(label(of: settings.currentThinking, in: settings.thinking) ?? "Default", systemImage: "brain")
                }
            }
            // Fast appears only where the current model offers it.
            if case .available(let isOn) = settings.fast {
                Button { onSetFast(!isOn) } label: {
                    Label("Fast", systemImage: isOn ? "hare.fill" : "hare")
                    Text(isOn ? "On" : "Off")
                }
            }
            if !settings.approval.isEmpty {
                Button { openSetting = .approval } label: {
                    Label(label(of: settings.currentApproval, in: settings.approval) ?? "Approval", systemImage: "checkmark.shield")
                }
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
        let isOn = state.capability == .configured && state.isAutomatic
        return Section {
            Button { onToggleAutomaticTranslation(!isOn) } label: {
                Label("Translate", systemImage: "translate")
                Text(isOn ? "On" : "Off")
            }
            .disabled(state.capability != .configured || !translationEnabled)
        }
    }

    private func label(of value: String?, in choices: [AgentOptionChoice]) -> String? {
        choices.first { $0.value == value }?.label
    }

    private func choices(_ setting: Setting, _ settings: ConversationSettingsPresentation) -> ChoiceList {
        func rows(_ choices: [(String?, String)], selected: String?, onSelect: @escaping (String?) -> Void) -> [ChoiceListRow] {
            choices.enumerated().map { index, choice in
                ChoiceListRow(id: "\(index)", title: choice.1, isSelected: choice.0 == selected) { onSelect(choice.0) }
            }
        }
        switch setting {
        case .model:
            return ChoiceList(header: "Model", rows: rows(settings.models.map { ($0.value, $0.label) },
                                                          selected: settings.model, onSelect: onSelectModel))
        case .thinking:
            return ChoiceList(header: "Thinking", rows: rows([(nil, "Default")] + settings.thinking.map { ($0.value, $0.label) },
                                                             selected: settings.currentThinking, onSelect: onSelectThinking))
        case .approval:
            return ChoiceList(header: "Approval", rows: rows(settings.approval.map { ($0.value, $0.label) },
                                                             selected: settings.currentApproval, onSelect: onSelectApproval))
        }
    }
}
