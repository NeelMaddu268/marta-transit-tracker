import SwiftUI
import MapKit

/// Phase 1 main screen: a live map of MARTA bus + train positions that refreshes
/// on a timer. Tapping a vehicle opens its upcoming arrivals.
struct MapScreen: View {
    @EnvironmentObject private var service: MartaService
    @EnvironmentObject private var favorites: FavoritesStore

    // Centered on downtown Atlanta.
    @State private var camera: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 33.755, longitude: -84.390),
            span: MKCoordinateSpan(latitudeDelta: 0.28, longitudeDelta: 0.28)
        )
    )
    @State private var selected: Vehicle?
    @State private var showBuses = true
    @State private var showTrains = true
    @State private var searchText: String
    @State private var path: [SearchDestination]
    @State private var showingNearby: Bool
    @State private var showingSettings: Bool
    /// Current camera span; buses are decluttered when zoomed out past a threshold.
    @State private var cameraSpanLat: Double = 0.28

    init() {
        // Test hooks: seed search text / deep-link a detail view / present sheets.
        // No effect normally.
        let env = ProcessInfo.processInfo.environment
        _searchText = State(initialValue: env["MARTA_SEARCH"] ?? "")
        _showingNearby = State(initialValue: env["MARTA_PRESENT_NEARBY"] == "1")
        _showingSettings = State(initialValue: env["MARTA_PRESENT_SETTINGS"] == "1")
        var initial: [SearchDestination] = []
        if let r = env["MARTA_NAV_ROUTE"] {
            initial = env["MARTA_NAV_ROUTE_MAP"] == "1" ? [.route(r), .routeMap(r)] : [.route(r)]
        } else if let code = env["MARTA_NAV_PLACE_CODE"] {
            let kind: FavoriteKind = env["MARTA_NAV_PLACE_KIND"] == "bus" ? .busStop : .railStation
            initial = [.place(kind: kind, code: code, name: env["MARTA_NAV_PLACE_NAME"] ?? code)]
        }
        _path = State(initialValue: initial)
    }

    /// Zoomed in enough to show every bus without the map turning to noise.
    private var zoomedIn: Bool { cameraSpanLat < 0.16 }

    private var visibleVehicles: [Vehicle] {
        service.vehicles.filter { v in
            let modeOn = (v.mode == .bus && showBuses) || (v.mode == .rail && showTrains)
            guard modeOn else { return false }
            // Declutter: zoomed out, only trains + favorited-route buses show.
            if v.mode == .bus && !zoomedIn { return favoritedRoutes.contains(v.route) }
            return true
        }
    }

    private var favoritedRoutes: Set<String> {
        Set(favorites.favorites.filter { $0.kind == .route }.map { $0.code })
    }

    // Favorited stations/stops that have a known coordinate, shown as map pins.
    private var favoritePlaces: [MapFavoritePlace] {
        favorites.favorites.compactMap { fav in
            let coord: CLLocationCoordinate2D?
            switch fav.kind {
            case .railStation:
                coord = StationCatalog.all.first { $0.name == fav.code }
                    .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            case .busStop:
                coord = StopCatalog.shared.coordinate(for: fav.code)
            case .route:
                coord = nil
            }
            return coord.map { MapFavoritePlace(id: fav.id, kind: fav.kind, code: fav.code,
                                                coordinate: $0, systemImage: fav.systemImage,
                                                name: fav.name) }
        }
    }

    /// Route polylines to draw: the four rail lines always (they anchor the map),
    /// plus any favorited bus routes.
    private var routeLines: [(id: String, color: Color, width: CGFloat, coords: [CLLocationCoordinate2D])] {
        var lines: [(String, Color, CGFloat, [CLLocationCoordinate2D])] = []
        for key in RouteShapes.railLines {
            let fav = favoritedRoutes.contains(key)
            for (i, poly) in RouteShapes.polylines(for: key).enumerated() {
                lines.append(("\(key)-\(i)", RouteStyle.lineColor(for: key).opacity(fav ? 0.95 : 0.55),
                              fav ? 4.5 : 3, poly))
            }
        }
        for key in favoritedRoutes where !RouteShapes.railLines.contains(key) {
            for (i, poly) in RouteShapes.polylines(for: key).enumerated() {
                lines.append(("\(key)-\(i)", Color.indigo.opacity(0.8), 3.5, poly))
            }
        }
        return lines
    }


    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                mapLayer
                SearchOverlay(query: searchText)
            }
            .navigationTitle("MARTA")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search stations, stops, routes")
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
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await service.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(service.isLoading)
                }
            }
            .sheet(item: $selected) { vehicle in
                ArrivalsSheet(vehicle: vehicle, arrivals: service.arrivals(for: vehicle))
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingNearby) { NearbySheet() }
            .sheet(isPresented: $showingSettings) { SettingsSheet() }
        }
    }

    private var mapLayer: some View {
        // Route lines under everything; non-highlighted vehicles, then highlighted
        // vehicles + place pins last so they draw on top.
        let highlighted = visibleVehicles.filter { favoritedRoutes.contains($0.route) }
        let normal = visibleVehicles.filter { !favoritedRoutes.contains($0.route) }
        return Map(position: $camera) {
            ForEach(routeLines, id: \.id) { line in
                MapPolyline(coordinates: line.coords)
                    .stroke(line.color, style: StrokeStyle(lineWidth: line.width,
                                                           lineCap: .round, lineJoin: .round))
            }
            ForEach(normal) { vehicle in
                Annotation(vehicle.route, coordinate: vehicle.coordinate) {
                    VehicleMarker(vehicle: vehicle)
                        .onTapGesture { selected = vehicle }
                }
            }
            ForEach(highlighted) { vehicle in
                Annotation(vehicle.route, coordinate: vehicle.coordinate) {
                    VehicleMarker(vehicle: vehicle, highlighted: true)
                        .onTapGesture { selected = vehicle }
                }
            }
            ForEach(favoritePlaces) { place in
                Annotation(place.name, coordinate: place.coordinate) {
                    FavoritePlaceMarker(systemImage: place.systemImage)
                        .onTapGesture {
                            path.append(.place(kind: place.kind, code: place.code,
                                               name: place.name))
                        }
                }
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .onMapCameraChange(frequency: .continuous) { context in
            cameraSpanLat = context.region.span.latitudeDelta
        }
        .overlay(alignment: .top) { statusBar }
        .overlay(alignment: .bottomTrailing) { filterControls }
        .overlay(alignment: .bottomLeading) { nearMeButton }
    }

    private var nearMeButton: some View {
        Button {
            showingNearby = true
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: Circle())
        }
        .padding()
    }

    private var statusBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                if service.isLoading {
                    ProgressView().controlSize(.small)
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if let error = service.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var statusText: String {
        let count = visibleVehicles.count
        let hint = (showBuses && !zoomedIn) ? " · zoom in for buses" : ""
        if let updated = service.lastUpdated {
            let fmt = RelativeDateTimeFormatter()
            fmt.unitsStyle = .short
            return "\(count) vehicles · updated \(fmt.localizedString(for: updated, relativeTo: Date()))\(hint)"
        }
        return service.vehicles.isEmpty ? "Loading MARTA feed…" : "\(count) vehicles\(hint)"
    }

    private var filterControls: some View {
        VStack(spacing: 8) {
            FilterToggle(label: "Buses", systemImage: "bus.fill",
                         color: .indigo, isOn: $showBuses)
            FilterToggle(label: "Trains", systemImage: "tram.fill",
                         color: .blue, isOn: $showTrains)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }
}

private struct FilterToggle: View {
    let label: String
    let systemImage: String
    let color: Color
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Label(label, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isOn ? color : .secondary)
                .frame(width: 70, alignment: .leading)
        }
        .buttonStyle(.plain)
        .opacity(isOn ? 1 : 0.5)
    }
}
