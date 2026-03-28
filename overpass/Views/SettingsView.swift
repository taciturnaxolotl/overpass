import StoreKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var store: StationStore
    @AppStorage("balance_mpg") private var balanceMpg: Double = 28
    @AppStorage("balance_tank") private var balanceTank: Double = 12
    @State private var showClearConfirm = false
    @State private var devTapCount = 0
    @State private var showDevSettings = false
    private let storeManager = StoreManager.shared
    @State private var isRestoring = false
    @State private var restoreSucceeded: Bool? = nil

    var body: some View {
        NavigationStack {
            Form {
                bestValueSection
                cacheSection
                aboutSection
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Clear on-device cache?",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear \(store.byId.count) stations", role: .destructive) {
                    store.clear()
                }
            } message: {
                Text("Station data will be re-fetched from the server when you next open the map.")
            }
            .sheet(isPresented: $showDevSettings) {
                DeveloperSettingsSheet(api: api)
            }
        }
    }

    // MARK: - Sections

    private var bestValueSection: some View {
        Section {
            Stepper(value: $balanceMpg, in: 10...60, step: 1) {
                LabeledContent("Fuel economy", value: "\(Int(balanceMpg)) mpg")
            }
            Stepper(value: $balanceTank, in: 5...40, step: 1) {
                LabeledContent("Tank size", value: "\(Int(balanceTank)) gal")
            }
        } header: {
            Text("Best Value Sort")
        } footer: {
            Text("Used to estimate the real cost of driving to a cheaper station.")
        }
    }

    private var cacheSection: some View {
        Section("Cache") {
            LabeledContent("Cached stations") {
                Text("\(store.byId.count)")
                    .foregroundStyle(.secondary)
            }
            Button("Clear Cache", role: .destructive) {
                showClearConfirm = true
            }
            .disabled(store.byId.isEmpty)
        }
    }

    private var aboutSection: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"

        return Section {
            if storeManager.isUnlocked {
                LabeledContent("Overpass", value: storeManager.purchaseDate.map { "Purchased \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: .now))" } ?? "Purchased")
                    .foregroundStyle(.secondary)
            } else if storeManager.isInTrial {
                let days = storeManager.daysRemainingInTrial
                LabeledContent("Free Trial") {
                    Text("\(days) day\(days == 1 ? "" : "s") remaining")
                        .foregroundStyle(days <= 2 ? .orange : .secondary)
                }
            }

            LabeledContent("Version", value: "\(version) (\(build))")
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .onTapGesture {
                    devTapCount += 1
                    if devTapCount >= 7 {
                        devTapCount = 0
                        showDevSettings = true
                    }
                }

            Button {
                Task {
                    isRestoring = true
                    restoreSucceeded = nil
                    await storeManager.restore()
                    restoreSucceeded = storeManager.isUnlocked
                    isRestoring = false
                    if restoreSucceeded == false {
                        try? await Task.sleep(for: .seconds(30))
                        restoreSucceeded = nil
                    }
                }
            } label: {
                if isRestoring {
                    HStack {
                        ProgressView()
                        Text("Restoring…")
                    }
                } else if restoreSucceeded == true {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Purchase Restored")
                    }
                } else if restoreSucceeded == false {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                        Text("Nothing to Restore")
                    }
                    .foregroundStyle(.secondary)
                } else {
                    Text("Restore Purchase")
                }
            }
            .disabled(isRestoring)

            if storeManager.isInTrial {
                Button(storeManager.isPurchasing ? "Purchasing…" : "Buy Overpass — \(storeManager.product?.displayPrice ?? "$2.99")") {
                    Task { try? await storeManager.purchase() }
                }
                .disabled(storeManager.isPurchasing || storeManager.product == nil)
            }
        } footer: {
            HStack {
                Spacer()
                Text("Made with ♥ by [Kieran Klukas](https://dunkirk.sh)")
                Spacer()
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        }
    }
}

// MARK: - Developer Settings Sheet

private struct DeveloperSettingsSheet: View {
    let api: APIClient

    @State private var baseURL: String = ""
    @State private var deviceSecret: String = ""
    @State private var registrationError: String?
    @State private var isRegistering = false
    @State private var hasApiKey = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Hi! If you found this I bet you like breaking things. Shoot me an email and negotiate your price :)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }

                Section("Server") {
                    TextField("Base URL", text: $baseURL, prompt: Text("https://overpass.dunkirk.sh"))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }

                Section("Authentication") {
                    if hasApiKey {
                        Label("API key registered", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Button("Reset API key", role: .destructive) {
                            KeychainService.delete(forKey: "user_api_key")
                            hasApiKey = false
                        }
                    } else {
                        SecureField("Device secret", text: $deviceSecret)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        Button(isRegistering ? "Registering…" : "Register API key") {
                            Task { await register() }
                        }
                        .disabled(isRegistering || deviceSecret.isEmpty || baseURL.isEmpty)

                        if let error = registrationError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("Developer")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            baseURL = api.baseURL
            deviceSecret = KeychainService.load(forKey: "device_secret") ?? ""
            hasApiKey = KeychainService.load(forKey: "user_api_key") != nil
        }
        .onChange(of: baseURL) { _, new in api.baseURL = new }
        .onChange(of: deviceSecret) { _, new in
            if new.isEmpty {
                KeychainService.delete(forKey: "device_secret")
            } else {
                KeychainService.save(new, forKey: "device_secret")
            }
        }
    }

    private func register() async {
        isRegistering = true
        registrationError = nil
        do {
            try await api.registerKey()
            hasApiKey = true
        } catch {
            registrationError = error.localizedDescription
        }
        isRegistering = false
    }
}
