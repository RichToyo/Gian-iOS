import SwiftUI
import GianCore

/// Collapsed/expanded execution details for one turn. Terminal labels always
/// match the turn: "Working" while active, then "Worked"/"Failed"/"Stopped".
/// A failed turn keeps its failing step expanded; nothing retries implicitly.
struct WorkCardView: View {
    let card: WorkCard
    @State private var isExpanded: Bool
    @State private var followsLatest = true
    @State private var nearBottom = true
    @State private var userScrolling = false

    init(card: WorkCard) {
        self.card = card
        _isExpanded = State(initialValue: card.phase == .failed)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                Divider().overlay(GianTheme.Colors.separator)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(card.events) { event in
                                WorkEventRow(event: event).id(event.id)
                                if event.id != card.events.last?.id {
                                    Divider().overlay(GianTheme.Colors.separator)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.contentSize.height - geometry.visibleRect.maxY <= 40
                    } action: { _, value in
                        nearBottom = value
                        if userScrolling { followsLatest = value }
                    }
                    .onScrollPhaseChange { _, phase in
                        switch phase {
                        case .tracking, .interacting, .decelerating: userScrolling = true
                        case .idle:
                            if userScrolling { followsLatest = nearBottom }
                            userScrolling = false
                        default: break
                        }
                    }
                    .onChange(of: card.events.count) { _, _ in
                        if followsLatest, !userScrolling, let last = card.events.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
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
                elapsedLabel
                Text("· \(card.events.count) step\(card.events.count == 1 ? "" : "s")")
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    .lineLimit(1)
                if card.events.contains(where: { $0.kind == .warning }) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(GianTheme.Colors.warning)
                        .accessibilityLabel("Contains a guardian warning")
                }
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
        // Working → Worked/Failed cross-fades instead of snapping.
        .animation(.easeInOut(duration: 0.2), value: card.phase)
        .accessibilityHint(isExpanded ? "Collapse details" : "Expand details")
    }

    private var headerLabel: String {
        switch card.phase {
        case .working: "Working"
        case .worked: "Worked"
        case .failed: "Failed"
        case .stopped: "Stopped"
        case .unknown: "Activity"
        }
    }

    private var headerColor: Color {
        switch card.phase {
        case .working: GianTheme.Colors.tint
        case .worked: GianTheme.Colors.success
        case .failed, .stopped: GianTheme.Colors.failure
        case .unknown: GianTheme.Colors.secondaryLabel
        }
    }

    @ViewBuilder
    private var elapsedLabel: some View {
        if let started = card.startedAt {
            if card.phase == .working {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.elapsed(from: started, to: context.date))
                        .font(GianTheme.Typography.caption)
                        .foregroundStyle(GianTheme.Colors.secondaryLabel)
                }
            } else if let finished = card.finishedAt {
                Text(Self.elapsed(from: started, to: finished))
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
            }
        }
    }

    private static func elapsed(from start: Date, to end: Date) -> String {
        let interval = end.timeIntervalSince(start)
        let seconds = interval.isFinite ? Int(max(0, min(interval, 359_999))) : 0
        if seconds >= 3_600 { return String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
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
        case .unknown:
            Image(systemName: "info.circle")
                .foregroundStyle(GianTheme.Colors.secondaryLabel)
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
        case .warning: "exclamationmark.triangle"
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
                .foregroundStyle(event.kind == .warning ? GianTheme.Colors.warning : GianTheme.Colors.success)
        case .failed:
            Text(event.statusText.isEmpty ? "Failed" : event.statusText)
                .font(GianTheme.Typography.caption)
                .foregroundStyle(GianTheme.Colors.failure)
        case .unknown:
            Text(event.statusText.isEmpty ? "Status unavailable" : event.statusText)
                .font(GianTheme.Typography.caption)
                .foregroundStyle(GianTheme.Colors.secondaryLabel)
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

extension WorkCardView: Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.card == rhs.card }
}
