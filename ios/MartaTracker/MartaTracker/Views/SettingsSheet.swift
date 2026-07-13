import SwiftUI

/// App settings: where the collector service lives (Delays + Trip tabs), with a
/// connection test. The URL is stored in UserDefaults so changing your Mac's IP
/// doesn't require a rebuild.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var urlText: String =
        UserDefaults.standard.string(forKey: HistoryService.overrideKey)
        ?? HistoryService.bundledBaseURL
    @State private var testResult: TestResult?
    @State private var testing = false

    enum TestResult {
        case ok(String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.1.123:8000", text: $urlText)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button {
                        Task { await test() }
                    } label: {
                        if testing {
                            HStack { ProgressView().controlSize(.small); Text("Testing…") }
                        } else {
                            Text("Test connection")
                        }
                    }
                    .disabled(testing)
                    if let result = testResult {
                        switch result {
                        case .ok(let message):
                            Label(message, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).font(.callout)
                        case .failed(let message):
                            Label(message, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red).font(.callout)
                        }
                    }
                } header: {
                    Text("Collector service")
                } footer: {
                    Text("Powers the Delays and Trip tabs. Run it on your Mac "
                         + "(python -m collector.api) and use the Mac's WiFi IP here. "
                         + "The live map and favorites work without it.")
                }

                Section {
                    Button("Reset to default (\(HistoryService.bundledBaseURL))") {
                        urlText = HistoryService.bundledBaseURL
                        UserDefaults.standard.removeObject(forKey: HistoryService.overrideKey)
                        testResult = nil
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                // Test hook: run the connection test on open. No effect normally.
                if ProcessInfo.processInfo.environment["MARTA_AUTOTEST"] == "1" {
                    await test()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { save(); dismiss() }
                }
            }
        }
    }

    private func save() {
        let trimmed = urlText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == HistoryService.bundledBaseURL {
            UserDefaults.standard.removeObject(forKey: HistoryService.overrideKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: HistoryService.overrideKey)
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        save()
        do {
            let health = try await HistoryService.healthCheck()
            let fresh = health.secondsAgo.map { " · updated \($0)s ago" } ?? ""
            testResult = .ok("Connected · \(health.observations.formatted()) observations\(fresh)")
        } catch {
            testResult = .failed(error.localizedDescription)
        }
    }
}
