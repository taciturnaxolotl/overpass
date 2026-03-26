import Foundation

struct Price: Codable, Identifiable {
    var id: String { nickname }
    let nickname: String
    let formattedPrice: String?
    let postedTime: String?

    // "$3.29" → 3.29
    var numericPrice: Double? {
        guard let fp = formattedPrice, fp.hasPrefix("$") else { return nil }
        return Double(fp.dropFirst())
    }
}

struct Station: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let lat: Double
    let lng: Double
    let address: String?
    let city: String?
    let state: String?
    let zip: String?
    let prices: [Price]
    let fetchedAt: Int64

    var regularPrice: Price? {
        prices.first { $0.nickname == "Regular" }
    }

    var isStale: Bool {
        let ageMs = Int64(Date().timeIntervalSince1970 * 1000) - fetchedAt
        return ageMs > 6 * 60 * 60 * 1000
    }
}

struct HealthResponse: Codable {
    let ok: Bool
    let cachedStations: Int
    let oldestFetch: String?
    let newestFetch: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case cachedStations = "cached_stations"
        case oldestFetch = "oldest_fetch"
        case newestFetch = "newest_fetch"
    }
}

struct PrefetchResponse: Codable {
    struct Bbox: Codable {
        let minLat: Double
        let minLng: Double
        let maxLat: Double
        let maxLng: Double
    }
    let bbox: Bbox
    let samples: Int
    let stations: [Station]
    let count: Int
    let cachedAt: Int64

    enum CodingKeys: String, CodingKey {
        case bbox, samples, stations, count
        case cachedAt = "cached_at"
    }
}
