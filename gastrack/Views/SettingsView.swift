import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var store: StationStore
    @State private var baseURL: String = ""
    @State private var deviceSecret: String = ""
    @State private var registrationStatus: String?
    @State private var isRegistering = false
    @State private var health: HealthResponse?
    @State private var isLoadingHealth = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Base URL (e.g. http://100.x.x.x:7878)", text: $baseURL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }

                Section {
                    LabeledContent("Local cache", value: "\(store.byId.count) stations")
                    Button("Clear local cache", role: .destructive) {
                        store.clear()
                    }
                    if let h = health {
                        LabeledContent("Server cache", value: "\(h.cachedStations) stations")
                        if let newest = h.newestFetch.flatMap({ ISO8601DateFormatter().date(from: $0) }) {
                            LabeledContent("Last fetch", value: newest.formatted(.relative(presentation: .named)))
                        }
                    }
                    Button(isLoadingHealth ? "Refreshing…" : "Refresh stats") {
                        Task { await loadHealth() }
                    }
                    .disabled(isLoadingHealth || baseURL.isEmpty)
                } header: {
                    Text("Cache")
                }

                Section("Authentication") {
                    SecureField("Device secret", text: $deviceSecret)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Button(isRegistering ? "Registering…" : "Register API key") {
                        Task { await register() }
                    }
                    .disabled(isRegistering || deviceSecret.isEmpty || baseURL.isEmpty)

                    if let status = registrationStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(status.hasPrefix("✓") ? .green : .red)
                    }

                    if KeychainService.load(forKey: "user_api_key") != nil {
                        Label("API key stored", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                baseURL = api.baseURL
                deviceSecret = KeychainService.load(forKey: "device_secret") ?? ""
                Task { await loadHealth() }
            }
            .onChange(of: baseURL) { _, new in
                api.baseURL = new
            }
            .onChange(of: deviceSecret) { _, new in
                if new.isEmpty {
                    KeychainService.delete(forKey: "device_secret")
                } else {
                    KeychainService.save(new, forKey: "device_secret")
                }
            }
        }
    }

    private func loadHealth() async {
        guard !baseURL.isEmpty else { return }
        isLoadingHealth = true
        health = try? await api.fetchHealth()
        isLoadingHealth = false
    }

    private func register() async {
        isRegistering = true
        registrationStatus = nil
        do {
            try await api.registerKey()
            registrationStatus = "✓ Key registered successfully"
        } catch {
            registrationStatus = "✗ \(error.localizedDescription)"
        }
        isRegistering = false
    }
}
