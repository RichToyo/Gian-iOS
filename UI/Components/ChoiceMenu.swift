import SwiftUI

/// A choice among mutually exclusive values, for the New chat bar (Task,
/// Repository, Agent). The label is a symbol + title so it works as an iPhone
/// Duo vertical-bar item. Tapping opens a `ChoiceList` (the selection's
/// checkmark at the end of its row); past `searchableThreshold` choices, a
/// searchable sheet instead. Nil choices (e.g. "No task") are allowed.
struct ChoiceMenu<ID: Hashable>: View {
    let title: String
    let systemImage: String
    let choices: [(id: ID?, name: String)]
    let selected: ID?
    var searchableThreshold: Int? = nil
    var onSelect: (ID?) -> Void

    @State private var showsList = false
    @State private var showsPicker = false

    private var selectedName: String? {
        choices.first { $0.id == selected }?.name
    }

    private var usesPicker: Bool {
        searchableThreshold.map { choices.count > $0 } ?? false
    }

    var body: some View {
        Button {
            if usesPicker { showsPicker = true } else { showsList = true }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .popover(isPresented: $showsList) {
            ChoiceList(header: title, rows: choices.enumerated().map { index, choice in
                ChoiceListRow(id: "\(index)", title: choice.name, isSelected: choice.id == selected) { onSelect(choice.id) }
            })
        }
        .sheet(isPresented: $showsPicker) {
            ChoicePickerSheet(title: title, choices: choices, selected: selected) { id in
                showsPicker = false
                onSelect(id)
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue(selectedName ?? "None")
    }
}

/// Searchable list for long choice sets (many tasks or repositories).
private struct ChoicePickerSheet<ID: Hashable>: View {
    let title: String
    let choices: [(id: ID?, name: String)]
    let selected: ID?
    var onSelect: (ID?) -> Void

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [(offset: Int, element: (id: ID?, name: String))] {
        let all = Array(choices.enumerated())
        guard !query.isEmpty else { return all }
        return all.filter { $0.element.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(filtered, id: \.offset) { _, choice in
                Button {
                    onSelect(choice.id)
                } label: {
                    HStack {
                        Text(choice.name)
                            .foregroundStyle(GianTheme.Colors.label)
                        Spacer()
                        if choice.id == selected {
                            Image(systemName: "checkmark")
                                .foregroundStyle(GianTheme.Colors.tint)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }
}
