import SwiftUI
import MapKit

struct MapStationsView: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var eia: EIAService
    @StateObject private var location = LocationManager.shared

    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var stations: [Station] = []
    @State private var selectedStation: Station?
    @State private var isLoading = false
    @State private var error: String?
    @State private var lastAutoLoad: Date = .distantPast

    var body: some View {
        NavigationStack {
            Map(position: $position, selection: $selectedStation) {
                ForEach(displayedStations) { station in
                    if let price = station.regularPrice?.formattedPrice {
                        Marker(price, systemImage: "fuelpump.fill", coordinate: CLLocationCoordinate2D(
                            latitude: station.lat,
                            longitude: station.lng
                        ))
                        .tint(markerTint(for: station))
                        .tag(station)
                    } else {
                        Marker(station.name, systemImage: "fuelpump", coordinate: CLLocationCoordinate2D(
                            latitude: station.lat,
                            longitude: station.lng
                        ))
                        .tint(.gray)
                        .tag(station)
                    }
                }
                UserAnnotation()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                visibleRegion = context.region
                Task { await autoLoad() }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await loadVisible(live: true) } } label: {
                        if isLoading {
                            ProgressView()
                        } else {
                            Label("Refresh area", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isLoading)
                }
            }
            .overlay(alignment: .bottom) {
                if let error {
                    Text(error)
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial)
                        .clipShape(Capsule())
                        .padding(.bottom, 8)
                }
            }
            .sheet(item: $selectedStation) { station in
                NavigationStack {
                    StationDetailView(station: station)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { selectedStation = nil }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
        }
        .onAppear {
            location.startUpdating()
            if let region = visibleRegion {
                let fromStore = StationStore.shared.stations(in: region)
                if !fromStore.isEmpty { stations = fromStore }
            }
        }
    }

    // Only thin when markers would actually crowd. Greedy by price so the
    // same stations are kept regardless of viewport position.
    private var displayedStations: [Station] {
        guard stations.count > 15, let region = visibleRegion else { return stations }

        // Minimum separation scales with zoom — roughly one marker-width apart.
        let minSep = min(region.span.latitudeDelta, region.span.longitudeDelta) / 8.0

        // Cheapest first; stations with no price go last.
        let sorted = stations.sorted {
            ($0.regularPrice?.numericPrice ?? .infinity) <
            ($1.regularPrice?.numericPrice ?? .infinity)
        }

        var kept: [Station] = []
        for station in sorted {
            let crowded = kept.contains {
                abs(station.lat - $0.lat) < minSep && abs(station.lng - $0.lng) < minSep
            }
            if !crowded { kept.append(station) }
        }
        return kept
    }

    private func markerTint(for station: Station) -> Color {
        if station.isStale { return .gray }
        if let dev = eia.deviation(for: station) {
            if dev < -0.05 { return .green }
            if dev > 0.05 { return .red }
            return .yellow
        }
        return .green
    }

    private func autoLoad() async {
        // Always show whatever the store already has — no network, no cooldown.
        if let region = visibleRegion {
            let fromStore = StationStore.shared.stations(in: region)
            if !fromStore.isEmpty { stations = fromStore }
        }

        guard Date().timeIntervalSince(lastAutoLoad) > 60 else { return }
        lastAutoLoad = Date()
        await loadVisible(live: false)
        Task { await loadVisible(live: true) }
    }

    private func loadVisible(live: Bool) async {
        let region = visibleRegion ?? {
            guard let loc = location.location else { return nil }
            return MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 16_000, longitudinalMeters: 16_000)
        }()
        guard let region else { return }

        let latSpan = region.span.latitudeDelta
        let lngSpan = region.span.longitudeDelta
        // Only enforce area cap for live fetches (cache reads are free).
        if live && latSpan * lngSpan > 0.5 {
            error = "Zoom in to refresh stations"
            return
        }
        error = nil

        let store = StationStore.shared
        if live {
            guard !isLoading else { return }
            isLoading = true
            do {
                let radiusKm = max(latSpan, lngSpan) * 111 / 2
                let results = try await api.fetchNearby(lat: region.center.latitude, lng: region.center.longitude, radiusKm: radiusKm)
                store.merge(results)
                stations = store.stations(in: region)
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        } else {
            let minLat = region.center.latitude - latSpan / 2
            let maxLat = region.center.latitude + latSpan / 2
            let minLng = region.center.longitude - lngSpan / 2
            let maxLng = region.center.longitude + lngSpan / 2
            if let results = try? await api.fetchBbox(minLat: minLat, minLng: minLng, maxLat: maxLat, maxLng: maxLng) {
                store.merge(results)
            }
            stations = store.stations(in: region)
        }
    }
}

extension Station: Hashable {
    static func == (lhs: Station, rhs: Station) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
