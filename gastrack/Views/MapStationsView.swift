import SwiftUI
import MapKit

// MARK: - Annotation model

final class StationAnnotation: NSObject, MKAnnotation {
    let station: Station
    @objc dynamic var coordinate: CLLocationCoordinate2D
    @objc var title: String?

    init(_ station: Station) {
        self.station = station
        self.coordinate = CLLocationCoordinate2D(latitude: station.lat, longitude: station.lng)
        self.title = station.regularPrice?.formattedPrice
        super.init()
    }
}

// MARK: - UIViewRepresentable

struct NativeMapView: UIViewRepresentable {
    let stations: [Station]
    let tint: (Station) -> UIColor
    @Binding var selectedStation: Station?
    let onRegionChanged: (MKCoordinateRegion) -> Void

    // Populated by AppDelegate before any view renders.
    static var prewarmedView: MKMapView?

    func makeUIView(context: Context) -> MKMapView {
        let map: MKMapView
        if let prewarmed = Self.prewarmedView {
            map = prewarmed
            Self.prewarmedView = nil
            map.removeFromSuperview()   // detach from prewarm window
            (UIApplication.shared.delegate as? AppDelegate)?.teardownPrewarmWindow()
        } else {
            map = MKMapView()
        }
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        map.showsScale = true
        map.userTrackingMode = .none
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync(map)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: NativeMapView
        private var cache: [String: StationAnnotation] = [:]
        private var centeredOnUser = false

        init(_ parent: NativeMapView) {
            self.parent = parent
        }

        func sync(_ map: MKMapView) {
            let newIds = Set(parent.stations.map { $0.id })
            let oldIds = Set(cache.keys)

            let stale = cache.filter { !newIds.contains($0.key) }.map { $0.value }
            if !stale.isEmpty {
                map.removeAnnotations(stale)
                stale.forEach { cache.removeValue(forKey: $0.station.id) }
            }

            var toAdd: [StationAnnotation] = []
            for station in parent.stations where !oldIds.contains(station.id) {
                let ann = StationAnnotation(station)
                cache[station.id] = ann
                toAdd.append(ann)
            }
            if !toAdd.isEmpty { map.addAnnotations(toAdd) }

            // Refresh tints only on already-visible annotation views (no iteration over all stations)
            for ann in map.annotations.compactMap({ $0 as? StationAnnotation }) {
                guard let view = map.view(for: ann) as? MKMarkerAnnotationView else { continue }
                view.markerTintColor = parent.tint(ann.station)
            }

            // Sync selection
            let wantId = parent.selectedStation?.id
            let haveId = (map.selectedAnnotations.first as? StationAnnotation)?.station.id
            guard wantId != haveId else { return }
            if wantId == nil {
                map.selectedAnnotations.forEach { map.deselectAnnotation($0, animated: false) }
            } else if let ann = cache[wantId!] {
                map.selectAnnotation(ann, animated: true)
            }
        }

        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let ann = annotation as? StationAnnotation else { return nil }
            let view = (map.dequeueReusableAnnotationView(withIdentifier: "s") as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: ann, reuseIdentifier: "s")
            view.annotation = ann
            view.glyphImage = UIImage(systemName: "fuelpump.fill")
            view.markerTintColor = parent.tint(ann.station)
            view.titleVisibility = .visible
            view.canShowCallout = false
            return view
        }

        func mapView(_ map: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard !centeredOnUser else { return }
            centeredOnUser = true
            let region = MKCoordinateRegion(center: userLocation.coordinate,
                                            latitudinalMeters: 16_000, longitudinalMeters: 16_000)
            map.setRegion(region, animated: false)
        }

        func mapView(_ map: MKMapView, regionDidChangeAnimated animated: Bool) {
            parent.onRegionChanged(map.region)
        }

        func mapView(_ map: MKMapView, didSelect annotation: MKAnnotation) {
            guard let ann = annotation as? StationAnnotation else { return }
            parent.selectedStation = ann.station
        }

        func mapView(_ map: MKMapView, didDeselect annotation: MKAnnotation) {
            if (annotation as? StationAnnotation)?.station.id == parent.selectedStation?.id {
                parent.selectedStation = nil
            }
        }
    }
}

// MARK: - MapStationsView

struct MapStationsView: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var eia: EIAService
    @StateObject private var location = LocationManager.shared

    @State private var visibleRegion: MKCoordinateRegion?
    @State private var stations: [Station] = []
    @State private var displayedStations: [Station] = []
    @State private var selectedStation: Station?
    @State private var isLoading = false
    @State private var error: String?
    @State private var lastAutoLoad: Date = .distantPast
    @State private var showNativeMap = false
    @State private var mapReady = false

    var body: some View {
        NavigationStack {
            ZStack {
                if showNativeMap {
                    NativeMapView(
                        stations: displayedStations,
                        tint: { markerTintColor(for: $0) },
                        selectedStation: $selectedStation,
                        onRegionChanged: { region in
                            visibleRegion = region
                            mapReady = true
                            updateDisplayed()
                            Task { await autoLoad() }
                        }
                    )
                    .ignoresSafeArea()
                }
                if !mapReady {
                    Color(uiColor: .systemBackground).ignoresSafeArea()
                    ProgressView("Loading map…")
                }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await loadVisible(live: true) } } label: {
                        if isLoading { ProgressView() }
                        else { Label("Refresh area", systemImage: "arrow.clockwise") }
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
            DispatchQueue.main.async { showNativeMap = true }
        }
        .task { await autoLoad() }
    }

    private func markerTintColor(for station: Station) -> UIColor {
        if station.isStale { return .gray }
        if let dev = eia.deviation(for: station) {
            if dev < -0.05 { return .systemGreen }
            if dev >  0.05 { return .systemRed }
            return .systemYellow
        }
        return .systemGreen
    }

    private func updateDisplayed() {
        guard stations.count > 15, let region = visibleRegion else {
            displayedStations = stations; return
        }
        let minSep = min(region.span.latitudeDelta, region.span.longitudeDelta) / 8.0
        let sorted = stations.sorted {
            ($0.regularPrice?.numericPrice ?? .infinity) < ($1.regularPrice?.numericPrice ?? .infinity)
        }
        var occupied = Set<SIMD2<Int32>>()
        var kept: [Station] = []
        for s in sorted {
            let r = Int32(floor(s.lat / minSep))
            let c = Int32(floor(s.lng / minSep))
            var crowded = false
            outer: for dr: Int32 in -1...1 {
                for dc: Int32 in -1...1 {
                    if occupied.contains(SIMD2(r &+ dr, c &+ dc)) { crowded = true; break outer }
                }
            }
            if !crowded { kept.append(s); occupied.insert(SIMD2(r, c)) }
        }
        displayedStations = kept
    }

    private func autoLoad() async {
        let storeRegion = visibleRegion ?? location.location.map {
            MKCoordinateRegion(center: $0.coordinate, latitudinalMeters: 16_000, longitudinalMeters: 16_000)
        }
        if let region = storeRegion {
            let fromStore = StationStore.shared.stations(in: region)
            if !fromStore.isEmpty {
                stations = fromStore
                Task { @MainActor in updateDisplayed() }
            }
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
        if live && latSpan * lngSpan > 0.5 { error = "Zoom in to refresh stations"; return }
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
                updateDisplayed()
            } catch { self.error = error.localizedDescription }
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
            updateDisplayed()
        }
    }
}

extension Station: Hashable {
    static func == (lhs: Station, rhs: Station) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
