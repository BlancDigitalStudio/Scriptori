import ScriptoriKit
import SwiftUI

/// Opened from the gear on the Profile tab: the subscription and account details.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showPaywall = false
    @State private var manageSubscriptionFailed = false
    @State private var restoreMessage: String?

    var body: some View {
        List {
            if let profile = model.profile {
                subscriptionSection(profile.subscription)
                accountSection(profile)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPaywall) { PaywallView(isDismissible: true) }
        .manageSubscriptionsFailureAlert(isPresented: $manageSubscriptionFailed)
        .alert("Restore purchases", isPresented: Binding(get: { restoreMessage != nil }, set: { if !$0 { restoreMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(restoreMessage ?? "")
        }
    }

    private func subscriptionSection(_ status: SubscriptionState) -> some View {
        Section("Subscription") {
            LabeledContent("Plan", value: planLabel(status))
            if let expires = status.expiresAt {
                LabeledContent(expiryLabel(status), value: expires.formatted(date: .abbreviated, time: .omitted))
            }
            if status.hasAccess {
                Button("Manage subscription") {
                    Task { await model.openManageSubscriptions(onFailure: { manageSubscriptionFailed = true }) }
                }
            } else {
                Button("Start free trial") { showPaywall = true }
            }
            Button("Restore purchases") { Task { await restore() } }
        }
    }

    private func accountSection(_ profile: UserProfile) -> some View {
        Section("Account") {
            if let email = profile.email { LabeledContent("Email", value: email) }
            LabeledContent("Signed in with", value: profile.authProvider.rawValue.capitalized)
        }
    }

    private func restore() async {
        do {
            try await model.subscriptions.restorePurchases()
            if !model.subscriptions.status.hasAccess { restoreMessage = "No active subscription found." }
        } catch {
            restoreMessage = error.localizedDescription
        }
    }

    private func planLabel(_ status: SubscriptionState) -> String {
        switch status.tier {
        case .free: "Free"
        case .monthly: status.isInTrial ? "Free Trial - Monthly" : "Monthly"
        case .annual: status.isInTrial ? "Free Trial - Annual" : "Annual"
        }
    }

    /// A trial ends rather than renews: the paid plan starts then, or access stops if it's cancelled.
    private func expiryLabel(_ status: SubscriptionState) -> String {
        if status.isInTrial { return "Trial ends" }
        return status.willAutoRenew ? "Renews" : "Expires"
    }
}

extension AppModel {
    /// Shows Apple's subscription management, calling `onFailure` if it couldn't be opened.
    func openManageSubscriptions(onFailure: @escaping @MainActor () -> Void) async {
        do {
            try await subscriptions.showManageSubscriptions()
        } catch {
            onFailure()
        }
    }
}

extension View {
    /// Explains where else to manage the subscription when Apple's sheet couldn't be opened.
    func manageSubscriptionsFailureAlert(isPresented: Binding<Bool>) -> some View {
        modifier(ManageSubscriptionsFailureAlert(isPresented: isPresented))
    }
}

private struct ManageSubscriptionsFailureAlert: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(\.openURL) private var openURL

    private let subscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!

    func body(content: Content) -> some View {
        content.alert("Couldn't open subscriptions", isPresented: $isPresented) {
            Button("Open App Store") { openURL(subscriptionsURL) }
            Button("OK", role: .cancel) {}
        } message: {
            Text("We couldn't open subscription management. You can also manage it in Settings › your name › Subscriptions.")
        }
    }
}
