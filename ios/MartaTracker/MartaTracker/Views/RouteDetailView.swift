import SwiftUI
import MapKit

/// Everything about a route/line: its live vehicles on a mini-map, grouped by
/// where they're headed.
struct RouteDetailView: View {
    @EnvironmentObject private var service: MartaService
    @EnvironmentObject private var commutes: CommuteStore
    @EnvironmentObject private var favorites: FavoritesStore
    let routeKey: String

    @State private var settingUpCommute = false

    private var info: RouteInfo? { RouteCatalog.info(for: routeKey) }
    private var routeFavorite: Favorite {
        Favorite(kind: .route, code: routeKey, name: info?.displayName ?? "Route \(routeKey)")
    }

    /// Live vehicles on this route, grouped by destination (headsign).
    private var groups: [(destination: String, vehicles: [Vehicle])] {
        let vehicles = service.vehicles(onRoute: routeKey)
        let byDest = Dictionary(grouping: vehicles) {
            $0.destination ?? ($0.direction.map { "Direction \($0)" } ?? "In service")
        }
        return byDest
            .map { (destination: $0.key, vehicles: $0.value) }
            .sorted { $0.destination < $1.destination }
    }

    var body: some View {
        let groups = groups
        let all = groups.flatMap(\.vehicles)
        List {
            // Active service alerts for this route.
            ForEach(service.alerts(forRoute: routeKey), id: \.header) { alert in
                Section {
                    AlertBanner(alert: alert)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            // Pinned commutes for this route, at the very top.
            ForEach(commutes.commutes(forRoute: routeKey)) { commute in
                Section {
                    CommuteCard(commute: commute, departures: service.commuteDepartures(commute))
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            if all.isEmpty {
                Section {
                    Text("No vehicles running on this route right now.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    RouteMiniMap(vehicles: all)
                        .frame(height: 200)
                        .listRowInsets(EdgeInsets())
                        .overlay(alignment: .bottomTrailing) {
                            NavigationLink(value: SearchDestination.routeMap(routeKey)) {
                                Label("Full map", systemImage: "arrow.up.left.and.arrow.down.right")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.thinMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .padding(8)
                        }
                }
                ForEach(groups, id: \.destination) { group in
                    Section("To \(group.destination) · \(group.vehicles.count)") {
                        ForEach(group.vehicles) { v in
                            HStack {
                                Image(systemName: v.mode == .bus ? "bus.fill" : "tram.fill")
                                    .foregroundStyle(.indigo)
                                Text(v.mode == .bus ? "Bus \(v.id)" : "Train \(v.id)")
                                Spacer()
                                OccupancyBadge(raw: v.occupancy)
                                DelayBadge(delaySeconds: v.delaySeconds, compact: true)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(info?.displayName ?? "Route \(routeKey)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Recents.record(kind: "route", code: routeKey,
                           name: info?.displayName ?? "Route \(routeKey)")
        }
        .refreshable { await service.refresh() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { favorites.toggle(routeFavorite) } label: {
                    Image(systemName: favorites.contains(routeFavorite) ? "star.fill" : "star")
                }
                Button { settingUpCommute = true } label: {
                    Image(systemName: "pin")
                }
            }
        }
        .sheet(isPresented: $settingUpCommute) {
            CommuteSetupSheet(routeKey: routeKey)
        }
    }
}

/// The pinned "your commute" hero card: brand gradient (matching the widget),
/// big live countdown, bay guidance, and a bell for a "time to leave" reminder.
private struct CommuteCard: View {
    @EnvironmentObject private var reminders: ReminderService
    @EnvironmentObject private var service: MartaService
    @EnvironmentObject private var history: HistoricalDelayCache
    let commute: Commute
    let departures: [Arrival]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "pin.fill").font(.caption)
                Text(commute.displayTitle)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .lineLimit(2)
                Spacer(minLength: 6)
                if let next = departures.first {
                    Button {
                        Task {
                            await reminders.toggle(
                                for: next, title: commute.displayTitle,
                                bay: StopCatalog.shared.bayLabel(for: next.stopId))
                        }
                    } label: {
                        Image(systemName: reminders.isScheduled(next) ? "bell.fill" : "bell")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .background(.white.opacity(0.22), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("departure reminder")
                }
            }
            .opacity(0.95)

            if departures.isEmpty {
                Text("No upcoming departures right now.")
                    .font(.callout)
                    .opacity(0.85)
            } else if let next = departures.first {
                HStack(alignment: .firstTextBaseline) {
                    TickingETA(time: next.predictedTime, approximate: true)
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                    Spacer()
                    if departures.count > 1 {
                        Text("then \(laterTimes)")
                            .font(.caption.weight(.medium))
                            .opacity(0.9)
                    }
                }
                HStack(spacing: 6) {
                    if let bay = StopCatalog.shared.bayLabel(for: next.stopId) {
                        InfoChip(text: "Wait at \(bay)", onDark: true)
                    }
                    if let delay = next.delaySeconds, abs(delay) > 60 {
                        InfoChip(text: DelayFormat.label(delay), onDark: true)
                    }
                    OccupancyBadge(raw: service.occupancy(forTrip: next.tripId), onDark: true)
                    if let typical = history.typicalDelayNow(route: commute.routeKey) {
                        InfoChip(text: "usually +\(typical / 60)m this hour", onDark: true)
                    }
                    if next.isVolatile {
                        InfoChip(text: "Updating…", onDark: true)
                    } else if let eta = next.etaSeconds, eta >= 600 {
                        // Far-out estimate: show its measured typical error.
                        let margin = ETAConfidence.typicalErrorMinutes(
                            isRail: RouteShapes.railLines.contains(commute.routeKey),
                            horizonMinutes: eta / 60)
                        InfoChip(text: "typically ±\(margin) min", onDark: true)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: 18))
        .padding(.vertical, 2)
    }

    private var laterTimes: String {
        departures.dropFirst().prefix(2)
            .compactMap { a -> String? in
                guard let eta = a.etaSeconds, eta > 0 else { return nil }
                return "\(eta / 60)"
            }
            .joined(separator: ", ") + " min"
    }
}

/// Small non-interactive map framing a set of vehicles.
private struct RouteMiniMap: View {
    let vehicles: [Vehicle]

    var body: some View {
        Map(initialPosition: .automatic, interactionModes: [.pan, .zoom]) {
            ForEach(vehicles) { v in
                Annotation(v.destination ?? "", coordinate: v.coordinate) {
                    VehicleMarker(vehicle: v)
                }
            }
        }
    }
}
