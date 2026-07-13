import SwiftUI

/// Top-level tabs: the live map and the favorites list.
struct RootView: View {
    @EnvironmentObject private var service: MartaService
    @EnvironmentObject private var commutes: CommuteStore
    @EnvironmentObject private var reminders: ReminderService
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: Int

    init() {
        // Test hook: open on a given tab when launched with this env var.
        // No effect on a normal launch.
        let tab = ProcessInfo.processInfo.environment["MARTA_START_TAB"]
        _selection = State(initialValue:
            ["map": 0, "favorites": 1, "delays": 2, "trip": 3][tab ?? ""] ?? 0)
    }

    var body: some View {
        TabView(selection: $selection) {
            MapScreen()
                .tag(0)
                .tabItem { Label("Map", systemImage: "map.fill") }
            FavoritesScreen()
                .tag(1)
                .tabItem { Label("Favorites", systemImage: "star.fill") }
            DelaysScreen()
                .tag(2)
                .tabItem { Label("Delays", systemImage: "clock.badge.exclamationmark.fill") }
            TripPlanScreen()
                .tag(3)
                .tabItem { Label("Trip", systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill") }
        }
        // Single owner of the refresh lifecycle so tab switches don't churn it.
        .task { service.start() }
        // Returning to the app refreshes immediately instead of waiting out the
        // remainder of the poll interval — reopened ETAs are never stale.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await service.refresh() }
            }
        }
        // After every feed refresh, re-aim pending departure reminders at the
        // latest predictions (self-correcting while the app is open).
        .onChange(of: service.lastUpdated) { _, _ in
            let departures = commutes.commutes.flatMap { service.commuteDepartures($0) }
            Task { await reminders.reconcile(departures: departures) }
        }
        .tint(.indigo)
    }
}
