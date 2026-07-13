import SwiftUI

/// Phase 2: a merged list of the next arrivals across all favorite places
/// (sorted by time), plus management of the favorites themselves.
struct FavoritesScreen: View {
    @EnvironmentObject private var service: MartaService
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var commutes: CommuteStore
    @State private var showingAdd =
        ProcessInfo.processInfo.environment["MARTA_PRESENT_ADD"] == "1"  // test hook

    var body: some View {
        NavigationStack {
            Group {
                if favorites.favorites.isEmpty && commutes.commutes.isEmpty {
                    emptyState
                } else {
                    listContent
                }
            }
            .navigationTitle("Favorites")
            .navigationDestination(for: SearchDestination.self) { dest in
                switch dest {
                case let .place(kind, code, name):
                    PlaceDetailView(kind: kind, code: code, name: name)
                case let .route(key):
                    RouteDetailView(routeKey: key)
                case let .routeMap(key):
                    RouteMapScreen(routeKey: key)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !favorites.favorites.isEmpty { EditButton() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingAdd) { AddFavoriteSheet() }
            .refreshable { await service.refresh() }
        }
    }

    /// All upcoming arrivals across favorited places (not routes), soonest first.
    private var mergedArrivals: [Arrival] {
        favorites.favorites
            .filter { $0.kind.isPlace }
            .flatMap { service.arrivals(for: $0) }
            .sorted { ($0.predictedTime ?? .distantFuture) < ($1.predictedTime ?? .distantFuture) }
    }

    private var listContent: some View {
        List {
            if !commutes.commutes.isEmpty {
                Section("Commutes") {
                    ForEach(commutes.commutes) { commute in
                        NavigationLink(value: SearchDestination.route(commute.routeKey)) {
                            let next = service.commuteDepartures(commute).first
                            HStack(spacing: 12) {
                                RoutePill(route: commute.routeKey)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(commute.displayTitle)
                                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                        .lineLimit(1)
                                    Label("Commute", systemImage: "pin.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                TickingETA(time: next?.predictedTime)
                                    .font(.system(.title3, design: .rounded).weight(.bold))
                                    .foregroundStyle(.indigo)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .onDelete { commutes.remove(atOffsets: $0) }
                }
            }
            let arrivals = mergedArrivals
            Section("Next arrivals") {
                if arrivals.isEmpty {
                    Text("No upcoming arrivals right now.")
                        .foregroundStyle(.secondary)
                } else {
                    // Arrival ids are stable across refreshes, so rows don't churn.
                    ForEach(Array(arrivals.prefix(25))) { arrival in
                        ArrivalRow(arrival: arrival, showRoute: true)
                    }
                }
            }
            Section("Saved") {
                ForEach(favorites.favorites) { fav in
                    NavigationLink(value: destination(for: fav)) {
                        Label(fav.name, systemImage: fav.systemImage)
                    }
                }
                .onDelete { favorites.remove(atOffsets: $0) }
                .onMove { favorites.move(fromOffsets: $0, toOffset: $1) }
            }
        }
    }

    private func destination(for fav: Favorite) -> SearchDestination {
        switch fav.kind {
        case .route:
            return .route(fav.code)
        case .railStation, .busStop:
            return .place(kind: fav.kind, code: fav.code, name: fav.name)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No favorites yet", systemImage: "star")
        } description: {
            Text("Add a train station or bus stop to see its upcoming arrivals here.")
        } actions: {
            Button("Add a favorite") { showingAdd = true }
                .buttonStyle(.borderedProminent)
        }
    }
}
