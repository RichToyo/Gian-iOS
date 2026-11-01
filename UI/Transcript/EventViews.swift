import SwiftUI
import GianCore

/// Collapsed/expanded execution details for one turn. Terminal labels always
/// match the turn: "Working" while active, then "Worked"/"Failed"/"Stopped".
/// A failed turn keeps its failing step expanded; nothing retries implicitly.
struct WorkCardView: View {
    let card: WorkCard
    @State private var isExpanded: Bool

    init(card: WorkCard) {
        self.card = card
        // Failures stay expanded; ordinary details collapse.
        _isExpanded = State(initialValue: card.phase == .failed)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                Divider().overlay(GianTheme.Colors.separator)
                VStack(spacing: 0) {
                    ForEach(card.events) { event in
                        WorkEventRow(event: event)
                        if event.id != card.events.last?.id {
                            Divider().overlay(GianTheme.Colors.separator)
                        }
                    }
                }
            }
        }
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
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: GianTheme.Metrics.paddingSmall) {
                headerIcon
                Text(headerLabel)
                    .font(GianTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(headerColor)
                Text("· \(card.events.count) step\(card.events.count == 1 ? "" : "s")")
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
            }
            .padding(.horizontal, GianTheme.Metrics.paddingMedium)
            .frame(minHeight: GianTheme.Metrics.minHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(isExpanded ? "Collapse details" : "Expand details")
    }

    private var headerLabel: String {
        switch card.phase {
        case .working: "Working"
        case .worked: "Worked"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }

    private var headerColor: Color {
        switch card.phase {
        case .working: GianTheme.Colors.tint
        case .worked: GianTheme.Colors.success
        case .failed, .stopped: GianTheme.Colors.failure
        }
    }

    @ViewBuilder
    private var headerIcon: some View {
        switch card.phase {
        case .working:
            ProgressView().controlSize(.mini)
        case .worked:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(GianTheme.Colors.success)
        case .failed, .stopped:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(GianTheme.Colors.failure)
        }
    }
}

/// One execution event row: command, file change/read/search, web search,
/// tool, subagent — with its outcome on the trailing edge.
struct WorkEventRow: View {
    let event: WorkEventItem

    var body: some View {
        HStack(spacing: GianTheme.Metrics.paddingSmall) {
            Image(systemName: iconName)
                .font(.callout)
                .foregroundStyle(GianTheme.Colors.secondaryLabel)
                .frame(width: 20)
            Text(event.title)
                .font(GianTheme.Typography.code)
                .foregroundStyle(GianTheme.Colors.label)
                .lineLimit(1)
            Spacer(minLength: 0)
            statusLabel
        }
        .padding(.horizontal, GianTheme.Metrics.paddingMedium)
        .padding(.vertical, GianTheme.Metrics.paddingSmall)
        .accessibilityElement(children: .combine)
    }

    private var iconName: String {
        switch event.kind {
        case .command: "terminal"
        case .fileChange: "doc.badge.gearshape"
        case .fileRead: "doc.text"
        case .fileSearch: "magnifyingglass"
        case .webSearch: "globe"
        case .tool: "wrench.and.screwdriver"
        case .subagent: "person.2"
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch event.outcome {
        case .running:
            ProgressView().controlSize(.mini)
        case .done:
            Text(event.statusText.isEmpty ? "Done" : event.statusText)
                .font(GianTheme.Typography.caption)
                .foregroundStyle(GianTheme.Colors.success)
        case .failed:
            Text(event.statusText.isEmpty ? "Failed" : event.statusText)
                .font(GianTheme.Typography.caption)
                .foregroundStyle(GianTheme.Colors.failure)
        }
    }
}

/// Terminal turn outcome row for non-clean endings ("Failed" / "Stopped") and
/// severe errors. Worked turns render no extra row — the transcript speaks.
struct TurnOutcomeRow: View {
    let outcome: TurnOutcomePresentation

    var body: some View {
        HStack(alignment: .top, spacing: GianTheme.Metrics.paddingSmall) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(GianTheme.Typography.caption)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(GianTheme.Metrics.paddingMedium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            color.opacity(0.1),
            in: RoundedRectangle(
                cornerRadius: GianTheme.Metrics.cornerRadiusMedium,
                style: .continuous
            )
        )
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch outcome {
        case .failed, .severeError: "exclamationmark.circle.fill"
        case .stopped: "stop.circle.fill"
        }
    }

    private var color: Color {
        GianTheme.Colors.failure
    }

    private var text: String {
        switch outcome {
        case .failed:
            "Turn ended · Failed. The failing step stays expanded above; nothing was retried automatically."
        case .stopped:
            "Turn ended · Stopped."
        case .severeError:
            "A severe error occurred in this turn."
        }
    }
}

enum TurnOutcomePresentation: Equatable, Sendable {
    case failed
    case stopped
    case severeError
}

#Preview("Turn work") {
    VStack(spacing: 16) {
        WorkCardView(card: WorkCard(
            id: TurnID(rawValue: "turn-1")!,
            phase: .failed,
            events: [
                WorkEventItem(id: TranscriptItemID(rawValue: "e1")!, kind: .command,
                              title: "Command", outcome: .failed, statusText: "exit 1"),
                WorkEventItem(id: TranscriptItemID(rawValue: "e2")!, kind: .fileSearch,
                              title: "File search · grep", outcome: .done, statusText: "3 matches"),
                WorkEventItem(id: TranscriptItemID(rawValue: "e3")!, kind: .webSearch,
                              title: "Web search", outcome: .done, statusText: "5 results"),
                WorkEventItem(id: TranscriptItemID(rawValue: "e4")!, kind: .subagent,
                              title: "Explore agent", outcome: .done, statusText: "Done"),
            ]
        ))
        TurnOutcomeRow(outcome: .failed)
    }
    .padding()
}
