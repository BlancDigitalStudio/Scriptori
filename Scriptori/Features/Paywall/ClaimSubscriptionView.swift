import ScriptoriKit
import SwiftUI

/// Shown instead of the paywall when the Apple ID already has a trial or subscription that
/// was started with a different Scriptori account. The reader either moves it to the account
/// they're signed in to (no new charge, no new trial) or signs out to use the original one.
struct ClaimSubscriptionView: View {
    @Environment(AppModel.self) private var model
    @State private var isClaiming = false

    private let palette = Palette.dusk

    private var status: SubscriptionState { model.subscriptions.status }

    var body: some View {
        ZStack {
            PaletteBackground(palette: palette)
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "leaf.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(palette.accent)
                Text("You already have\nScriptori Premium")
                    .font(Typography.display(32))
                    .multilineTextAlignment(.center)
                Text("Your Apple ID has \(planDescription) that was started with a different Scriptori account.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.8))
                Text("Move it to \(accountDescription)? You won't be charged again, and the other account will no longer have Premium on this device.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button {
                    isClaiming = true
                    Task {
                        await model.claimSubscription()
                        isClaiming = false
                    }
                } label: {
                    Text("Use It on This Account")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isClaiming)

                Button("Sign out") { model.signOut() }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .disabled(isClaiming)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .foregroundStyle(.white)
    }

    private var planDescription: String {
        let plan = status.tier == .annual ? "annual" : "monthly"
        return status.isInTrial ? "a free trial of the \(plan) plan" : "an active \(plan) subscription"
    }

    private var accountDescription: String {
        model.profile?.email ?? "this account"
    }
}
