import SwiftUI

/// Searchable rail-station picker for choosing a trip origin/destination.
struct StationPickerSheet: View {
    let title: String
    let onPick: (Station) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(StationCatalog.search(query)) { station in
                Button {
                    onPick(station)
                    dismiss()
                } label: {
                    Label(station.name, systemImage: "tram.fill")
                        .foregroundStyle(.primary)
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search stations")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
