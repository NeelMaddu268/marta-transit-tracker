import SwiftUI

/// Create a commute for a route: choose an origin stop and a destination.
struct CommuteSetupSheet: View {
    @EnvironmentObject private var service: MartaService
    @EnvironmentObject private var commutes: CommuteStore
    @Environment(\.dismiss) private var dismiss

    let routeKey: String

    @State private var fromCode: String?
    @State private var fromName: String?
    @State private var toName: String?
    @State private var pickingStop = false

    var body: some View {
        NavigationStack {
            Form {
                Section("From (your stop)") {
                    Button {
                        pickingStop = true
                    } label: {
                        Label(fromName ?? "Choose a bus stop", systemImage: "mappin.circle")
                            .foregroundStyle(fromName == nil ? .secondary : .primary)
                    }
                }

                Section("Toward") {
                    let dests = service.destinations(forRoute: routeKey)
                    if dests.isEmpty {
                        Text("No live directions for this route right now — try again when buses are running.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(dests, id: \.self) { dest in
                            Button {
                                toName = dest
                            } label: {
                                HStack {
                                    Text(dest).foregroundStyle(.primary)
                                    Spacer()
                                    if toName == dest {
                                        Image(systemName: "checkmark").foregroundStyle(.blue)
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    Button("Save commute") { save() }
                        .disabled(fromCode == nil || toName == nil)
                }
            }
            .navigationTitle("Set Up Commute")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $pickingStop) {
                BusStopPickerSheet { id, name in
                    fromCode = id
                    fromName = name
                }
            }
        }
    }

    private func save() {
        guard let fromCode, let fromName, let toName else { return }
        // Store all sibling bays so departures match whichever bay the route
        // actually boards at; display the facility's base name.
        var commute = Commute(routeKey: routeKey, fromCode: fromCode,
                              fromName: fromName.baseStopName, toName: toName)
        commute.fromCodes = StopCatalog.shared.siblingStopIds(of: fromCode)
        commutes.add(commute)
        dismiss()
    }
}
