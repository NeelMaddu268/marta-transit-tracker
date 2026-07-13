import SwiftUI

/// Recently viewed stops/stations/routes, most recent first (max 8).
enum Recents {
    struct Item: Codable, Identifiable {
        let kind: String     // "route" | "railStation" | "busStop"
        let code: String
        let name: String
        var id: String { "\(kind):\(code)" }

        var destination: SearchDestination {
            switch kind {
            case "route": return .route(code)
            case "railStation": return .place(kind: .railStation, code: code, name: name)
            default: return .place(kind: .busStop, code: code, name: name)
            }
        }

        var systemImage: String {
            switch kind {
            case "route": return "signpost.right.fill"
            case "railStation": return "tram.fill"
            default: return "bus.fill"
            }
        }
    }

    private static let key = "recents.v1"

    static func all() -> [Item] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return items
    }

    static func record(kind: String, code: String, name: String) {
        var items = all().filter { !($0.kind == kind && $0.code == code) }
        items.insert(Item(kind: kind, code: code, name: name), at: 0)
        if let data = try? JSONEncoder().encode(Array(items.prefix(8))) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// The Map search overlay: results while typing, recents when the field is
/// focused but empty, nothing otherwise.
struct SearchOverlay: View {
    let query: String
    @Environment(\.isSearching) private var isSearching

    var body: some View {
        if !query.isEmpty {
            SearchResultsList(query: query)
        } else if isSearching {
            let recents = Recents.all()
            List {
                if recents.isEmpty {
                    Text("Search routes, stations, and bus stops — recent ones will show up here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Section("Recent") {
                        ForEach(recents) { item in
                            NavigationLink(value: item.destination) {
                                Label(item.name.localizedCapitalized, systemImage: item.systemImage)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .background(.background)
        }
    }
}
