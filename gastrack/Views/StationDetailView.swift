import SwiftUI
import MapKit
import CoreLocation

struct StationDetailView: View {
    let station: Station
    @EnvironmentObject private var eia: EIAService
    @StateObject private var location = LocationManager.shared

    private var otherPrices: [Price] {
        station.prices.filter { $0.nickname != "Regular" && $0.formattedPrice != nil }
    }

    var body: some View {
        List {
            // ── Hero: regular price ──
            Section {
                VStack(spacing: 6) {
                    if let regular = station.regularPrice, let fp = regular.formattedPrice {
                        Text(fp)
                            .font(.system(size: 64, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text("Regular")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let dev = eia.deviation(for: station) {
                            Text(deviationLabel(dev))
                                .font(.callout.bold())
                                .foregroundStyle(dev < 0 ? .green : .red)
                                .padding(.top, 2)
                        }
                    } else {
                        Text("No price reported")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            // ── Other fuel prices ──
            if !otherPrices.isEmpty {
                Section {
                    ForEach(otherPrices) { price in
                        HStack {
                            Text(price.nickname)
                                .font(.subheadline)
                            Spacer()
                            Text(price.formattedPrice!)
                                .font(.subheadline.bold())
                        }
                    }
                }
            }

            // ── Map + address ──
            let date = Date(timeIntervalSince1970: Double(station.fetchedAt) / 1000)
            Section {
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: station.lat, longitude: station.lng),
                    latitudinalMeters: 400, longitudinalMeters: 400
                ))) {
                    Marker(station.name, coordinate: CLLocationCoordinate2D(latitude: station.lat, longitude: station.lng))
                }
                .allowsHitTesting(false)
                .frame(height: 160)
                .listRowInsets(.init())

                Button(action: openInMaps) {
                    HStack(spacing: 10) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            if let address = station.address {
                                Text(address)
                            }
                            if let city = station.city, let state = station.state {
                                Text("\(city), \(state) \(station.zip ?? "")".trimmingCharacters(in: .whitespaces))
                                    .foregroundStyle(.secondary)
                            }
                            if let dist = distanceMiles {
                                Text(dist)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            } footer: {
                HStack(spacing: 6) {
                    Text("Fetched \(date.formatted(.relative(presentation: .named)))")
                    if station.isStale {
                        Label("May be outdated", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .navigationTitle(station.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var distanceMiles: String? {
        guard let loc = location.location else { return nil }
        let meters = loc.distance(from: CLLocation(latitude: station.lat, longitude: station.lng))
        let miles = meters / 1609.34
        return miles < 10 ? String(format: "%.1f mi away", miles) : String(format: "%.0f mi away", miles)
    }

    private func openInMaps() {
        let item = MKMapItem(location: CLLocation(latitude: station.lat, longitude: station.lng), address: nil)
        item.name = station.name
        item.openInMaps()
    }

    private func deviationLabel(_ dev: Double) -> String {
        let prefix = dev < 0 ? "-" : "+"
        return "\(prefix)$\(String(format: "%.2f", abs(dev))) vs state avg"
    }
}
