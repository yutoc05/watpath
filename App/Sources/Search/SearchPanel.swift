import CampusModel
import MapKit
import SwiftUI

/// The top search field shown while browsing the map.
struct SearchField: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Search campus", systemImage: "magnifyingglass")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .frame(height: 50)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel("Search")
    }
}

/// Full-screen search: Recents and Popular when empty, then campus results
/// (our own index) followed by Apple's results for everything else.
struct SearchPanel: View {
    let model: AppModel
    @State private var query = ""
    @State private var completer: LocalSearchCompleter
    @FocusState private var isFieldFocused: Bool

    init(model: AppModel) {
        self.model = model
        _completer = State(initialValue: LocalSearchCompleter(around: model.campus.origin))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search campus", text: $query)
                        .accessibilityIdentifier("searchText")
                        .focused($isFieldFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .onSubmit(selectTopResult)
                    if !query.isEmpty {
                        Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .glassEffect(.regular, in: .capsule)

                Button("Cancel") { model.endSearch() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            List {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    emptyQuerySections
                } else {
                    resultSections
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
        }
        .background(.regularMaterial)
        .onAppear { isFieldFocused = true }
        .onChange(of: query) { completer.update(query: query) }
    }

    @ViewBuilder
    private var emptyQuerySections: some View {
        Section {
            Button {
                model.beginPickingLocation()
            } label: {
                PlaceRow(title: "Choose location on map", subtitle: "Move the map to place a pin", systemImage: "mappin.and.ellipse")
            }
            Button {
                model.beginPickingLocation(insidePath: true)
            } label: {
                PlaceRow(title: "Choose location inside the path", subtitle: "Place a pin inside a building", systemImage: "building.2.crop.circle")
            }
        }
        if !model.recents.items.isEmpty {
            Section {
                ForEach(model.recents.items, id: \.self) { place in
                    placeButton(place)
                }
            } header: {
                HStack {
                    Text("Recents")
                    Spacer()
                    Button("Clear") { model.clearRecents() }
                        .font(.subheadline)
                        .textCase(nil)
                }
            }
        }
        Section("Popular Locations") {
            ForEach(model.campus.popular, id: \.self) { reference in
                placeButton(.campus(reference))
            }
        }
    }

    @ViewBuilder
    private var resultSections: some View {
        let campusResults = model.searchIndex.search(query)
        if !campusResults.isEmpty {
            Section("On Campus") {
                ForEach(campusResults, id: \.place) { result in
                    placeButton(.campus(result.place))
                }
            }
        }
        if !completer.results.isEmpty {
            Section("Other Places") {
                ForEach(completer.results, id: \.self) { completion in
                    Button {
                        Task {
                            if let item = await completer.resolve(completion) {
                                model.select(.mapItem(item), focus: true, remember: true)
                            }
                        }
                    } label: {
                        PlaceRow(title: completion.title, subtitle: completion.subtitle, systemImage: "mappin")
                    }
                }
            }
        }
        if campusResults.isEmpty && completer.results.isEmpty {
            ContentUnavailableView.search(text: query)
                .listRowBackground(Color.clear)
        }
    }

    private func placeButton(_ place: Place) -> some View {
        Button {
            model.select(place, focus: true, remember: true)
        } label: {
            if let summary = place.summary(in: model.campus) {
                PlaceRow(title: summary.title, subtitle: summary.subtitle, systemImage: summary.systemImage)
            }
        }
    }

    private func selectTopResult() {
        if let top = model.searchIndex.search(query, limit: 1).first {
            model.select(.campus(top.place), focus: true, remember: true)
        }
    }
}

struct PlaceRow: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.tint, in: .circle)
            // Color.primary rather than .primary: inside a List button, the hierarchical
            // styles resolve against the tint and the text would turn blue.
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Color.primary)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline).foregroundStyle(Color.secondary)
                }
            }
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
