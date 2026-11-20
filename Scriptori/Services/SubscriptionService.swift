import CryptoKit
import Foundation
import Observation
import ScriptoriKit
import StoreKit
import UIKit

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
    /// The transaction behind `status`, for deciding which account it belongs to.
    private(set) var entitlement: SubscriptionEntitlement?
    private(set) var isEligibleForTrial = true
    private(set) var loadState: LoadState = .idle
    private(set) var hasResolvedEntitlements = false

    @ObservationIgnored var onStatusChange: (@MainActor (SubscriptionState) -> Void)?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var statusUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshRequested = false

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
        // Expiry and cancellation change the status without producing a transaction.
        statusUpdatesTask = Task.detached { [weak self] in
            for await _ in Product.SubscriptionInfo.Status.updates {
                await self?.refreshEntitlements()
            }
        }
        await loadProducts()
        await refreshEntitlements()
    }

    /// A cancelled subscription ends without any StoreKit event the app is guaranteed to
    /// see while it's open, so the entitlement is re-read the moment it runs out. Otherwise
    /// it would keep granting access, or keep other accounts locked out, until the next launch.
    /// The same goes for the end of a billing grace period.
    private func scheduleExpiryRefresh(for state: SubscriptionState, inGracePeriod: Bool) {
        expiryTask?.cancel()
        expiryTask = nil
        guard state.hasAccess, inGracePeriod || !state.willAutoRenew, let expiresAt = state.expiresAt else { return }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(expiresAt.timeIntervalSinceNow, 0) + 1))
            guard !Task.isCancelled, let self else { return }
            // Cleared first so the refresh doesn't cancel the task it is running in.
            self.expiryTask = nil
            await self.refreshEntitlements()
        }
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

    enum PurchaseError: LocalizedError {
        /// The App Store returned a transaction that failed StoreKit's signature check. The reader
        /// may still have been charged, so this must never be swallowed.
        case unverified
        case manageSubscriptionsUnavailable

        var errorDescription: String? {
            switch self {
            case .unverified: "We couldn't confirm your purchase. If you were charged, contact support."
            case .manageSubscriptionsUnavailable: "We couldn't open your subscriptions."
            }
        }
    }

    enum PurchaseOutcome {
        /// Paid for, and access is on.
        case unlocked
        /// Paid for, but the entitlement isn't usable (yet).
        case notUnlocked
        /// Not finished: it waits on Ask to Buy approval or on the buyer fixing a payment
        /// problem. If it goes through, it arrives later through `Transaction.updates`.
        case pending
        case cancelled
    }

    /// Throws `PurchaseError.unverified` when the App Store's transaction can't be verified.
    func purchase(_ product: Product, appAccountToken: UUID?) async throws -> PurchaseOutcome {
        var options: Set<Product.PurchaseOption> = []
        if let appAccountToken { options.insert(.appAccountToken(appAccountToken)) }

        switch try await product.purchase(options: options) {
        case .success(let verification):
            guard case .verified(let transaction) = verification else { throw PurchaseError.unverified }
            await transaction.finish()
            await refreshEntitlements()
            return status.hasAccess ? .unlocked : .notUnlocked
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .notUnlocked
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

    /// Apple's subscription management sheet. Used instead of SwiftUI's
    /// `.manageSubscriptionsSheet`, which fails silently, so a failure can be shown.
    func showManageSubscriptions() async throws {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let scene else { throw PurchaseError.manageSubscriptionsUnavailable }
        try await AppStore.showManageSubscriptions(in: scene)
    }

    func restorePurchases() async throws {
        try await AppStore.sync()
        await refreshEntitlements()
    }

    /// Re-reads what the Apple ID is entitled to. Requests never overlap: StoreKit reports one
    /// event (an approved Ask to Buy purchase, a renewal) through several channels at once, and
    /// a read that started before the event must not finish last and overwrite the newer answer.
    /// A request made while a read is running triggers one more read after it, and every caller
    /// returns only once a read that began after its request has finished.
    func refreshEntitlements() async {
        refreshRequested = true
        if let running = refreshTask {
            await running.value
            return
        }
        let task = Task {
            while refreshRequested {
                refreshRequested = false
                await readEntitlements()
            }
            refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    private func readEntitlements() async {
        await finishUnfinishedTransactions()
        var best: (transaction: Transaction, tier: SubscriptionTier, accessEnds: Date?, inGracePeriod: Bool)?
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement,
                  transaction.productType == .autoRenewable,
                  transaction.revocationDate == nil
            else { continue }
            var accessEnds = transaction.expirationDate
            var inGracePeriod = false
            if let paidUntil = accessEnds, paidUntil <= .now {
                // A failed renewal leaves the paid period over, but access continues while
                // Apple retries the charge during the billing grace period.
                guard let graceEnds = await gracePeriodEnd(for: transaction), graceEnds > .now else { continue }
                accessEnds = graceEnds
                inGracePeriod = true
            }
            let tier: SubscriptionTier = transaction.productID == ProductID.annual ? .annual : .monthly
            if best == nil || tier == .annual { best = (transaction, tier, accessEnds, inGracePeriod) }
        }

        var next = SubscriptionState.free
        if let best {
            next = SubscriptionState(
                tier: best.tier,
                isInTrial: Self.isIntroductoryOffer(best.transaction),
                expiresAt: best.accessEnds,
                willAutoRenew: await willAutoRenew(productID: best.transaction.productID)
            )
        }
        if let group = products.first?.subscription {
            isEligibleForTrial = await group.isEligibleForIntroOffer
        }

        hasResolvedEntitlements = true
        let nextEntitlement = best.map {
            SubscriptionEntitlement(
                originalTransactionID: String($0.transaction.originalID),
                purchaserToken: $0.transaction.appAccountToken
            )
        }
        if nextEntitlement != entitlement { entitlement = nextEntitlement }
        scheduleExpiryRefresh(for: next, inGracePeriod: best?.inGracePeriod ?? false)
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

    /// When the billing grace period of this subscription ends, or nil when it isn't in one.
    private func gracePeriodEnd(for transaction: Transaction) async -> Date? {
        guard let status = await transaction.subscriptionStatus, status.state == .inGracePeriod,
              case .verified(let renewal) = status.renewalInfo
        else { return nil }
        return renewal.gracePeriodExpirationDate
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
