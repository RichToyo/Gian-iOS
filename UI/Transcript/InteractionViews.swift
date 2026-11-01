import SwiftUI
import GianCore

/// Inline interaction card rendering a contract `InteractionRecord` verbatim:
/// approval, question (with typed inputs), exit-plan and native choice.
/// Actions are exactly the Host-supplied `actions`; inputs map to typed
/// `InteractionValue`s. The UI dispatches `.respondToInteraction` only.
struct InteractionCard: View {
    let record: InteractionRecord
    var onRespond: (ActionID, [String: InteractionValue]) -> Void = { _, _ in }

    /// Collected input values keyed by input id (presentation state only).
    /// Selects store Host option VALUES, never labels.
    @State private var textValues: [String: String] = [:]
    @State private var boolValues: [String: Bool] = [:]
    @State private var listValues: [String: [String]] = [:]

    var body: some View {
        switch record.phase {
        case .resolvedHere:
            resolvedRow("You responded", icon: "checkmark", color: GianTheme.Colors.success)
        case .resolvedElsewhere:
            resolvedRow("Resolved on another device", icon: "checkmark", color: GianTheme.Colors.secondaryLabel)
        case .expired:
            resolvedRow("This request expired", icon: "clock", color: GianTheme.Colors.secondaryLabel)
        case .failed:
            resolvedRow("The response failed to send", icon: "xmark.circle", color: GianTheme.Colors.failure)
        case .uncertain:
            resolvedRow(
                "Response outcome unknown — check the Host before retrying",
                icon: "exclamationmark.triangle",
                color: GianTheme.Colors.warning
            )
        case .pending, .responding:
            card
        }
    }

