import SwiftUI

/// A choice among mutually exclusive values with the current one checkmarked.
/// The label is a symbol + title so it works as an iPhone Duo vertical-bar
/// item (a custom icon only belongs in menus); nil choices (e.g. "No task") are allowed. Past `searchableThreshold`
/// choices it opens a searchable list instead of a long menu.
struct ChoiceMenu<ID: Hashable>: View {
    enum TitleStyle {
        /// "Repository": toolbar menus.
        case name
        /// "Ada Large": menu rows, where the icon names the setting and the
        /// title carries the current value (nested rows have no subtitle).
        case value
    }

    let title: String
    var systemImage: String = ""
    /// Replaces the symbol, e.g. the Agent's logo for Model.
    var icon: Image? = nil
    let choices: [(id: ID?, name: String)]
    let selected: ID?
    var titleStyle: TitleStyle = .name
    /// Toolbar use only: menus can't present sheets from inside another menu.
    var searchableThreshold: Int? = nil
    var onSelect: (ID?) -> Void

    @State private var showsPicker = false

    private var selectedName: String? {
        choices.first { $0.id == selected }?.name
    }

    private var usesPicker: Bool {
        searchableThreshold.map { choices.count > $0 } ?? false
    }

    var body: some View {
        Group {
            if usesPicker {
                Button {
                    showsPicker = true
                } label: {
                    label
                }
                .sheet(isPresented: $showsPicker) {
                    ChoicePickerSheet(title: title, choices: choices, selected: selected) { id in
                        showsPicker = false
                        onSelect(id)
                    }
                }
            } else {
                Menu {
                    Section(title) {
                        ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                            Button {
                                onSelect(choice.id)
                            } label: {
                                if choice.id == selected {
                                    Label(choice.name, systemImage: "checkmark")
                                } else {
                                    Text(choice.name)
                                }
                            }
                        }
                    }
                } label: {
                    label
                }
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue(selectedName ?? "None")
    }

    private var labelText: String {
        titleStyle == .value ? selectedName ?? title : title
    }

    @ViewBuilder
    private var label: some View {
        if let icon {
            Label { Text(labelText) } icon: { icon }
        } else {
            Label(labelText, systemImage: systemImage)
        }
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
