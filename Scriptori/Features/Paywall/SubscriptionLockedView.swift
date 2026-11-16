import ScriptoriKit
import StoreKit
import SwiftUI

/// Shown instead of the paywall when the Apple ID already has a trial or subscription that
/// was started with a different Scriptori account. The subscription is locked to that
/// account, so the only ways forward are signing in with it or cancelling with Apple.
struct SubscriptionLockedView: View {
    @Environment(AppModel.self) private var model
    @State private var showManageSubscription = false

    private let palette = Palette.dusk

    private var status: SubscriptionState { model.subscriptions.status }

    var body: some View {
        ZStack {
            PaletteBackground(palette: palette)
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(palette.accent)
                Text("Premium is on\nanother account")
                    .font(Typography.display(32))
                    .multilineTextAlignment(.center)
                Text("Your Apple ID has \(planDescription) that was started with a different Scriptori account.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.8))
                Text("Sign out, then log in with that account to keep reading.\(signedInDescription)")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button("Sign Out") { model.signOut() }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Manage subscription") { showManageSubscription = true }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .foregroundStyle(.white)
        .manageSubscriptionsSheet(isPresented: $showManageSubscription)
    }

    private var planDescription: String {
        let plan = status.tier == .annual ? "annual" : "monthly"
        return status.isInTrial ? "a free trial of the \(plan) plan" : "an active \(plan) subscription"
    }

    private var signedInDescription: String {
        model.profile?.email.map { " You're signed in as \($0)." } ?? ""
    }
}
