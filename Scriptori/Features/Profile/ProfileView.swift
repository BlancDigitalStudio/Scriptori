import ScriptoriKit
import SwiftUI

struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @State private var manageSubscriptionFailed = false
    @State private var confirmDelete = false
    @State private var reauthProvider: AuthProvider?
    @State private var deleteError: String?
    @State private var streakInfo: StreakInfoSheet.Kind?

    var body: some View {
        NavigationStack {
            if let profile = model.profile {
                List {
                    Section { stats(profile) }
                    Section("This week") { WeekStrip(days: profile.streak.recentDays) }
                    bookSection(profile.plan)
                    reminderSection(profile.preferences)
                    signOutRow
                }
                .navigationTitle(profile.displayName ?? "Profile")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink { SettingsView() } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
                .manageSubscriptionsFailureAlert(isPresented: $manageSubscriptionFailed)
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
                .sheet(item: $streakInfo) { kind in
                    StreakInfoSheet(kind: kind, current: model.displayedStreak, longest: profile.streak.longest, days: profile.streak.recentDays)
                }
                .confirmationDialog("Delete your account and all reflections?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    if profile.subscription.hasAccess && profile.subscription.willAutoRenew {
                        Button("Manage subscription") {
                            Task { await model.openManageSubscriptions(onFailure: { manageSubscriptionFailed = true }) }
                        }
                    }
                    Button("Delete account", role: .destructive) { Task { await deleteAccount() } }
                } message: {
                    Text(deleteWarning(profile.subscription))
                }
            }
        }
    }

    private func stats(_ profile: UserProfile) -> some View {
        HStack {
            stat("\(model.displayedStreak)", "Current streak", "flame.fill", .orange) { streakInfo = .current }
            Divider()
            stat("\(profile.streak.longest)", "Longest", "trophy.fill", .yellow) { streakInfo = .longest }
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

    private func reminderSection(_ prefs: ReadingPreferences) -> some View {
        Section {
            Toggle("Daily reminder", isOn: binding(\.remindersEnabled))
            if prefs.remindersEnabled {
                DatePicker("Time", selection: reminderTime(prefs), displayedComponents: .hourAndMinute)
            }
        } header: {
            Text("Reminders")
        } footer: {
            Text("Missed a day? Complete the next day's chapter within 24 hours to repair your streak.")
        }
    }

    /// Sign out and delete share one row; the account details live in Settings.
    private var signOutRow: some View {
        Section {
            HStack(spacing: 12) {
                Button { model.signOut() } label: {
                    Text("Sign out").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button(role: .destructive) { confirmDelete = true } label: {
                    Text("Delete account").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
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

    /// Deleting the account can't cancel an App Store subscription, so say what keeps billing.
    private func deleteWarning(_ status: SubscriptionState) -> String {
        let base = "This can't be undone."
        guard status.hasAccess else { return base }
        guard status.willAutoRenew else {
            return "\(base) Your subscription is already cancelled and won't renew."
        }
        return status.isInTrial
            ? "\(base) Deleting your account doesn't cancel your free trial: you'll be charged when it ends unless you cancel it with Apple first."
            : "\(base) Deleting your account doesn't cancel your subscription: it keeps renewing until you cancel it with Apple."
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

/// Explains whichever streak number was tapped on the Profile tab, and only that one.
private struct StreakInfoSheet: View {
    enum Kind: String, Identifiable {
        case current, longest
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    let kind: Kind
    let current: Int
    let longest: Int
    let days: [DayKey]

    var body: some View {
        NavigationStack {
            List {
                switch kind {
                case .current:
                    Section {
                        explainer("flame.fill", .orange, "Current streak", "\(current) day\(current == 1 ? "" : "s")",
                                  "Days in a row, up to today, with at least one chapter checked in. Miss a day and it starts over, unless you finish the next day's chapter within 24 hours.")
                    }
                    Section("This week") { WeekStrip(days: days) }
                    Section {
                        Text("Checking in on more than one chapter in a day counts toward Chapters, but adds one day to your streak.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                case .longest:
                    Section {
                        explainer("trophy.fill", .yellow, "Longest streak", "\(longest) day\(longest == 1 ? "" : "s")",
                                  "Your best run ever. It never goes down, so it's the number to beat.")
                    }
                }
            }
            .navigationTitle(kind == .current ? "Current streak" : "Longest streak")
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

    /// Fixed Sunday-to-Saturday columns. "Th" and "Sat" stay distinct from Tuesday and Sunday.
    private static let labels = ["S", "M", "T", "W", "Th", "F", "Sat"]

    var body: some View {
        let today = DayKey(AppClock.now)
        // Gregorian weekday is 1 for Sunday, whichever day the locale treats as the start of the week.
        let sunday = today.adding(days: 1 - Calendar.current.component(.weekday, from: today.startDate()))
        HStack {
            ForEach(0..<7, id: \.self) { offset in
                let day = sunday.adding(days: offset)
                let done = days.contains(day)
                VStack(spacing: 6) {
                    Text(Self.labels[offset])
                        .font(.caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(day == today ? .primary : .secondary)
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
