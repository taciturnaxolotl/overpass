import Foundation
import Observation
import StoreKit

@MainActor
@Observable
final class StoreManager {
    static let shared = StoreManager()

    private(set) var isUnlocked = false
    private(set) var justPurchased = false
    var isAppActive = false
    private(set) var purchaseDate: Date?
    private(set) var product: Product?
    private(set) var isPurchasing = false

    private let productId = "sh.dunkirk.overpass.unlock"
    private let firstLaunchKeychainKey = "sh.dunkirk.overpass.first_launch"
    static let trialDuration: TimeInterval = 15 * 24 * 60 * 60

    var trialStartDate: Date? {
        guard let stored = KeychainService.load(forKey: firstLaunchKeychainKey),
              let t = Double(stored) else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    var daysRemainingInTrial: Int {
        guard let start = trialStartDate else { return 0 }
        let remaining = Self.trialDuration - Date().timeIntervalSince(start)
        return max(0, Int(ceil(remaining / 86400)))
    }

    var isInTrial: Bool {
        guard !isUnlocked, let start = trialStartDate else { return false }
        return Date().timeIntervalSince(start) < Self.trialDuration
    }

    var hasAccess: Bool { isUnlocked || isInTrial }

    private var updatesTask: Task<Void, Never>?

    private init() {
        if KeychainService.load(forKey: firstLaunchKeychainKey) == nil {
            KeychainService.save("\(Date().timeIntervalSince1970)", forKey: firstLaunchKeychainKey)
        }
    }

    func load() async {
        updatesTask = Task { await listenForUpdates() }
        async let p: () = loadProduct()
        async let e: () = checkEntitlements()
        _ = await (p, e)
    }

    private func listenForUpdates() async {
        for await result in Transaction.updates {
            if case .verified(let tx) = result, tx.productID == productId {
                if tx.revocationDate != nil {
                    isUnlocked = false
                    purchaseDate = nil
                } else {
                    isUnlocked = true
                    purchaseDate = tx.purchaseDate
                    if isAppActive {
                        justPurchased = true
                        Task { try? await Task.sleep(for: .seconds(4)); justPurchased = false }
                    }
                }
                await tx.finish()
            }
        }
    }

    private func loadProduct() async {
        product = try? await Product.products(for: [productId]).first
    }

    private func checkEntitlements() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let tx) = result, tx.productID == productId {
                isUnlocked = true
                purchaseDate = tx.purchaseDate
                await tx.finish()
                return
            }
        }
    }

    func purchase() async throws {
        guard let product else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        let result = try await product.purchase()
        if case .success(let verification) = result,
           case .verified(let tx) = verification {
            isUnlocked = true
            purchaseDate = tx.purchaseDate
            justPurchased = true
            Task { try? await Task.sleep(for: .seconds(4)); justPurchased = false }
            await tx.finish()
        }
    }

    func restore() async {
        try? await AppStore.sync()
        await checkEntitlements()
    }
}
