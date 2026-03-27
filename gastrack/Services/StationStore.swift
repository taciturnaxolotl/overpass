import Combine
import CoreLocation
import GRDB
import MapKit

// MARK: - GRDB conformance for Station

extension Station: FetchableRecord {
    nonisolated init(row: Row) throws {
        let pricesJson: String = row["prices_json"]
        let prices = (try? JSONDecoder().decode([Price].self, from: Data(pricesJson.utf8))) ?? []
        self.init(
            id: row["id"],
            name: row["name"],
            lat: row["lat"],
            lng: row["lng"],
            address: row["address"],
            city: row["city"],
            state: row["state"],
            zip: row["zip"],
            prices: prices,
            fetchedAt: row["fetched_at"]
        )
    }
}

extension Station: PersistableRecord {
    static let databaseTableName = "stations"

    nonisolated func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["name"] = name
        container["lat"] = lat
        container["lng"] = lng
        container["address"] = address
        container["city"] = city
        container["state"] = state
        container["zip"] = zip
        container["prices_json"] = String(data: (try? JSONEncoder().encode(prices)) ?? Data(), encoding: .utf8) ?? "[]"
        container["fetched_at"] = fetchedAt
    }
}

// MARK: - Store

@MainActor
final class StationStore: ObservableObject {
    static let shared = StationStore()

    @Published private(set) var byId: [String: Station] = [:]
    private let db: DatabaseQueue

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = (try? DatabaseQueue(path: dir.appendingPathComponent("stations.sqlite").path)) ?? (try! DatabaseQueue())

        try? db.write { d in
            try d.create(table: Station.databaseTableName, ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("lat", .double).notNull()
                t.column("lng", .double).notNull()
                t.column("address", .text)
                t.column("city", .text)
                t.column("state", .text)
                t.column("zip", .text)
                t.column("prices_json", .text).notNull()
                t.column("fetched_at", .integer).notNull()
            }
            try d.create(index: "idx_stations_lat_lng", on: Station.databaseTableName, columns: ["lat", "lng"], ifNotExists: true)
        }

        if let all = try? db.read({ try Station.fetchAll($0) }) {
            for s in all { byId[s.id] = s }
        }
    }

    // MARK: - Mutations

    func merge(_ stations: [Station]) {
        try? db.write { d in
            for s in stations { try s.save(d) }
        }
        for s in stations { byId[s.id] = s }
    }

    /// Upserts incoming stations and removes any previously cached stations
    /// in the same area that the server no longer returns.
    func replace(_ incoming: [Station], near center: CLLocationCoordinate2D, radiusKm: Double) {
        let incomingIds = Set(incoming.map { $0.id })
        let latDelta = radiusKm / 111.0
        let lngDelta = radiusKm / (111.0 * cos(center.latitude * .pi / 180))
        let stale = byId.values.filter { s in
            abs(s.lat - center.latitude) <= latDelta &&
            abs(s.lng - center.longitude) <= lngDelta &&
            !incomingIds.contains(s.id)
        }
        try? db.write { d in
            for s in stale   { try Station.deleteOne(d, key: s.id) }
            for s in incoming { try s.save(d) }
        }
        for s in stale   { byId.removeValue(forKey: s.id) }
        for s in incoming { byId[s.id] = s }
    }

    func clear() {
        _ = try? db.write { try Station.deleteAll($0) }
        byId = [:]
    }

    // MARK: - Queries

    func stations(near coord: CLLocationCoordinate2D, radiusKm: Double) -> [Station] {
        let latDelta = radiusKm / 111.0
        let lngDelta = radiusKm / (111.0 * cos(coord.latitude * .pi / 180))
        let userLoc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        return byId.values
            .filter {
                abs($0.lat - coord.latitude) <= latDelta &&
                abs($0.lng - coord.longitude) <= lngDelta
            }
            .sorted {
                CLLocation(latitude: $0.lat, longitude: $0.lng).distance(from: userLoc) <
                CLLocation(latitude: $1.lat, longitude: $1.lng).distance(from: userLoc)
            }
    }

    func stations(in region: MKCoordinateRegion) -> [Station] {
        let minLat = region.center.latitude - region.span.latitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        let minLng = region.center.longitude - region.span.longitudeDelta / 2
        let maxLng = region.center.longitude + region.span.longitudeDelta / 2
        return byId.values.filter {
            $0.lat >= minLat && $0.lat <= maxLat &&
            $0.lng >= minLng && $0.lng <= maxLng
        }
    }
}