    private func resolvedRow(_ summary: String, icon: String, color: Color) -> some View {
        HStack(spacing: GianTheme.Metrics.paddingSmall) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(summary)
                .font(GianTheme.Typography.caption)
                .foregroundStyle(GianTheme.Colors.secondaryLabel)
        }
        .padding(GianTheme.Metrics.paddingMedium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GianTheme.Colors.secondaryLabel.opacity(0.1),
            in: RoundedRectangle(
                cornerRadius: GianTheme.Metrics.cornerRadiusMedium,
                style: .continuous
            )
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Pending / responding card

    private var isResponding: Bool { record.phase == .responding }

    private var card: some View {
        VStack(alignment: .leading, spacing: GianTheme.Metrics.paddingMedium) {
            header
            if !record.detail.isEmpty {
                detailView
            }
            if !record.inputs.isEmpty {
                inputsView
            }
            if isResponding {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Sending response…")
                        .font(GianTheme.Typography.caption)
                        .foregroundStyle(GianTheme.Colors.secondaryLabel)
                }
            } else {
                actionsView
            }
        }
        .padding(GianTheme.Metrics.paddingMedium)
        .background(GianTheme.Colors.card)
        .clipShape(RoundedRectangle(
            cornerRadius: GianTheme.Metrics.cornerRadiusMedium,
            style: .continuous
        ))
        .overlay(
            RoundedRectangle(
                cornerRadius: GianTheme.Metrics.cornerRadiusMedium,
                style: .continuous
            )
            .stroke(GianTheme.Colors.separator, lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack(spacing: GianTheme.Metrics.paddingSmall) {
            Image(systemName: headerIcon)
                .foregroundStyle(GianTheme.Colors.warning)
                .frame(width: 32, height: 32)
                .background(
                    GianTheme.Colors.warning.opacity(0.25),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .font(GianTheme.Typography.title)
                    .foregroundStyle(GianTheme.Colors.label)
                if record.risk != .low {
                    Text("\(record.risk.rawValue.capitalized) risk")
                        .font(GianTheme.Typography.badge)
                        .foregroundStyle(record.risk == .high ? GianTheme.Colors.failure : GianTheme.Colors.warning)
                }
            }
        }
    }

    private var headerIcon: String {
        switch record.kind {
        case .approval: "shield.lefthalf.filled"
        case .question: "questionmark.circle"
        case .exitPlanMode: "list.clipboard"
        case .nativeChoice: "list.bullet"
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if record.kind == .exitPlanMode {
            // Plan bodies are markdown.
            MarkdownView(source: record.detail)
                .padding(GianTheme.Metrics.paddingSmall)
                .background(
                    GianTheme.Colors.secondaryLabel.opacity(0.08),
                    in: RoundedRectangle(
                        cornerRadius: GianTheme.Metrics.cornerRadiusSmall,
                        style: .continuous
                    )
                )
        } else {
            Text(record.detail)
                .font(GianTheme.Typography.caption)
                .foregroundStyle(GianTheme.Colors.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Typed inputs. Select inputs render exactly the Host-supplied options;
    /// absent options are unavailable metadata, never invented choices or a
    /// free-text stand-in.
    private var inputsView: some View {
        VStack(alignment: .leading, spacing: GianTheme.Metrics.paddingSmall) {
            ForEach(record.inputs) { input in
                switch input.type {
                case .boolean:
                    Toggle(input.label, isOn: Binding(
                        get: { boolValues[input.id] ?? false },
                        set: { boolValues[input.id] = $0 }
                    ))
                    .font(GianTheme.Typography.caption)
                case .text:
                    labelledField(input, multiline: false)
                case .multilineText:
                    labelledField(input, multiline: true)
                case .singleSelect:
                    if let options = input.options {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(input.label)
                                .font(GianTheme.Typography.caption)
                                .foregroundStyle(GianTheme.Colors.secondaryLabel)
                            Menu {
                                ForEach(options) { option in
                                    Button {
                                        textValues[input.id] = option.value
                                    } label: {
                                        VStack(alignment: .leading) {
                                            Text(option.label)
                                            if let description = option.description {
                                                Text(description)
                                                    .font(.caption)
                                            }
                                        }
                                    }
                                }
                            } label: {
                                pickerLabel(
                                    text: selectedOptionLabel(for: input, options: options)
                                        ?? "Choose…"
                                )
                            }
                        }
                    } else {
                        unavailableOptionsNote(input)
                    }
                case .multiSelect:
                    if let options = input.options {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(input.label)
                                .font(GianTheme.Typography.caption)
                                .foregroundStyle(GianTheme.Colors.secondaryLabel)
                            ForEach(options) { option in
                                let selected = (listValues[input.id] ?? []).contains(option.value)
                                Button {
                                    var current = listValues[input.id] ?? []
                                    if selected {
                                        current.removeAll { $0 == option.value }
                                    } else {
                                        current.append(option.value)
                                    }
                                    listValues[input.id] = current
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selected ? GianTheme.Colors.tint : GianTheme.Colors.secondaryLabel)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(option.label)
                                                .font(GianTheme.Typography.caption)
                                                .foregroundStyle(GianTheme.Colors.label)
                                            if let description = option.description {
                                                Text(description)
                                                    .font(GianTheme.Typography.badge)
                                                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .frame(minHeight: GianTheme.Metrics.minHitTarget)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else {
                        unavailableOptionsNote(input)
                    }
                }
            }
        }
    }

    private func labelledField(_ input: InteractionInput, multiline: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(input.label)
                .font(GianTheme.Typography.caption)
                .foregroundStyle(GianTheme.Colors.secondaryLabel)
            if multiline {
                TextField("Your answer…", text: textBinding(for: input.id), axis: .vertical)
                    .lineLimit(2...6)
                    .font(GianTheme.Typography.body)
                    .padding(GianTheme.Metrics.paddingSmall)
                    .background(
                        GianTheme.Colors.secondaryLabel.opacity(0.1),
                        in: RoundedRectangle(
                            cornerRadius: GianTheme.Metrics.cornerRadiusSmall,
                            style: .continuous
                        )
                    )
            } else {
                TextField("Your answer…", text: textBinding(for: input.id))
                    .font(GianTheme.Typography.body)
                    .padding(GianTheme.Metrics.paddingSmall)
                    .background(
                        GianTheme.Colors.secondaryLabel.opacity(0.1),
                        in: RoundedRectangle(
                            cornerRadius: GianTheme.Metrics.cornerRadiusSmall,
                            style: .continuous
                        )
                    )
            }
        }
    }

    private func pickerLabel(text: String) -> some View {
        HStack {
            Text(text)
                .font(GianTheme.Typography.body)
                .foregroundStyle(GianTheme.Colors.label)
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption)
                .foregroundStyle(GianTheme.Colors.secondaryLabel)
        }
        .padding(GianTheme.Metrics.paddingSmall)
        .frame(minHeight: GianTheme.Metrics.minHitTarget)
        .background(
            GianTheme.Colors.secondaryLabel.opacity(0.1),
            in: RoundedRectangle(
                cornerRadius: GianTheme.Metrics.cornerRadiusSmall,
                style: .continuous
            )
        )
    }

    private func selectedOptionLabel(
        for input: InteractionInput,
        options: [InteractionInputOption]
    ) -> String? {
        guard let value = textValues[input.id] else { return nil }
        return options.first { $0.value == value }?.label ?? value
    }

    private func unavailableOptionsNote(_ input: InteractionInput) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(input.label)
                .font(GianTheme.Typography.caption)
                .foregroundStyle(GianTheme.Colors.secondaryLabel)
            Label("Options unavailable from this Host.", systemImage: "exclamationmark.triangle")
                .font(GianTheme.Typography.caption)
                .foregroundStyle(GianTheme.Colors.warning)
        }
    }

    private var actionsView: some View {
        HStack(spacing: GianTheme.Metrics.paddingSmall) {
            ForEach(record.actions) { action in
                Button(action.label) {
                    onRespond(action.id, collectedValues())
                }
                .buttonStyle(buttonStyle(for: action.tone))
            }
        }
    }

    private func textBinding(for inputID: String) -> Binding<String> {
        Binding(
            get: { textValues[inputID] ?? "" },
            set: { textValues[inputID] = $0 }
        )
    }

    private func collectedValues() -> [String: InteractionValue] {
        var values: [String: InteractionValue] = [:]
        for input in record.inputs {
            switch input.type {
            case .boolean:
                if let value = boolValues[input.id] { values[input.id] = .boolean(value) }
            case .text, .multilineText, .singleSelect:
                if let value = textValues[input.id], !value.isEmpty { values[input.id] = .text(value) }
            case .multiSelect:
                if let value = listValues[input.id], !value.isEmpty {
                    values[input.id] = .list(value)
                }
            }
        }
        return values
    }

    private func buttonStyle(for tone: ActionTone) -> AnyButtonStyle {
        switch tone {
        case .default: AnyButtonStyle(GianPrimaryButtonStyle())
        case .danger: AnyButtonStyle(GianDestructiveButtonStyle())
        }
    }
}

/// Destructive Host action (tone == .danger).
struct GianDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GianTheme.Typography.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: GianTheme.Metrics.minHitTarget)
            .background(
                GianTheme.Colors.failure,
                in: RoundedRectangle(
                    cornerRadius: GianTheme.Metrics.cornerRadiusMedium,
                    style: .continuous
                )
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Type-erased button style for Host-supplied action tones.
struct AnyButtonStyle: ButtonStyle {
    private let _makeBody: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        _makeBody = { configuration in
            AnyView(style.makeBody(configuration: configuration))
        }
    }

    func makeBody(configuration: Configuration) -> AnyView {
        _makeBody(configuration)
    }
}

#Preview("Interactions") {
    VStack(spacing: 16) {
        InteractionCard(record: InteractionRecord(
            id: InteractionID(rawValue: "i1")!,
            revision: "1",
            sessionID: SessionID(rawValue: "s1")!,
            turnID: TurnID(rawValue: "t1")!,
            kind: .approval,
            title: "Approval requested",
            detail: "Run on MacBook Pro: git push origin release/1.4.0",
            risk: .medium,
            actions: [
                InteractionAction(id: ActionID(rawValue: "deny")!, label: "Deny", tone: .danger),
                InteractionAction(id: ActionID(rawValue: "allow-once")!, label: "Allow once", tone: .default),
            ],
            phase: .pending
        ))
        InteractionCard(record: InteractionRecord(
            id: InteractionID(rawValue: "i2")!,
            revision: "1",
            sessionID: SessionID(rawValue: "s1")!,
            turnID: TurnID(rawValue: "t1")!,
            kind: .question,
            title: "Question",
            detail: "Which environment should receive the hotfix?",
            risk: .low,
            actions: [InteractionAction(id: ActionID(rawValue: "submit")!, label: "Submit", tone: .default)],
            inputs: [InteractionInput(id: "env", label: "Environment", type: .text)],
            phase: .pending
        ))
        InteractionCard(record: InteractionRecord(
            id: InteractionID(rawValue: "i3")!,
            revision: "1",
            sessionID: SessionID(rawValue: "s1")!,
            turnID: TurnID(rawValue: "t1")!,
            kind: .approval,
            title: "Approval requested",
            detail: "",
            risk: .low,
            actions: [],
            phase: .resolvedHere
        ))
    }
    .padding()
}
