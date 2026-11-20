import ScriptoriKit
import StoreKit
import SwiftUI

struct PaywallView: View {
    enum Plan: Hashable { case monthly, annual }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let isDismissible: Bool

    @State private var plan: Plan = .annual
    @State private var isPurchasing = false
    @State private var errorText: String?
    /// The reason the plans couldn't be loaded. Kept while a retry is running, so the bottom bar
    /// doesn't flip back to a disabled purchase button between attempts.
    @State private var loadFailureMessage: String?

    private let palette = Palette.dusk
    private let termsURL = URL(string: "https://scriptori.app/terms")!
    private let privacyURL = URL(string: "https://scriptori.app/privacy")!

    private var subscriptions: SubscriptionService { model.subscriptions }
    private var selectedProduct: Product? { plan == .annual ? subscriptions.annual : subscriptions.monthly }
    private var showsTrial: Bool { subscriptions.isEligibleForTrial && (selectedProduct?.hasFreeTrial ?? true) }
    /// No plan is available to buy because loading them failed; the only useful action is retrying.
    private var showsLoadFailure: Bool { loadFailureMessage != nil && subscriptions.products.isEmpty }

    var body: some View {
        ZStack {
            PaletteBackground(palette: palette)
            ScrollView {
                VStack(spacing: 28) {
                    hero
                    benefits
                    if !showsLoadFailure {
                        planToggle
                        planDetail
                    }
                    if showsTrial { trialTimeline }
                }
                .padding(.horizontal, 24)
                .padding(.top, 56)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom) { purchaseBar }

            VStack {
                HStack {
                    if !isDismissible {
                        // The gate after sign-in: the only way back to the sign-in screen.
                        Button("Sign Out") { model.signOut() }
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(.ultraThinMaterial, in: .capsule)
                            .disabled(isPurchasing)
                    }
                    Spacer()
                    if isDismissible {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.subheadline.weight(.bold))
                                .frame(width: 32, height: 32)
                                .background(.ultraThinMaterial, in: .circle)
                        }
                        .accessibilityLabel("Close")
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
        }
        .overlay { if isPurchasing { purchasingOverlay } }
        .animation(.easeInOut(duration: 0.3), value: isPurchasing)
        .foregroundStyle(.white)
        .task {
            if subscriptions.products.isEmpty { await subscriptions.loadProducts() }
        }
        .onChange(of: subscriptions.loadState, initial: true) { _, state in
            switch state {
            case .failed(let message): loadFailureMessage = message
            case .loaded: loadFailureMessage = nil
            case .idle, .loading: break
            }
        }
        .onChange(of: subscriptions.status.hasAccess) { _, hasAccess in
            // While a purchase is finishing, `purchase()` dismisses once the leaf has had its moment.
            if hasAccess && isDismissible && !isPurchasing { dismiss() }
        }
    }

    /// Replaces the paywall while the purchase is in flight: the App Store sheet slides over
    /// this, and it's what the reader sees once they confirm. Opaque, so none of the paywall
    /// shows through; cancelling the purchase fades it back in.
    private var purchasingOverlay: some View {
        ZStack {
            PaletteBackground(palette: palette).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(palette.accent)
                    .symbolEffect(.pulse, options: .repeating, isActive: true)
                Text(showsTrial ? "Starting your trial…" : "Unlocking Scriptori…")
                    .font(Typography.display(24))
            }
        }
        .transition(.opacity)
    }

    // MARK: Sections

