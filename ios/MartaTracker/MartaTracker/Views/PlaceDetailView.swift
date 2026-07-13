import SwiftUI

/// Everything about a station or bus stop: live incoming arrivals (bus + rail),
/// with a one-tap favorite.
struct PlaceDetailView: View {
    @EnvironmentObject private var service: MartaService
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var history: HistoricalDelayCache

    let kind: FavoriteKind
    let code: String
    let name: String

    private var favorite: Favorite { Favorite(kind: kind, code: code, name: name) }

    var body: some View {
        List {
            let placeCodes = Set(StopCatalog.shared.members(of: code) + [code, name])
            ForEach(service.alerts(forPlaceCodes: placeCodes), id: \.header) { alert in
                Section {
                    AlertBanner(alert: alert)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            let groups = DepartureGroup.group(service.arrivals(kind: kind, code: code))
            Section("Departures") {
                if groups.isEmpty {
                    Text("No arrivals reported right now.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(groups) { group in
                        DepartureBoardRow(
                            group: group,
                            occupancy: service.occupancy(forTrip: group.arrivals.first?.tripId),
                            typicalDelay: history.typicalDelayNow(route: group.route))
                    }
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Recents.record(kind: kind.rawValue, code: code, name: name) }
        .refreshable { await service.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    favorites.toggle(favorite)
                } label: {
                    Image(systemName: favorites.contains(favorite) ? "star.fill" : "star")
                }
            }
        }
    }
}
