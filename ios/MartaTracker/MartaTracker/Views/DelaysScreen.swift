import SwiftUI

/// Phase 3: historical delay stats from the Python collector service.
/// Lists routes/lines worst-first by typical delay; tap for an hourly breakdown.
struct DelaysScreen: View {
    @State private var source: TransitMode = .bus
    @State private var groups: [DelayGroup] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var path: [String]

    // Only show groups with enough samples to be meaningful.
    private let minSamples = 50

    init() {
        // Test hook: deep-link into a route's hourly detail. No effect normally.
        let route = ProcessInfo.processInfo.environment["MARTA_DETAIL_ROUTE"]
        _path = State(initialValue: route.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let errorMessage, groups.isEmpty {
                    errorState(errorMessage)
                } else if groups.isEmpty && !isLoading {
                    emptyState
                } else {
                    statsList
                }
            }
            .navigationTitle("Typical Delays")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Mode", selection: $source) {
                        Text("Bus").tag(TransitMode.bus)
                        Text("Rail").tag(TransitMode.rail)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
            }
            .overlay { if isLoading && groups.isEmpty { ProgressView() } }
            .navigationDestination(for: String.self) { route in
                RouteDelayDetail(source: source, route: route)
            }
            .task(id: source) { await load() }
            .refreshable { await load() }
        }
    }

    private var statsList: some View {
        List {
            Section {
                ForEach(sortedGroups) { g in
                    NavigationLink(value: g.group) {
                        DelayStatRow(group: g, unit: source == .bus ? "Route" : "Line")
                    }
                }
            } footer: {
                Text("Based on collected data, most-delayed first. "
                     + "Groups with fewer than \(minSamples) samples are hidden.")
            }
        }
    }

    private var sortedGroups: [DelayGroup] {
        groups.sorted { $0.medianDelay > $1.medianDelay }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            groups = try await HistoryService.delayStats(
                source: source, groupBy: "route", minN: minSamples)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            groups = []
        }
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Stats unavailable", systemImage: "exclamationmark.icloud")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") { Task { await load() } }
                .buttonStyle(.borderedProminent)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No data yet",
            systemImage: "clock.badge.questionmark",
            description: Text("The collector needs to run for a while to build up "
                              + "delay history for \(source == .bus ? "buses" : "trains").")
        )
    }
}

/// One route/line row: badge, typical delay, on-time rate, sample count.
private struct DelayStatRow: View {
    let group: DelayGroup
    let unit: String

    var body: some View {
        HStack(spacing: 12) {
            RoutePill(route: group.group)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(unit) \(group.group)")
                    .font(.system(.body, design: .rounded).weight(.medium))
                Text("\(Int(group.onTimePct))% on time · \(group.n) samples")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(DelayFormat.label(group.medianDelay))
                .font(.caption.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(DelayFormat.color(group.medianDelay).opacity(0.16), in: Capsule())
                .foregroundStyle(DelayFormat.color(group.medianDelay))
        }
        .padding(.vertical, 2)
    }
}