    private var hero: some View {
        VStack(spacing: 12) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 40))
                .foregroundStyle(palette.accent)
                .symbolEffect(.pulse)
            Text(showsTrial ? "Start your 3-day\nfree trial" : "Unlock Scriptori")
                .font(Typography.display(34))
                .multilineTextAlignment(.center)
            Text("Turn doomscrolling into bloomscrolling.")
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 14) {
            benefit("rectangle.stack", "A new chapter every day, one swipe at a time")
            benefit("text.bubble", "Guided reflections & a private journal")
            benefit("flame", "Streaks with a 24-hour Streak Repair")
            benefit("cloud.rain", "Ambient rain, waves & wind, plus read-aloud")
            benefit("square.and.arrow.up", "Beautiful shareable verse cards")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func benefit(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .frame(width: 28)
                .foregroundStyle(palette.accent)
            Text(text).font(.subheadline)
        }
    }

    private var planToggle: some View {
        HStack(spacing: 4) {
            toggleButton(.monthly, "Monthly")
            toggleButton(.annual, "Annual", badge: subscriptions.annualSavingsPercent.map { "Save \($0)%" } ?? "Save 20%")
        }
        .padding(4)
        .background(.white.opacity(0.12), in: .capsule)
        .sensoryFeedback(.selection, trigger: plan)
    }

    private func toggleButton(_ value: Plan, _ title: String, badge: String? = nil) -> some View {
        Button {
            withAnimation(.snappy) { plan = value }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.orange, in: .capsule)
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(plan == value ? Color.white : .clear, in: .capsule)
            .foregroundStyle(plan == value ? Color.black : .white)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var planDetail: some View {
        // A failed load is shown in the bottom bar instead (see `loadFailureBar`).
        if let product = selectedProduct {
            VStack(spacing: 6) {
                Text("\(product.displayPrice) / \(product.periodLabel)")
                    .font(.title2.bold())
                if let monthly = product.monthlyEquivalent {
                    Text("Just \(monthly), billed annually")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    Text("Billed monthly, cancel anytime")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(.white.opacity(0.08), in: .rect(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(palette.accent.opacity(0.6)))
            .contentTransition(.numericText())
        } else {
            ProgressView().tint(.white).frame(height: 96)
        }
    }

    /// Bottom-bar replacement for the purchase button when the plans couldn't be loaded.
    private func loadFailureBar(_ message: String) -> some View {
        let isRetrying = subscriptions.loadState == .loading
        return VStack(spacing: 10) {
            Text("We couldn't load the subscription options.")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.footnote.weight(.bold))
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
            Button {
                Task { await subscriptions.loadProducts() }
            } label: {
                if isRetrying {
                    ProgressView().tint(.black)
                } else {
                    Text("Try Again")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isRetrying)
        }
    }

    private var trialTimeline: some View {
        VStack(alignment: .leading, spacing: 16) {
            timelineRow("lock.open.fill", "Today", "Full access to every chapter and feature.")
            timelineRow("bell.fill", "Day 2", "We'll remind you before your trial ends.")
            timelineRow("star.fill", "Day 3", "Your subscription begins. Cancel anytime before.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timelineRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.footnote)
                .frame(width: 30, height: 30)
                .background(palette.accent.opacity(0.25), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private var purchaseBar: some View {
        VStack(spacing: 10) {
            if let errorText {
                // Same treatment as the load-failure message in `loadFailureBar`.
                Text(errorText)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let endsAt = model.otherAccountPlanEndsAt {
                // The Apple ID still has paid time from another Scriptori account. Buying now
                // would only re-enable that plan for them, so this opens up when it runs out.
                Text("A plan from another Scriptori account on your Apple ID ends \(Self.shownEnd(of: endsAt).formatted(date: .abbreviated, time: .shortened)). You can subscribe using this account after that.")
                    .font(.footnote.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Color(red: 1, green: 0.42, blue: 0.42), in: .rect(cornerRadius: 14))
            } else if showsLoadFailure, let message = loadFailureMessage {
                // No plans loaded, so there's nothing to buy: offer a full-size retry instead of
                // a purchase button that can't be tapped.
                loadFailureBar(message)
            } else {
                // Not offered while the banner is up: there's nothing to buy until that plan ends.
                Button {
                    Task { await purchase() }
                } label: {
                    Text(showsTrial ? "Start Free Trial" : "Continue")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(selectedProduct == nil || isPurchasing)
            }

            Text(finePrint)
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 18) {
                Button("Restore") { Task { await restore() } }
                Link("Terms", destination: termsURL)
                Link("Privacy", destination: privacyURL)
                #if DEBUG
                Button("Skip (debug)") { model.debugBypassPaywall = true; if isDismissible { dismiss() } }
                #endif
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    private var finePrint: String {
        guard let product = selectedProduct else { return " " }
        let price = "\(product.displayPrice)/\(product.periodLabel)"
        return showsTrial
            ? "3 days free, then \(price). Auto-renews until cancelled in Settings."
            : "\(price). Auto-renews until cancelled in Settings."
    }

    /// The banner shows no seconds, so a plan ending at 5:11:46 would read "5:11", a time that
    /// passes while the plan is still running. Rounded up to the minute it is always true.
    private static func shownEnd(of date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / 60).rounded(.up) * 60)
    }

    // MARK: Actions

    private func purchase() async {
        guard let product = selectedProduct else { return }
        isPurchasing = true
        errorText = nil
        // Held before the purchase so the paywall can't be swapped out the moment access flips on.
        model.isHoldingPaywall = true
        defer {
            isPurchasing = false
            model.isHoldingPaywall = false
        }
        do {
            let token = model.profile.map { SubscriptionService.appAccountToken(for: $0.id) }
            switch try await subscriptions.purchase(product, appAccountToken: token) {
            case .unlocked:
                Haptics.chapterComplete()
                try? await Task.sleep(for: .seconds(1.6))
                if isDismissible { dismiss() }
            case .pending:
                errorText = "Your purchase isn't finished yet. Scriptori will unlock as soon as it goes through."
            case .notUnlocked, .cancelled:
                break
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func restore() async {
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            try await subscriptions.restorePurchases()
            if !subscriptions.status.hasAccess { errorText = "No active subscription found." }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
