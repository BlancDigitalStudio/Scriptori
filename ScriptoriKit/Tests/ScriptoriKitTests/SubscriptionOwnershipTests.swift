import Foundation
import Testing
@testable import ScriptoriKit

struct SubscriptionOwnershipTests {
    private let buyerToken = UUID()
    private let otherToken = UUID()

    private func entitlement(purchaser: UUID?) -> SubscriptionEntitlement {
        SubscriptionEntitlement(originalTransactionID: "1000", purchaserToken: purchaser)
    }

    private func resolve(
        _ entitlement: SubscriptionEntitlement?,
        userID: String,
        token: UUID,
        profileClaim: String? = nil,
        deviceClaims: [String: String] = [:]
    ) -> SubscriptionOwnership {
        .resolve(entitlement: entitlement, userID: userID, userToken: token, profileClaim: profileClaim, deviceClaims: deviceClaims)
    }

    @Test func noSubscriptionIsNone() {
        #expect(resolve(nil, userID: "buyer", token: buyerToken) == .none)
    }

    @Test func buyerOwnsTheirPurchase() {
        #expect(resolve(entitlement(purchaser: buyerToken), userID: "buyer", token: buyerToken) == .mine)
    }

    @Test func secondAccountOnSameAppleIDMustClaim() {
        #expect(resolve(entitlement(purchaser: buyerToken), userID: "second", token: otherToken) == .other)
    }

    @Test func claimingMovesItOnThisDevice() {
        let claims = ["1000": "second"]
        #expect(resolve(entitlement(purchaser: buyerToken), userID: "second", token: otherToken, deviceClaims: claims) == .mine)
        #expect(resolve(entitlement(purchaser: buyerToken), userID: "buyer", token: buyerToken, deviceClaims: claims) == .other)
    }

    @Test func claimFollowsTheAccountToAnotherDevice() {
        #expect(resolve(entitlement(purchaser: buyerToken), userID: "second", token: otherToken, profileClaim: "1000") == .mine)
    }

    @Test func claimForADifferentSubscriptionIsIgnored() {
        #expect(resolve(entitlement(purchaser: buyerToken), userID: "second", token: otherToken, profileClaim: "999", deviceClaims: ["999": "second"]) == .other)
    }

    @Test func deviceClaimBeatsProfileClaim() {
        #expect(resolve(entitlement(purchaser: buyerToken), userID: "second", token: otherToken, profileClaim: "1000", deviceClaims: ["1000": "buyer"]) == .other)
    }

    @Test func purchaseWithoutAnAccountIsOpenToAnyone() {
        #expect(resolve(entitlement(purchaser: nil), userID: "second", token: otherToken) == .mine)
    }
}
