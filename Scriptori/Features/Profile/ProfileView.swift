import ScriptoriKit
import StoreKit
import SwiftUI

struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @State private var showManageSubscription = false
    @State private var showPaywall = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            if let profile = model.profile {
                List {
                    Section { stats(profile) }
                    Section("Last 7 days") { WeekStrip(days: profile.streak.recentDays) }
                    bookSection(profile.plan)
                    readingSection(profile.preferences)
                    reminderSection(profile.preferences)
                    subscriptionSection(profile.subscription)
                    accountSection(profile)
                }
                .navigationTitle(profile.displayName ?? "Profile")
                .manageSubscriptionsSheet(isPresented: $showManageSubscription)
                .sheet(isPresented: $showPaywall) { PaywallView(isDismissible: true) }
                .confirmationDialog("Delete your account and all reflections?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete account", role: .destructive) { Task { await model.deleteAccount() } }
                } message: {
                    Text("This can't be undone. Manage your App Store subscription separately in Settings.")
                }
            }
        }
    }

    private func stats(_ profile: UserProfile) -> some View {
        HStack {
            stat("\(model.displayedStreak)", "Current streak", "flame.fill", .orange)
            Divider()
            stat("\(profile.streak.longest)", "Longest", "trophy.fill", .yellow)
            Divider()
            stat("\(profile.totalChaptersRead)", "Chapters", "book.fill", .green)
            Divider()
            stat("\(profile.reflectionCount)", "Reflections", "text.bubble.fill", .purple)
        }
        .padding(.vertical, 6)
    }

    private func stat(_ value: String, _ label: String, _ symbol: String, _ tint: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(value).font(.title3.bold()).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private func bookSection(_ plan: PlanProgress) -> some View {
        Section("Your book") {
            NavigationLink {
                ChangeBookScreen()
            } label: {
                if let book = model.book(id: plan.bookID) {
                    HStack(spacing: 12) {
                        BookCover(book: book, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(book.name)
                            Text("\(min(plan.position, book.chapterCount)) of \(book.chapterCount) chapters read")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Label("Choose a book", systemImage: "books.vertical")
                }
            }
        }
    }

    private func readingSection(_ prefs: ReadingPreferences) -> some View {
        Section("Reading") {
            Picker("Typeface", selection: binding(\.typeface)) {
                ForEach(Typeface.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Stepper("Verses per card: \(prefs.versesPerCard)", value: binding(\.versesPerCard), in: ReadingPreferences.versesPerCardRange)
            Picker("Ambient mode", selection: binding(\.ambientSound)) {
                ForEach(AmbientSound.allCases) {
                    Label($0.label, systemImage: $0.symbol).tag($0)
                }
            }
        }
    }

    private func reminderSection(_ prefs: ReadingPreferences) -> some View {
        Section {
            Toggle("Daily reminder", isOn: binding(\.remindersEnabled))
            if prefs.remindersEnabled {
                DatePicker("Time", selection: reminderTime(prefs), displayedComponents: .hourAndMinute)
            }
        } header: {
            Text("Reminders")
        } footer: {
            Text("Missed a day? Complete the next day's chapter within 24 hours to repair your streak (once a week).")
        }
    }

    private func subscriptionSection(_ status: SubscriptionState) -> some View {
        Section("Subscription") {
            LabeledContent("Plan", value: planLabel(status))
            if let expires = status.expiresAt {
                LabeledContent(status.willAutoRenew ? "Renews" : "Expires", value: expires.formatted(date: .abbreviated, time: .omitted))
            }
            if status.hasAccess {
                Button("Manage subscription") { showManageSubscription = true }
            } else {
                Button("Start free trial") { showPaywall = true }
            }
            Button("Restore purchases") { Task { try? await model.subscriptions.restorePurchases() } }
        }
    }

    private func accountSection(_ profile: UserProfile) -> some View {
        Section("Account") {
            if let email = profile.email { LabeledContent("Email", value: email) }
            LabeledContent("Signed in with", value: profile.authProvider.rawValue.capitalized)
            Button("Sign out") { model.signOut() }
            Button("Delete account", role: .destructive) { confirmDelete = true }
        }
    }

    private func planLabel(_ status: SubscriptionState) -> String {
        switch status.tier {
        case .free: "Free"
        case .monthly: status.isInTrial ? "Monthly · Free trial" : "Monthly"
        case .annual: status.isInTrial ? "Annual · Free trial" : "Annual"
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ReadingPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { model.profile?.preferences[keyPath: keyPath] ?? ReadingPreferences()[keyPath: keyPath] },
            set: { newValue in model.updatePreferences { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func reminderTime(_ prefs: ReadingPreferences) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: prefs.reminderHour, minute: prefs.reminderMinute, second: 0, of: .now) ?? .now },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                model.updatePreferences {
                    $0.reminderHour = parts.hour ?? 8
                    $0.reminderMinute = parts.minute ?? 0
                }
            }
        )
    }
}

private struct WeekStrip: View {
    let days: [DayKey]

    var body: some View {
        let today = DayKey(.now)
        HStack {
            ForEach((0..<7).reversed(), id: \.self) { offset in
                let day = today.adding(days: -offset)
                let done = days.contains(day)
                VStack(spacing: 6) {
                    Text(day.startDate().formatted(.dateTime.weekday(.narrow)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Image(systemName: done ? "flame.fill" : "circle")
                        .foregroundStyle(done ? Color.orange : Color.secondary.opacity(0.4))
                        .font(.title3)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }
}
