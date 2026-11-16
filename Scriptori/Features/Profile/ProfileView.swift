import ScriptoriKit
import StoreKit
import SwiftUI

struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @State private var showManageSubscription = false
    @State private var showPaywall = false
    @State private var confirmDelete = false
    @State private var reauthProvider: AuthProvider?
    @State private var deleteError: String?
    @State private var showStreakInfo = false

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
                .sheet(isPresented: Binding(get: { reauthProvider != nil }, set: { if !$0 { reauthProvider = nil } })) {
                    if let reauthProvider {
                        ConfirmIdentitySheet(provider: reauthProvider) { Task { await deleteAccount() } }
                    }
                }
                .alert("Couldn't delete your account", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(deleteError ?? "")
                }
                .sheet(isPresented: $showStreakInfo) {
                    StreakInfoSheet(current: model.displayedStreak, longest: profile.streak.longest, days: profile.streak.recentDays)
                }
                .confirmationDialog("Delete your account and all reflections?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete account", role: .destructive) { Task { await deleteAccount() } }
                } message: {
                    Text("This can't be undone. Manage your App Store subscription separately in Settings.")
                }
            }
        }
    }

    private func stats(_ profile: UserProfile) -> some View {
        HStack {
            stat("\(model.displayedStreak)", "Current streak", "flame.fill", .orange) { showStreakInfo = true }
            Divider()
            stat("\(profile.streak.longest)", "Longest", "trophy.fill", .yellow) { showStreakInfo = true }
            Divider()
            stat("\(model.history.chapters.count)", "Chapters", "book.fill", .green) { model.selectedTab = .chapters }
            Divider()
            stat("\(model.reflections.count)", "Reflections", "text.bubble.fill", .purple) { model.selectedTab = .journal }
        }
        .padding(.vertical, 6)
    }

    private func stat(_ value: String, _ label: String, _ symbol: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(value).font(.title3.bold()).monospacedDigit().foregroundStyle(.primary)
                Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("\(label): \(value)")
    }

    /// The current book first, then every other book with a check-in (most recent first).
    private func bookSection(_ plan: PlanProgress) -> some View {
        let history = model.history
        let started = ([plan.bookID].compactMap { $0 } + history.startedBookIDs).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        return Section(started.count > 1 ? "Your books" : "Your book") {
            ForEach(started, id: \.self) { bookID in
                if let book = model.book(id: bookID) {
                    let isCurrent = bookID == plan.bookID
                    Button {
                        if !isCurrent { Task { await model.chooseBook(bookID) } } else { model.selectedTab = .today }
                    } label: {
                        StartedBookRow(book: book, read: history.chaptersRead(in: bookID), isCurrent: isCurrent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(isCurrent ? "Open today's chapter" : "Switch to \(book.name)")
                }
            }
            NavigationLink {
                ChangeBookScreen()
            } label: {
                Label(started.isEmpty ? "Choose a book" : "Browse all books", systemImage: "books.vertical")
            }
        }
    }

    private func readingSection(_ prefs: ReadingPreferences) -> some View {
        Section {
            Picker("Typeface", selection: binding(\.typeface)) {
                ForEach(Typeface.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Stepper("Verses per card: \(prefs.versesPerCard)", value: binding(\.versesPerCard), in: ReadingPreferences.versesPerCardRange)
            Picker("Ambient mode", selection: binding(\.ambientSound)) {
                ForEach(AmbientSound.allCases) {
                    Label($0.label, systemImage: $0.symbol).tag($0)
                }
            }
        } header: {
            Text("Reading")
        } footer: {
            Text("Ambient sound starts once you swipe into today's chapter, and your choice is remembered next time.")
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

    private func deleteAccount() async {
        do {
            try await model.deleteAccount()
        } catch AuthError.requiresRecentLogin(let provider) {
            reauthProvider = provider
        } catch {
            deleteError = error.localizedDescription
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

private struct StartedBookRow: View {
    let book: BibleBook
    let read: Int
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            BookCover(book: book, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(book.name)
                    if isCurrent {
                        Text("Reading")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.15), in: .capsule)
                            .foregroundStyle(.tint)
                    }
                }
                Text("\(read) of \(book.chapterCount) chapters read")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(min(read, book.chapterCount)), total: Double(book.chapterCount))
            }
            if !isCurrent {
                Text("Switch")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(.rect)
    }
}

private struct StreakInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let current: Int
    let longest: Int
    let days: [DayKey]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    explainer("flame.fill", .orange, "Current streak", "\(current) day\(current == 1 ? "" : "s")",
                              "Days in a row, up to today, with at least one chapter checked in. Miss a day and it starts over, unless you use Streak Repair within 24 hours (once a week).")
                    explainer("trophy.fill", .yellow, "Longest streak", "\(longest) day\(longest == 1 ? "" : "s")",
                              "Your best run ever. It never goes down, so it's the number to beat.")
                }
                Section("Last 7 days") { WeekStrip(days: days) }
                Section {
                    Text("Checking in on more than one chapter in a day counts toward Chapters, but adds one day to your streak.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Streaks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func explainer(_ symbol: String, _ tint: Color, _ title: String, _ value: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tint).font(.title3).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Text(value).font(.headline.monospacedDigit())
                }
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
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
