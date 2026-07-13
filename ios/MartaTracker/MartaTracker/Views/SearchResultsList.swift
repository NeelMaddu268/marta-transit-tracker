import SwiftUI

/// Results for the Map search: routes, rail stations, and bus stops. Each row
/// navigates to its detail. Shown as an overlay while the search field is active.
struct SearchResultsList: View {
    let query: String

    var body: some View {
        List {
            let routes = RouteCatalog.search(query)
            if !routes.isEmpty {
                Section("Routes") {
                    ForEach(routes.prefix(25)) { r in
                        NavigationLink(value: SearchDestination.route(r.key)) {
                            Label(r.displayName, systemImage: r.isRail ? "tram.fill" : "bus.fill")
                        }
                    }
                }
            }

            let stations = StationCatalog.railStations.filter { $0.name.searchMatches(query) }
            if !stations.isEmpty {
                Section("Stations") {
                    ForEach(stations.prefix(25)) { s in
                        NavigationLink(value: SearchDestination.place(
                            kind: .railStation, code: s.name, name: s.name)) {
                            Label(s.name, systemImage: "tram.fill")
                        }
                    }
                }
            }

            let stops = StopCatalog.shared.search(query)
            if !stops.isEmpty {
                Section("Bus stops") {
                    ForEach(stops, id: \.id) { stop in
                        NavigationLink(value: SearchDestination.place(
                            kind: .busStop, code: stop.id, name: stop.name)) {
                            Label(stop.name, systemImage: "bus.fill")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .background(.background)
    }
}
