import SwiftUI
import GianCore

/// The composer's ⋯ menu: only options that can change while a conversation
/// runs — Model, Thinking, Fast, Approval and Translate. Repository, Agent and
/// Task are fixed at creation and live in the toolbar instead. Rows are an
/// icon plus the current value (the Agent's logo marks Model), with no
/// headers or explanations, to stay short on the folded Duo. Model, Thinking
/// and Approval open a `ChoiceList` (checkmark at the end of the row; iOS
/// menus can only put it at the start); Fast and Translate use switches.
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
    @State private var showsMenu = false

    /// Nothing to offer: the caller hides the ⋯ button.
    var isEmpty: Bool {
        (settings?.isEmpty ?? true) && translation == nil
    }

    var body: some View {
        Button { showsMenu = true } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(GianTheme.Colors.label)
                .frame(width: GianTheme.Metrics.minHitTarget, height: GianTheme.Metrics.minHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More options")
        .popover(isPresented: $showsMenu) {
            if let setting = openSetting, let settings {
                choices(setting, settings)
            } else {
                options
            }
        }
        .onChange(of: showsMenu) { _, shown in if !shown { openSetting = nil } }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let settings, !settings.isEmpty { conversationSection(settings) }
            if let translation {
                if let settings, !settings.isEmpty { Divider().padding(.vertical, 4) }
                translationSection(translation)
            }
        }
        .padding(.vertical, 6)
        .frame(minWidth: 220, idealWidth: 260, maxWidth: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .presentationCompactAdaptation(.popover)
    }

    @ViewBuilder
    private func conversationSection(_ settings: ConversationSettingsPresentation) -> some View {
        Group {
            if !settings.models.isEmpty {
                optionButton(action: { openSetting = .model }) {
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
                optionButton(action: { openSetting = .thinking }) {
                    Label(label(of: settings.currentThinking, in: settings.thinking) ?? "Default", systemImage: "brain")
                }
            }
            // Fast appears only where the current model offers it.
            if case .available(let isOn) = settings.fast {
                Toggle(isOn: Binding(get: { isOn }, set: { if $0 != isOn { onSetFast($0) } })) {
                    Label("Fast", systemImage: "hare")
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 16)
                .frame(minHeight: GianTheme.Metrics.minHitTarget)
            }
            if !settings.approval.isEmpty {
                if !settings.models.isEmpty || !settings.thinking.isEmpty || settings.showsFast {
                    Divider().padding(.vertical, 4)
                }
                optionButton(action: { openSetting = .approval }) {
                    Label(label(of: settings.currentApproval, in: settings.approval) ?? "Approval", systemImage: "checkmark.shield")
                }
            }
            if let notice = settings.notice {
                Text(notice)
                    .font(GianTheme.Typography.caption)
                    .padding(.horizontal, 16)
            }
        }
        .disabled(!settings.isEnabled)
    }

    private func translationSection(_ state: SessionTranslationPresentation) -> some View {
        let isOn = state.capability == .configured && state.isAutomatic
        return Toggle(isOn: Binding(get: { isOn }, set: { if $0 != isOn { onToggleAutomaticTranslation($0) } })) {
                Label("Translate", systemImage: "translate")
        }
        .toggleStyle(.switch)
        .padding(.horizontal, 16)
        .frame(minHeight: GianTheme.Metrics.minHitTarget)
        .disabled(state.capability != .configured || !translationEnabled)
    }

    private func optionButton<LabelContent: View>(action: @escaping () -> Void,
                                                   @ViewBuilder label: () -> LabelContent) -> some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, minHeight: GianTheme.Metrics.minHitTarget, alignment: .leading)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
