import SwiftUI

/// One row of a `ChoiceList`.
struct ChoiceListRow: Identifiable {
    let id: String
    var title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var isSelected = false
    var isEnabled = true
    var action: () -> Void
}

/// A small pop-up list for choosing one value, with the selection's checkmark
/// at the end of its row. iOS 26 menus can only put checkmarks at the start,
/// so choices use this instead. Actions (Refresh, Add Host…) follow a divider.
/// Present it in a popover; it stays a popover on iPhone too.
struct ChoiceList: View {
    var header: String? = nil
    var rows: [ChoiceListRow]
    var actions: [ChoiceListRow] = []

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                Text(header)
                    .font(GianTheme.Typography.caption)
                    .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(rows) { row($0) }
            if !actions.isEmpty {
                Divider().padding(.vertical, 4)
                ForEach(actions) { row($0) }
            }
        }
        .padding(.vertical, 6)
        .frame(minWidth: 220, idealWidth: 260, maxWidth: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .presentationCompactAdaptation(.popover)
    }

    private func row(_ row: ChoiceListRow) -> some View {
        Button {
            dismiss()
            row.action()
        } label: {
            HStack(spacing: 12) {
                if let systemImage = row.systemImage {
                    Image(systemName: systemImage)
                        .frame(width: 22)
                        .foregroundStyle(GianTheme.Colors.label)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .foregroundStyle(GianTheme.Colors.label)
                    if let subtitle = row.subtitle {
                        Text(subtitle)
                            .font(GianTheme.Typography.caption)
                            .foregroundStyle(GianTheme.Colors.secondaryLabel)
                    }
                }
                Spacer(minLength: 16)
                if row.isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(GianTheme.Colors.tint)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: GianTheme.Metrics.minHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!row.isEnabled)
        .opacity(row.isEnabled ? 1 : 0.4)
        .accessibilityAddTraits(row.isSelected ? .isSelected : [])
    }
}

#Preview("Choice list") {
    Color.clear.popover(isPresented: .constant(true)) {
        ChoiceList(header: "Approval", rows: [
            ChoiceListRow(id: "ask", title: "Ask for approval", isSelected: true, action: {}),
            ChoiceListRow(id: "auto", title: "Approve for me", action: {}),
        ], actions: [ChoiceListRow(id: "refresh", title: "Refresh", systemImage: "arrow.clockwise", action: {})])
    }
}
