import ScriptoriKit
import SwiftUI

/// Shown when the Apple ID already has a trial or subscription that was started with a
/// different Scriptori account. The subscription is locked to that account, so the way
/// forward is signing in with it.
///
/// It appears in two places: after signing in to an account that doesn't own the
/// subscription, and before sign-up, in place of creating a new account.
struct SubscriptionLockedView: View {
    /// Actions for someone who isn't signed in yet and tried to create an account.
    struct SignedOutActions {
        let logIn: () -> Void
        let back: () -> Void
    }

    @Environment(AppModel.self) private var model
    var signedOut: SignedOutActions?

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
                Text(instructions)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                if let signedOut {
                    Button("Log In", action: signedOut.logIn)
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Back", action: signedOut.back)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.8))
                } else {
                    Button("Sign Out") { model.signOut() }
                        .buttonStyle(PrimaryButtonStyle())
                }
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

    private var instructions: String {
        if signedOut != nil {
            return "A new account can't be created while it's active. Log in with that account to keep reading."
        }
        let signedInAs = model.profile?.email.map { " You're signed in as \($0)." } ?? ""
        return "Sign out, then log in with that account to keep reading.\(signedInAs)"
    }
}
