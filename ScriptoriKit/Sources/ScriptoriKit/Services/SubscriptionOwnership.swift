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

/// A subscription is bought by an Apple ID but used by one Scriptori account at a time.
/// It starts with the account that bought it and moves when another account claims it.
public enum SubscriptionOwnership: Hashable, Sendable {
    /// No active subscription.
    case none
    /// The signed-in account may use the subscription.
    case mine
    /// The subscription is active but belongs to another account until this one claims it.
    case other

    /// - Parameters:
    ///   - userToken: the signed-in account's `appAccountToken`.
    ///   - profileClaim: `UserProfile.claimedSubscriptionID`, which follows the account across devices.
    ///   - deviceClaims: original transaction ID → user ID of the last account to buy or claim it
    ///     on this device. Newest decision on the device, so it wins over everything else.
    public static func resolve(
        entitlement: SubscriptionEntitlement?,
        userID: String,
        userToken: UUID,
        profileClaim: String?,
        deviceClaims: [String: String]
    ) -> SubscriptionOwnership {
        guard let entitlement else { return .none }
        if let claimant = deviceClaims[entitlement.originalTransactionID] {
            return claimant == userID ? .mine : .other
        }
        if profileClaim == entitlement.originalTransactionID { return .mine }
        guard let purchaser = entitlement.purchaserToken else { return .mine }
        return purchaser == userToken ? .mine : .other
    }
}
