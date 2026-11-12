import CryptoKit
import Foundation
import Observation
import ScriptoriKit
import StoreKit

/// StoreKit 2 entitlement manager. Both plans live in one subscription group and carry a
/// 3-day free introductory offer (configured in App Store Connect / `Scriptori.storekit`).
/// Access is decided on-device; any server-side mirror (App Store Server Notifications)
/// is for records only and must never gate access.
@Observable
@MainActor
final class SubscriptionService {
    enum ProductID {
        static let monthly = "com.scriptori.premium.monthly"
        static let annual = "com.scriptori.premium.annual"
        static let all = [monthly, annual]
    }

    enum LoadState: Equatable {
        case idle, loading, loaded, failed(String)
    }

    private(set) var products: [Product] = []
    private(set) var status: SubscriptionState = .free
    private(set) var isEligibleForTrial = true
    private(set) var loadState: LoadState = .idle
    private(set) var hasResolvedEntitlements = false

    @ObservationIgnored var onStatusChange: (@MainActor (SubscriptionState) -> Void)?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    var monthly: Product? { products.first { $0.id == ProductID.monthly } }
    var annual: Product? { products.first { $0.id == ProductID.annual } }

    /// Annual savings vs. paying monthly for 12 months, e.g. 20 for "Save 20%".
    var annualSavingsPercent: Int? {
        guard let monthly, let annual, monthly.price > 0 else { return nil }
        let yearlyAtMonthly = monthly.price * 12
        let savings = (yearlyAtMonthly - annual.price) / yearlyAtMonthly * 100
        return Int(NSDecimalNumber(decimal: savings).doubleValue.rounded())
    }

    func start() async {
        guard updatesTask == nil else { return }
        updatesTask = Task.detached { [weak self] in
            for await update in Transaction.updates {
                guard case .verified(let transaction) = update else { continue }
                await transaction.finish()
                await self?.refreshEntitlements()
            }
        }
        await loadProducts()
        await refreshEntitlements()
    }

    func loadProducts() async {
        loadState = .loading
        do {
            let fetched = try await Product.products(for: ProductID.all)
            products = fetched.sorted { $0.price > $1.price }
            if let group = fetched.first?.subscription {
                isEligibleForTrial = await group.isEligibleForIntroOffer
            }
            loadState = fetched.isEmpty ? .failed("No plans are available right now.") : .loaded
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    /// Returns `true` when the purchase completed and access is granted.
    func purchase(_ product: Product, appAccountToken: UUID?) async throws -> Bool {
        var options: Set<Product.PurchaseOption> = []
        if let appAccountToken { options.insert(.appAccountToken(appAccountToken)) }

        switch try await product.purchase(options: options) {
        case .success(let verification):
            guard case .verified(let transaction) = verification else { return false }
            await transaction.finish()
            await refreshEntitlements()
            return status.hasAccess
        case .pending, .userCancelled:
            return false
        @unknown default:
            return false
        }
    }

    /// Stable UUID derived from the account ID so App Store Server Notifications
    /// can be mapped back to the Scriptori user on the backend.
    static func appAccountToken(for userID: String) -> UUID {
        if let uuid = UUID(uuidString: userID) { return uuid }
        var bytes = Array(SHA256.hash(data: Data(userID.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    func restorePurchases() async throws {
        try await AppStore.sync()
        await refreshEntitlements()
    }

    func refreshEntitlements() async {
        await finishUnfinishedTransactions()
        var best: (transaction: Transaction, tier: SubscriptionTier)?
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement,
                  transaction.productType == .autoRenewable,
                  transaction.revocationDate == nil,
                  (transaction.expirationDate ?? .distantFuture) > .now
            else { continue }
            let tier: SubscriptionTier = transaction.productID == ProductID.annual ? .annual : .monthly
            if best == nil || tier == .annual { best = (transaction, tier) }
        }

        var next = SubscriptionState.free
        if let best {
            next = SubscriptionState(
                tier: best.tier,
                isInTrial: Self.isIntroductoryOffer(best.transaction),
                expiresAt: best.transaction.expirationDate,
                willAutoRenew: await willAutoRenew(productID: best.transaction.productID)
            )
        }
        if let group = products.first?.subscription {
            isEligibleForTrial = await group.isEligibleForIntroOffer
        }

        hasResolvedEntitlements = true
        if next != status {
            status = next
            onStatusChange?(next)
        }
    }

    /// `Transaction.updates` only replays unfinished transactions at launch, so renewals that land
    /// while the app is suspended would otherwise stay unfinished until the next cold start.
    private func finishUnfinishedTransactions() async {
        for await result in Transaction.unfinished {
            if case .verified(let transaction) = result { await transaction.finish() }
        }
    }

    private func willAutoRenew(productID: String) async -> Bool {
        guard let statuses = try? await products.first(where: { $0.id == productID })?.subscription?.status else { return false }
        return statuses.contains { status in
            if case .verified(let info) = status.renewalInfo { return info.willAutoRenew }
            return false
        }
    }

    private static func isIntroductoryOffer(_ transaction: Transaction) -> Bool {
        if #available(iOS 17.2, *) {
            return transaction.offer?.type == .introductory
        } else {
            return transaction.offerType == .introductory
        }
    }
}

extension Product {
    var periodLabel: String {
        guard let period = subscription?.subscriptionPeriod else { return "" }
        switch period.unit {
        case .year: return "year"
        case .month: return "month"
        case .week: return "week"
        case .day: return "day"
        @unknown default: return ""
        }
    }

    /// Annual price expressed per month, e.g. "$4.00/mo".
    var monthlyEquivalent: String? {
        guard subscription?.subscriptionPeriod.unit == .year else { return nil }
        return (price / 12).formatted(priceFormatStyle) + "/mo"
    }

    var hasFreeTrial: Bool {
        subscription?.introductoryOffer?.paymentMode == .freeTrial
    }
}
