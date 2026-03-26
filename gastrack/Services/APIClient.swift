import Combine
import Foundation

enum APIError: LocalizedError {
    case notConfigured
    case httpError(Int, String)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "API not configured — no user key"
        case .httpError(let code, let msg): return "HTTP \(code): \(msg)"
        case .decodingError(let e): return "Decode error: \(e.localizedDescription)"
        }
    }
}

final class APIClient: ObservableObject {
    static let shared = APIClient()

    // Base URL of the gastrack server on Tailscale
    var baseURL: String {
        get { UserDefaults.standard.string(forKey: "gastrack_base_url") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "gastrack_base_url") }
    }

    var userKey: String? {
        KeychainService.load(forKey: "user_api_key")
    }

    var deviceSecret: String? {
        KeychainService.load(forKey: "device_secret")
    }

    // Register a new user key using the device secret. Call on first launch.
    func registerKey(email: String? = nil) async throws {
        guard let secret = deviceSecret else {
            throw APIError.notConfigured
        }
        let url = try endpoint("/keys/register")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["email": email])

        let (data, response) = try await URLSession.shared.data(for: req)
        try checkStatus(response, data)

        let body = try JSONDecoder().decode([String: String].self, from: data)
        if let key = body["key"] {
            KeychainService.save(key, forKey: "user_api_key")
        }
    }

    func fetchNearby(lat: Double, lng: Double, radiusKm: Double = 8, cacheOnly: Bool = false) async throws -> [Station] {
        var comps = try urlComponents("/stations/nearby")
        comps.queryItems = [
            .init(name: "lat", value: "\(lat)"),
            .init(name: "lng", value: "\(lng)"),
            .init(name: "radius_km", value: "\(radiusKm)"),
        ]
        if cacheOnly { comps.queryItems?.append(.init(name: "cache_only", value: "true")) }
        return try await get(comps.url!)
    }

    func fetchBbox(minLat: Double, minLng: Double, maxLat: Double, maxLng: Double) async throws -> [Station] {
        var comps = try urlComponents("/stations/bbox")
        comps.queryItems = [
            .init(name: "min_lat", value: "\(minLat)"),
            .init(name: "min_lng", value: "\(minLng)"),
            .init(name: "max_lat", value: "\(maxLat)"),
            .init(name: "max_lng", value: "\(maxLng)"),
        ]
        return try await get(comps.url!)
    }

    func fetchHealth() async throws -> HealthResponse {
        return try await get(try endpoint("/health"))
    }

    func fetchEIAAverages() async throws -> [EIAAverage] {
        return try await get(try endpoint("/eia/averages"))
    }

    func prefetchRoute(points: [[Double]], intervalKm: Double = 8) async throws -> PrefetchResponse {
        let url = try endpoint("/prefetch/route")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try attachUserKey(&req)

        let body: [String: Any] = ["points": points, "interval_km": intervalKm]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try checkStatus(response, data)
        return try decode(data)
    }

    // MARK: - Helpers

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var req = URLRequest(url: url)
        try attachUserKey(&req)
        let (data, response) = try await URLSession.shared.data(for: req)
        try checkStatus(response, data)
        return try decode(data)
    }

    private func attachUserKey(_ req: inout URLRequest) throws {
        guard let key = userKey else { throw APIError.notConfigured }
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }

    private func endpoint(_ path: String) throws -> URL {
        guard let url = URL(string: baseURL + path) else {
            throw APIError.notConfigured
        }
        return url
    }

    private func urlComponents(_ path: String) throws -> URLComponents {
        guard let comps = URLComponents(string: baseURL + path) else {
            throw APIError.notConfigured
        }
        return comps
    }

    private func checkStatus(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            // Try to parse a JSON error message; fall back to generic status text
            let msg: String
            if let json = try? JSONDecoder().decode([String: String].self, from: data),
               let error = json["error"] {
                msg = error
            } else {
                msg = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            }
            throw APIError.httpError(http.statusCode, msg)
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }
}
