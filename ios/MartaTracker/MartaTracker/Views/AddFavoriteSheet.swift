import SwiftUI

/// Add a favorite: pick a rail station (from the live feed) or search bus stops
/// (from the bundled GTFS catalog).
struct AddFavoriteSheet: View {
    @EnvironmentObject private var service: MartaService
    @EnvironmentObject private var favorites: FavoritesStore
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable { case railStation = "Train station", busStop = "Bus stop" }
    @State private var mode: Mode = .railStation
    @State private var query = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Type", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()

                List(results, id: \.code) { item in
                    Button {
                        toggle(item)
                    } label: {
                        HStack {
                            Label(item.name, systemImage: item.kind.systemImage)
                                .foregroundStyle(.primary)
                            Spacer()
                            if favorites.isFavorited(code: item.code, kind: item.kind) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                            } else {
                                Image(systemName: "plus.circle").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if results.isEmpty {
                        ContentUnavailableView(
                            mode == .busStop && query.isEmpty ? "Search bus stops" : "No matches",
                            systemImage: "magnifyingglass",
                            description: Text(mode == .busStop
                                ? "Type part of a stop name."
                                : "No stations in the feed right now.")
                        )
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: mode == .railStation ? "Filter stations" : "Search bus stops")
            .navigationTitle("Add Favorite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private struct Item { let kind: FavoriteKind; let code: String; let name: String }

    private var results: [Item] {
        switch mode {
        case .railStation:
            let names = service.stationNames
            let filtered = query.isEmpty ? names : names.filter { $0.searchMatches(query) }
            return filtered.map { Item(kind: .railStation, code: $0, name: $0.capitalized) }
        case .busStop:
            return StopCatalog.shared.search(query).map {
                Item(kind: .busStop, code: $0.id, name: $0.name)
            }
        }
    }

    private func toggle(_ item: Item) {
        favorites.toggle(Favorite(kind: item.kind, code: item.code, name: item.name))
    }
}
