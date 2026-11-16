import Foundation

/// The active App Store subscription on this device, reduced to what's needed to decide
/// which Scriptori account it belongs to.
public struct SubscriptionEntitlement: Hashable, Sendable {
    /// Stable for the life of the subscription, across renewals, upgrades and resubscribing.
    public let originalTransactionID: String
    /// `appAccountToken` of the account that made the purchase. `nil` for purchases made
    /// outside the app (offer codes, Family Sharing), which no account owns.
    public let purchaserToken: UUID?

    public init(originalTransactionID: String, purchaserToken: UUID?) {
        self.originalTransactionID = originalTransactionID
        self.purchaserToken = purchaserToken
    }
}

/// A subscription is bought by an Apple ID but locked to the Scriptori account that bought it.
/// The purchase itself carries the buyer (`appAccountToken`), so every device on that Apple ID
/// reaches the same answer without a backend.
public enum SubscriptionOwnership: Hashable, Sendable {
    /// No active subscription.
    case none
    /// The signed-in account may use the subscription.
    case mine
    /// The subscription is active but locked to another account.
    case other

    /// - Parameters:
    ///   - userToken: the signed-in account's `appAccountToken`.
    ///   - releasedPurchasers: tokens of accounts deleted on this device while they held a
    ///     subscription. Their purchases are open to any account, so a subscription that is
    ///     still billing isn't stranded behind an account that no longer exists.
    public static func resolve(
        entitlement: SubscriptionEntitlement?,
        userToken: UUID,
        releasedPurchasers: Set<UUID> = []
    ) -> SubscriptionOwnership {
        guard let entitlement else { return .none }
        guard let purchaser = entitlement.purchaserToken, !releasedPurchasers.contains(purchaser) else { return .mine }
        return purchaser == userToken ? .mine : .other
    }
}
