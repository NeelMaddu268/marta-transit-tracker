import WidgetKit
import SwiftUI

// Home-screen widget: live next departures for the user's first saved commute
// (e.g. Windward P&R → 140 → North Springs). Reads commutes from the App Group
// and fetches the bus trip-updates feed directly — no key or local server needed.

// MARK: - Timeline

struct CommuteEntry: TimelineEntry {
    let date: Date
    let commute: Commute?
    let departures: [Date]     // upcoming departure times at the commute's stop
    let bay: String?           // where to wait, e.g. "Bay C"
    let problem: String?       // short user-facing note when data is unavailable

    static func placeholder() -> CommuteEntry {
        let commute = Commute(routeKey: "140", fromCode: "0",
                              fromName: "Windward P&R", toName: "North Springs Stn")
        return CommuteEntry(
            date: .now, commute: commute,
            departures: [.now.addingTimeInterval(480), .now.addingTimeInterval(1380)],
            bay: "Bay C", problem: nil
        )
    }
}

struct CommuteProvider: TimelineProvider {
    private static let tripUpdatesURL = URL(string:
        "https://gtfs-rt.itsmarta.com/TMGTFSRealTimeWebService/tripupdate/tripupdates.pb")!

    func placeholder(in context: Context) -> CommuteEntry { .placeholder() }

    func getSnapshot(in context: Context, completion: @escaping (CommuteEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder())
        } else {
            Task { completion(await makeEntry()) }
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CommuteEntry>) -> Void) {
        Task {
            let entry = await makeEntry()
            // Refresh roughly every 8 minutes; the countdown text ticks by itself.
            let next = Date().addingTimeInterval(8 * 60)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func loadCommute() -> Commute? {
        guard let data = AppGroup.defaults.data(forKey: CommuteStore.key),
              let commutes = try? JSONDecoder().decode([Commute].self, from: data) else {
            return nil
        }
        return commutes.first
    }

    private func makeEntry() async -> CommuteEntry {
        let now = Date()
        guard let commute = loadCommute() else {
            return CommuteEntry(date: now, commute: nil, departures: [], bay: nil, problem: nil)
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: Self.tripUpdatesURL)
            let matched = Self.departures(in: data, for: commute, now: now)
            let bay = matched.first.flatMap { Self.bayLabel(forStop: $0.stopId) }
            return CommuteEntry(date: now, commute: commute,
                                departures: matched.map { $0.time }, bay: bay,
                                problem: nil)
        } catch {
            return CommuteEntry(date: now, commute: commute, departures: [], bay: nil,
                                problem: "Couldn't reach the MARTA feed")
        }
    }

    /// Upcoming departures at the commute's stop (any sibling bay), on its route,
    /// toward its destination — same matching semantics as the app's commute card.
    static func departures(in feedData: Data, for commute: Commute, now: Date)
        -> [(time: Date, stopId: String)] {
        let nowEpoch = Int(now.timeIntervalSince1970)
        var matched: [(Int, String)] = []
        let fromCodes = Set(commute.allFromCodes)
        for tu in GTFSRealtime.tripUpdates(from: feedData) {
            guard tu.trip.routeId == commute.routeKey,
                  RouteCatalog.headsign(forTrip: tu.trip.tripId) == commute.toName else { continue }
            for stu in tu.stopTimeUpdates {
                guard let stopId = stu.stopId, fromCodes.contains(stopId) else { continue }
                if let t = stu.arrival?.time ?? stu.departure?.time, t >= nowEpoch {
                    matched.append((t, stopId))
                }
            }
        }
        return matched.sorted { $0.0 < $1.0 }.prefix(4)
            .map { (Date(timeIntervalSince1970: TimeInterval($0.0)), $0.1) }
    }

    /// Bay label ("Bay C") for a stop id, from the bundled stops.txt. One linear
    /// scan per timeline refresh — cheap, and avoids shipping a parsed catalog.
    static func bayLabel(forStop stopId: String) -> String? {
        guard let url = Bundle.main.url(forResource: "stops", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("\(stopId),") else { continue }
            // stop_name is the 3rd CSV field; respect quoted fields.
            var fields: [String] = []
            var current = ""
            var inQuotes = false
            for ch in line {
                if ch == "\"" { inQuotes.toggle() }
                else if ch == "," && !inQuotes { fields.append(current); current = "" }
                else { current.append(ch) }
                if fields.count > 3 { break }
            }
            fields.append(current)
            guard fields.count > 2 else { return nil }
            let name = fields[2].trimmingCharacters(in: .whitespaces)
            let base = name.baseStopName
            guard base.count < name.count else { return nil }
            let suffix = name.dropFirst(base.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: " -"))
            return suffix.isEmpty ? nil : suffix.capitalized
        }
        return nil
    }
}

// MARK: - Views

struct CommuteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CommuteEntry

    var body: some View {
        Group {
            if let commute = entry.commute {
                if family == .systemSmall {
                    smallLayout(commute)
                } else {
                    mediumLayout(commute)
                }
            } else {
                emptyState
            }
        }
        .foregroundStyle(.white)
    }

    private func smallLayout(_ commute: Commute) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                routeChip(commute.routeKey)
                if let bay = entry.bay {
                    Text(bay)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            Spacer(minLength: 2)
            countdownOrProblem
            Text("to \(commute.toName)")
                .font(.caption2)
                .opacity(0.85)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func mediumLayout(_ commute: Commute) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                routeChip(commute.routeKey)
                Text(commute.displayTitle)
                    .font(.caption.weight(.medium))
                    .opacity(0.9)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline) {
                countdownOrProblem
                Spacer()
                if entry.departures.count > 1 {
                    Text("then \(laterTimes)")
                        .font(.caption)
                        .opacity(0.85)
                }
            }
            HStack(spacing: 6) {
                if let bay = entry.bay {
                    Text("Wait at \(bay)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.white.opacity(0.22), in: Capsule())
                }
                Text("as of \(entry.date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .opacity(0.6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var countdownOrProblem: some View {
        if let first = entry.departures.first {
            let size: CGFloat = family == .systemSmall ? 28 : 32
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                // Far-out predictions are estimates; mark them like the app does.
                if first.timeIntervalSince(entry.date) >= 15 * 60 {
                    Text("~").font(.system(size: size * 0.8, weight: .bold, design: .rounded))
                }
                Text(timerInterval: entry.date...first, countsDown: true)
                    .font(.system(size: size, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
        } else {
            Text(entry.problem ?? "No departures right now")
                .font(.callout.weight(.medium))
                .opacity(0.9)
        }
    }

    private var laterTimes: String {
        entry.departures.dropFirst().prefix(2)
            .map { $0.formatted(date: .omitted, time: .shortened) }
            .joined(separator: ", ")
    }

    private func routeChip(_ route: String) -> some View {
        Text(route)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "pin.fill").font(.title3)
            Text("Save a commute in MARTA Tracker to see departures here.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .opacity(0.9)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Widget

struct CommuteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CommuteWidget", provider: CommuteProvider()) { entry in
            CommuteWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    LinearGradient(
                        colors: [Color(red: 0.32, green: 0.22, blue: 0.83),
                                 Color(red: 0.08, green: 0.47, blue: 0.95)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                }
        }
        .configurationDisplayName("Next Commute")
        .description("Live departures for your saved commute.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct MartaWidgetBundle: WidgetBundle {
    var body: some Widget {
        CommuteWidget()
    }
}
