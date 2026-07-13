import SwiftUI

@main
struct MartaTrackerApp: App {
    @StateObject private var service = MartaService()
    @StateObject private var favorites = FavoritesStore()
    @StateObject private var commutes = CommuteStore()
    @StateObject private var reminders = ReminderService()
    @StateObject private var history = HistoricalDelayCache()

    init() {
        // Let CommuteStore resolve sibling bays (widget builds without StopCatalog).
        CommuteStore.siblingResolver = { StopCatalog.shared.siblingStopIds(of: $0) }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(service)
                .environmentObject(favorites)
                .environmentObject(commutes)
                .environmentObject(reminders)
                .environmentObject(history)
                .task(priority: .utility) {
                    // Warm the bundled catalogs off the main thread so the first
                    // search/route view doesn't pay the parse cost (stops.txt ~7k
                    // rows, trip_headsigns.json ~1.6 MB). All are thread-safe.
                    _ = StopCatalog.shared.name(for: "warmup")
                    _ = RouteCatalog.tripHeadsigns.count
                    _ = RouteCatalog.all.count
                    _ = RouteShapes.polylines(for: "RED")
                    _ = StationCatalog.all.count
                }
        }
    }
}
