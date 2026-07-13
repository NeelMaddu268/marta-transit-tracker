import SwiftUI

/// Phase 4: multimodal trip planning. Pick two stations; the app asks the Python
/// service (OTP + our delay history) for itineraries.
struct TripPlanScreen: View {
    @State private var from: Station?
    @State private var to: Station?
    @State private var itineraries: [Itinerary] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var picking: PickTarget?
    @State private var autoPlan = false

    init() {
        // Test hook: preselect from/to stations by name and auto-plan on appear.
        // No effect on a normal launch.
        let env = ProcessInfo.processInfo.environment
        if let f = env["MARTA_TRIP_FROM"], let s = StationCatalog.all.first(where: { $0.name == f }) {
            _from = State(initialValue: s)
        }
        if let t = env["MARTA_TRIP_TO"], let s = StationCatalog.all.first(where: { $0.name == t }) {
            _to = State(initialValue: s)
        }
        _autoPlan = State(initialValue: env["MARTA_TRIP_FROM"] != nil && env["MARTA_TRIP_TO"] != nil)
    }

    enum PickTarget: Int, Identifiable {
        case from, to
        var id: Int { rawValue }
        var title: String { self == .from ? "From" : "To" }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    endpointRow(.from, station: from)
                    endpointRow(.to, station: to)
                    if from != nil || to != nil {
                        Button { swap(&from, &to) } label: {
                            Label("Swap", systemImage: "arrow.up.arrow.down")
                        }
                    }
                    Button {
                        Task { await planTrip() }
                    } label: {
                        Text("Plan trip").frame(maxWidth: .infinity)
                    }
                    .disabled(from == nil || to == nil || isLoading)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).font(.callout).foregroundStyle(.secondary)
                    }
                }

                if !itineraries.isEmpty {
                    Section("Options") {
                        ForEach(itineraries) { ItineraryCard(itinerary: $0) }
                    }
                }
            }
            .navigationTitle("Plan a Trip")
            .overlay {
                if isLoading { ProgressView("Planning…") }
            }
            .sheet(item: $picking) { target in
                StationPickerSheet(title: target.title) { station in
                    switch target {
                    case .from: from = station
                    case .to:   to = station
                    }
                }
            }
            .task {
                if autoPlan { autoPlan = false; await planTrip() }
            }
        }
    }

    private func endpointRow(_ target: PickTarget, station: Station?) -> some View {
        Button {
            picking = target
        } label: {
            HStack {
                Image(systemName: target == .from ? "circle" : "mappin.circle.fill")
                    .foregroundStyle(target == .from ? Color.secondary : Color.red)
                VStack(alignment: .leading, spacing: 1) {
                    Text(target.title).font(.caption).foregroundStyle(.secondary)
                    Text(station?.name ?? "Choose a station")
                        .foregroundStyle(station == nil ? .secondary : .primary)
                }
            }
        }
    }

    private func planTrip() async {
        guard let from, let to else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await HistoryService.plan(
                fromLat: from.lat, fromLon: from.lon, toLat: to.lat, toLon: to.lon)
            itineraries = result
            errorMessage = result.isEmpty
                ? "No trips found between these stations right now." : nil
        } catch {
            itineraries = []
            errorMessage = error.localizedDescription
        }
    }
}
