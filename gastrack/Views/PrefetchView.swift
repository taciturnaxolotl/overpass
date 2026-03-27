import Combine
import SwiftUI
import MapKit
import CoreLocation

// MARK: - Completer

private final class SearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let inner = MKLocalSearchCompleter()

    override init() {
        super.init()
        inner.delegate = self
        inner.resultTypes = [.address, .pointOfInterest]
    }

    func query(_ text: String, near region: MKCoordinateRegion?) {
        if let r = region { inner.region = r }
        inner.queryFragment = text
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = Array(completer.results.prefix(6))
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }
}

// MARK: - View

struct PrefetchView: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var store: StationStore
    @StateObject private var location = LocationManager.shared
    @StateObject private var completer = SearchCompleter()

    enum ActiveField { case from, to }

    @AppStorage("route_from_text") private var fromText: String = ""
    @AppStorage("route_to_text") private var toText: String = ""
    @AppStorage("route_to_lat") private var toLatSaved: Double = 0
    @AppStorage("route_to_lng") private var toLngSaved: Double = 0
    @AppStorage("route_from_lat") private var fromLatSaved: Double = 0
    @AppStorage("route_from_lng") private var fromLngSaved: Double = 0

    @FocusState private var focused: ActiveField?
    @State private var fromItem: MKMapItem?   // nil = current location
    @State private var toItem: MKMapItem?
    @State private var route: MKRoute?
    @State private var routePosition: MapCameraPosition = .automatic
    @State private var isPrefetching = false
    @State private var prefetchResult: (stations: Int, samples: Int)?
    @State private var errorMsg: String?

    var body: some View {
        NavigationStack {
            List {
                // ── Route inputs ──
                Section {
                    locationRow(
                        systemImage: "circle.fill",
                        tint: .blue,
                        text: $fromText,
                        placeholder: "Current location",
                        field: .from
                    )
                    locationRow(
                        systemImage: "mappin.circle.fill",
                        tint: .red,
                        text: $toText,
                        placeholder: "Destination",
                        field: .to
                    )
                }

                // ── Autocomplete suggestions ──
                if focused != nil && !completer.results.isEmpty {
                    Section {
                        ForEach(completer.results, id: \.self) { c in
                            Button { pick(c) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.title).foregroundStyle(.primary)
                                    if !c.subtitle.isEmpty {
                                        Text(c.subtitle).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                // ── Route preview ──
                if let route {
                    Section {
                        Map(position: $routePosition) {
                            MapPolyline(route.polyline)
                                .stroke(.blue, lineWidth: 3)
                        }
                        .frame(height: 180)
                        .listRowInsets(.init())
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                        HStack(spacing: 24) {
                            Label(String(format: "%.0f km", route.distance / 1000), systemImage: "arrow.left.and.right")
                            Label(formatDuration(route.expectedTravelTime), systemImage: "clock")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }

                // ── Prefetch button ──
                Section {
                    Button {
                        Task { await prefetch() }
                    } label: {
                        HStack {
                            Spacer()
                            if isPrefetching {
                                ProgressView().tint(.white)
                                Text("Caching stations…").foregroundStyle(.white)
                            } else {
                                Label("Prefetch Route", systemImage: "arrow.down.circle.fill")
                                    .foregroundStyle(.white)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(toItem != nil && !isPrefetching ? Color.accentColor : Color.secondary)
                    .disabled(toItem == nil || isPrefetching)
                }

                // ── Error / result ──
                if let errorMsg {
                    Section {
                        Label(errorMsg, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                if let r = prefetchResult {
                    Section("Last Prefetch") {
                        LabeledContent("Stations cached", value: "\(r.stations)")
                        LabeledContent("New cells fetched", value: "\(r.samples)")
                    }
                }
            }
            .navigationTitle("Prefetch Route")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await restoreRoute() }
    }

    private func restoreRoute() async {
        guard route == nil else { return }
        if toLatSaved != 0 && toLngSaved != 0 {
            let toCoord = CLLocationCoordinate2D(latitude: toLatSaved, longitude: toLngSaved)
            toItem = MKMapItem(location: CLLocation(latitude: toCoord.latitude, longitude: toCoord.longitude), address: nil)
        }
        if fromLatSaved != 0 && fromLngSaved != 0 {
            let fromCoord = CLLocationCoordinate2D(latitude: fromLatSaved, longitude: fromLngSaved)
            fromItem = MKMapItem(location: CLLocation(latitude: fromCoord.latitude, longitude: fromCoord.longitude), address: nil)
        }
        if toItem != nil { await fetchRoute() }
    }

    // MARK: - Row

    @ViewBuilder
    private func locationRow(
        systemImage: String,
        tint: Color,
        text: Binding<String>,
        placeholder: String,
        field: ActiveField
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 24)

            TextField(placeholder, text: text)
                .focused($focused, equals: field)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .submitLabel(field == .from ? .next : .search)
                .onChange(of: text.wrappedValue) { _, new in
                    if focused == field {
                        completer.query(new, near: location.location.map {
                            MKCoordinateRegion(center: $0.coordinate, latitudinalMeters: 500_000, longitudinalMeters: 500_000)
                        })
                    }
                    if new.isEmpty {
                        if field == .from { fromItem = nil }
                        if field == .to { toItem = nil; route = nil }
                    }
                }
                .onSubmit { if field == .from { focused = .to } }

            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                    if field == .from { fromItem = nil }
                    if field == .to { toItem = nil; route = nil }
                    completer.results = []
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Actions

    private func pick(_ completion: MKLocalSearchCompletion) {
        let field = focused
        focused = nil
        completer.results = []
        Task {
            let req = MKLocalSearch.Request(completion: completion)
            guard let item = try? await MKLocalSearch(request: req).start().mapItems.first else { return }
            let coord = item.location.coordinate
            if field == .from {
                fromText = completion.title
                fromItem = item
                fromLatSaved = coord.latitude
                fromLngSaved = coord.longitude
            } else {
                toText = completion.title
                toItem = item
                toLatSaved = coord.latitude
                toLngSaved = coord.longitude
            }
            await fetchRoute()
        }
    }

    private func fetchRoute() async {
        guard let dest = toItem else { return }
        let src = fromItem ?? .forCurrentLocation()
        let req = MKDirections.Request()
        req.source = src
        req.destination = dest
        req.transportType = .automobile
        guard let r = try? await MKDirections(request: req).calculate().routes.first else { return }
        route = r
        let rect = r.polyline.boundingMapRect
        routePosition = .rect(rect.insetBy(dx: -rect.size.width * 0.15, dy: -rect.size.height * 0.15))
    }

    private func prefetch() async {
        guard let dest = toItem else { return }
        errorMsg = nil
        isPrefetching = true

        let currentRoute: MKRoute
        if let r = route {
            currentRoute = r
        } else {
            let req = MKDirections.Request()
            req.source = fromItem ?? .forCurrentLocation()
            req.destination = dest
            req.transportType = .automobile
            guard let r = try? await MKDirections(request: req).calculate().routes.first else {
                errorMsg = "Could not calculate route"
                isPrefetching = false
                return
            }
            currentRoute = r
            route = r
        }

        let points = extractPoints(from: currentRoute.polyline, maxPoints: 400)
        do {
            let response = try await api.prefetchRoute(points: points)
            store.merge(response.stations)
            prefetchResult = (stations: response.count, samples: response.samples)
            if let json = String(data: (try? JSONEncoder().encode(points)) ?? Data(), encoding: .utf8) {
                UserDefaults.standard.set(json, forKey: "route_points")
            }
            BackgroundRefreshService.markRouteRefreshed()
        } catch {
            errorMsg = error.localizedDescription
        }
        isPrefetching = false
    }

    // MARK: - Helpers

    private func extractPoints(from polyline: MKPolyline, maxPoints: Int) -> [[Double]] {
        let count = polyline.pointCount
        let step = Swift.max(1, Int(ceil(Double(count) / Double(maxPoints))))
        var coords = [CLLocationCoordinate2D](repeating: .init(), count: count)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        var result: [[Double]] = []
        var i = 0
        while i < count {
            result.append([coords[i].latitude, coords[i].longitude])
            i += step
        }
        return result
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m) min"
    }
}
