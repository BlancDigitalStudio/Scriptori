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

    private let palette = Palette.dusk
    private let termsURL = URL(string: "https://scriptori.app/terms")!
    private let privacyURL = URL(string: "https://scriptori.app/privacy")!

    private var subscriptions: SubscriptionService { model.subscriptions }
    private var selectedProduct: Product? { plan == .annual ? subscriptions.annual : subscriptions.monthly }
    private var showsTrial: Bool { subscriptions.isEligibleForTrial && (selectedProduct?.hasFreeTrial ?? true) }

    var body: some View {
        ZStack {
            PaletteBackground(palette: palette)
            ScrollView {
                VStack(spacing: 28) {
                    hero
                    benefits
                    planToggle
                    planDetail
                    if showsTrial { trialTimeline }
                }
                .padding(.horizontal, 24)
                .padding(.top, 56)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom) { purchaseBar }

            if isDismissible {
                VStack {
                    HStack {
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.subheadline.weight(.bold))
                                .frame(width: 32, height: 32)
                                .background(.ultraThinMaterial, in: .circle)
                        }
                        .accessibilityLabel("Close")
                    }
                    Spacer()
                }
                .padding()
            }
        }
        .foregroundStyle(.white)
        .task {
            if subscriptions.products.isEmpty { await subscriptions.loadProducts() }
        }
        .onChange(of: subscriptions.status.hasAccess) { _, hasAccess in
            if hasAccess && isDismissible { dismiss() }
        }
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
        switch subscriptions.loadState {
        case .failed(let message):
            VStack(spacing: 10) {
                Text(message).font(.footnote).multilineTextAlignment(.center)
                Button("Try again") { Task { await subscriptions.loadProducts() } }
                    .font(.footnote.weight(.semibold))
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.08), in: .rect(cornerRadius: 20))
        default:
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
                Text(errorText).font(.footnote).foregroundStyle(.orange)
            }
            Button {
                Task { await purchase() }
            } label: {
                if isPurchasing {
                    ProgressView().tint(.black)
                } else {
                    Text(showsTrial ? "Start Free Trial" : "Continue")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(selectedProduct == nil || isPurchasing)

            Text(finePrint)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)

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

    // MARK: Actions

    private func purchase() async {
        guard let product = selectedProduct else { return }
        isPurchasing = true
        errorText = nil
        defer { isPurchasing = false }
        do {
            let token = model.profile.map { SubscriptionService.appAccountToken(for: $0.id) }
            if try await subscriptions.purchase(product, appAccountToken: token) {
                Haptics.chapterComplete()
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
