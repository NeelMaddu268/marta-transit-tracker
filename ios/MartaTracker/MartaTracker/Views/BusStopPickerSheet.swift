import SwiftUI

/// Searchable bus-stop picker (from the bundled GTFS catalog).
struct BusStopPickerSheet: View {
    let onPick: (_ id: String, _ name: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(StopCatalog.shared.search(query), id: \.id) { stop in
                Button {
                    onPick(stop.id, stop.name)
                    dismiss()
                } label: {
                    Label(stop.name, systemImage: "bus.fill").foregroundStyle(.primary)
                }
            }
            .listStyle(.plain)
            .overlay {
                if query.isEmpty {
                    ContentUnavailableView("Search bus stops", systemImage: "magnifyingglass",
                                           description: Text("Type part of a stop name."))
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search bus stops")
            .navigationTitle("Choose Stop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
        }
    }
}
