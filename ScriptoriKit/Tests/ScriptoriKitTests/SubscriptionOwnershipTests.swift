import Foundation
import Testing
@testable import ScriptoriKit

struct SubscriptionOwnershipTests {
    private let buyerToken = UUID()
    private let otherToken = UUID()

    private func entitlement(purchaser: UUID?) -> SubscriptionEntitlement {
        SubscriptionEntitlement(originalTransactionID: "1000", purchaserToken: purchaser)
    }

    @Test func noSubscriptionIsNone() {
        #expect(SubscriptionOwnership.resolve(entitlement: nil, userToken: buyerToken) == .none)
    }

    @Test func buyerOwnsTheirPurchase() {
        #expect(SubscriptionOwnership.resolve(entitlement: entitlement(purchaser: buyerToken), userToken: buyerToken) == .mine)
    }

    @Test func secondAccountOnSameAppleIDIsLockedOut() {
        #expect(SubscriptionOwnership.resolve(entitlement: entitlement(purchaser: buyerToken), userToken: otherToken) == .other)
    }

    @Test func purchaseWithoutAnAccountIsOpenToAnyone() {
        #expect(SubscriptionOwnership.resolve(entitlement: entitlement(purchaser: nil), userToken: otherToken) == .mine)
    }

    @Test func deletedBuyerReleasesTheirPurchase() {
        let ownership = SubscriptionOwnership.resolve(
            entitlement: entitlement(purchaser: buyerToken), userToken: otherToken, releasedPurchasers: [buyerToken]
        )
        #expect(ownership == .mine)
    }

    @Test func activeSubscriptionBlocksNewAccounts() {
        #expect(SubscriptionOwnership.isLocked(entitlement(purchaser: buyerToken)))
    }

    @Test func newAccountsAreAllowedWithoutALockedSubscription() {
        #expect(!SubscriptionOwnership.isLocked(nil))
        #expect(!SubscriptionOwnership.isLocked(entitlement(purchaser: nil)))
        #expect(!SubscriptionOwnership.isLocked(entitlement(purchaser: buyerToken), releasedPurchasers: [buyerToken]))
    }

    @Test func releaseDoesNotOpenSomeoneElsesPurchase() {
        let thirdToken = UUID()
        let ownership = SubscriptionOwnership.resolve(
            entitlement: entitlement(purchaser: buyerToken), userToken: otherToken, releasedPurchasers: [thirdToken]
        )
        #expect(ownership == .other)
    }
}
