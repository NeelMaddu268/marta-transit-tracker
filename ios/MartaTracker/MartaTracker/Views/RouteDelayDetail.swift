import SwiftUI
import Charts

/// Hourly delay breakdown for one route/line — "when is it usually late?"
struct RouteDelayDetail: View {
    let source: TransitMode
    let route: String

    @State private var hourly: [DelayGroup] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.secondary) }
            } else if hourly.isEmpty && !isLoading {
                Section { Text("Not enough data yet for an hourly breakdown.")
                    .foregroundStyle(.secondary) }
            } else {
                Section("Median delay by hour") {
                    chart.frame(height: 220).padding(.vertical, 8)
                }
                Section("By hour") {
                    ForEach(hourly.sorted { hourValue($0) < hourValue($1) }) { g in
                        HStack {
                            Text(hourLabel(hourValue(g))).font(.body.monospacedDigit())
                            Spacer()
                            Text("\(Int(g.onTimePct))% on time").font(.caption).foregroundStyle(.secondary)
                            Text(DelayFormat.label(g.medianDelay))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(DelayFormat.color(g.medianDelay))
                                .frame(width: 90, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .navigationTitle(source == .bus ? "Route \(route)" : "\(route.capitalized) Line")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if isLoading && hourly.isEmpty { ProgressView() } }
        .task { await load() }
    }

    private var chart: some View {
        Chart(hourly) { g in
            BarMark(
                x: .value("Hour", hourValue(g)),
                y: .value("Median delay (min)", Double(g.medianDelay) / 60.0)
            )
            .foregroundStyle(DelayFormat.color(g.medianDelay))
        }
        .chartXScale(domain: 0...23)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                AxisValueLabel { if let h = value.as(Int.self) { Text(hourLabel(h)) } }
                AxisGridLine()
            }
        }
        .chartYAxisLabel("min late")
    }

    private func hourValue(_ g: DelayGroup) -> Int { Int(g.group) ?? 0 }

    private func hourLabel(_ h: Int) -> String {
        if h == 0 { return "12a" }
        if h == 12 { return "12p" }
        return h < 12 ? "\(h)a" : "\(h - 12)p"
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            hourly = try await HistoryService.delayStats(
                source: source, groupBy: "hour", route: route, minN: 5)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
