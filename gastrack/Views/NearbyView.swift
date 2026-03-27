import SwiftUI
import CoreLocation

private enum SortMode: String, CaseIterable {
    case closest   = "Closest"
    case cheapest  = "Cheapest"
    case balanced  = "Best Value"
}

struct NearbyView: View {
    @StateObject private var location = LocationManager.shared
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var store: StationStore

    @AppStorage("balance_mpg") private var balanceMpg: Double = 28
    @AppStorage("balance_tank") private var balanceTank: Double = 12
    @State private var error: String?
    @State private var sortMode: SortMode = .balanced
    @State private var displayedStations: [Station] = []

    private let radiusKm = 16.0

    private func recompute() {
        guard let loc = location.location else { return }
        let nearby = store.stations(near: loc.coordinate, radiusKm: radiusKm)
        switch sortMode {
        case .closest:
            displayedStations = nearby
        case .cheapest:
            displayedStations = nearby.sorted { lhs, rhs in
                let a = lhs.regularPrice?.numericPrice ?? Double.infinity
                let b = rhs.regularPrice?.numericPrice ?? Double.infinity
                return a < b
            }
        case .balanced:
            displayedStations = nearby.sorted { lhs, rhs in
                balanceScore(lhs, from: loc) < balanceScore(rhs, from: loc)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let error, displayedStations.isEmpty {
                    ContentUnavailableView(error, systemImage: "antenna.radiowaves.left.and.right.slash")
                } else if displayedStations.isEmpty {
                    ContentUnavailableView("No stations found", systemImage: "fuelpump.slash")
                } else {
                    List(displayedStations) { station in
                        NavigationLink(destination: StationDetailView(station: station)) {
                            StationRow(station: station)
                        }
                    }
                    .refreshable { await loadLive() }
                }
            }
            .navigationTitle("Nearby")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Sort", selection: $sortMode) {
                            ForEach(SortMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "line.3.horizontal.decrease")
                    }
                }
            }
        }
        .task { await loadCached() }
        .onChange(of: location.location) { _, _ in
            recompute()
            if displayedStations.isEmpty { Task { await loadCached() } }
        }
        .onChange(of: store.byId.count) { _, _ in recompute() }
        .onChange(of: sortMode) { _, _ in recompute() }
        .onAppear {
            if location.authorizationStatus == .notDetermined {
                location.requestPermission()
            }
            location.startUpdating()
        }
    }

    private func balanceScore(_ station: Station, from loc: CLLocation) -> Double {
        let miles = loc.distance(from: CLLocation(latitude: station.lat, longitude: station.lng)) / 1609.34
        guard let price = station.regularPrice?.numericPrice else { return .infinity }
        // Effective price per gallon filled, accounting for round-trip fuel cost
        let roundTripFuelCost = (2 * miles / balanceMpg) * price
        return price + roundTripFuelCost / balanceTank
    }

    // Instant, works offline — merges into shared store.
    private func loadCached() async {
        guard let coord = location.location?.coordinate else {
            if location.authorizationStatus == .denied {
                error = "Location access denied"
            } else {
                error = "Waiting for location…"
            }
            return
        }
        error = nil
        if let results = try? await api.fetchNearby(lat: coord.latitude, lng: coord.longitude, radiusKm: radiusKm, cacheOnly: true) {
            store.merge(results)
            recompute()
        }
    }

    // Live — may call GasBuddy if cell is stale.
    private func loadLive() async {
        guard let coord = location.location?.coordinate else { return }
        error = nil
        do {
            let results = try await api.fetchNearby(lat: coord.latitude, lng: coord.longitude, radiusKm: radiusKm)
            store.merge(results)
            recompute()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
