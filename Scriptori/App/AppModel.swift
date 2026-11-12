import Foundation
import Observation
import ScriptoriKit

/// Today's chapter, its feed session, and where it sits in the plan.
struct TodayContext {
    let assignment: DailyAssignment
    let chapter: BibleChapter
    let session: ChapterSession
}

@Observable
@MainActor
final class AppModel {
    enum Phase: Equatable {
        case launching, onboarding, signIn, paywall, main
    }

    let auth = AuthService()
    let subscriptions = SubscriptionService()
    let audio = AmbientAudioService()
    let notifications = NotificationScheduler()
    @ObservationIgnored private let store = LocalStore()
    @ObservationIgnored private let sync: ProfileSyncing = SyncFactory.make()
    @ObservationIgnored private let completion = ChapterCompletionService()
    @ObservationIgnored private var content: BibleContentProviding?

    private(set) var isLaunching = true
    private(set) var profile: UserProfile?
    private(set) var reflections: [ReflectionEntry] = []
    private(set) var today: TodayContext?
    /// Set when there's no chapter to serve until the reader picks a book.
    private(set) var bookChoice: BookChoice?
    /// A check-in for today's chapter that was closed before completing.
    private(set) var reflectionDraft: ReflectionEntry?
    /// One-off encouragement shown over the Today feed.
    var banner: Banner?

    struct Banner: Equatable, Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }
    var errorMessage: String?

    enum Tab: Hashable {
        case today, journal, profile
    }

    var selectedTab: Tab = .today

    enum BookChoice: Equatable {
        case firstBook
        case finished(BibleBook)
    }

    var books: [BibleBook] { content?.books ?? [] }

    func book(id: String?) -> BibleBook? {
        guard let id else { return nil }
        return content?.book(id: id)
    }

    func recommendedBooks(for answers: OnboardingAnswers? = nil, excluding excludedID: String? = nil) -> [BibleBook] {
        let answers = answers ?? profile?.onboarding
        return BookRecommender.recommend(
            from: books.filter { $0.id != excludedID },
            intent: answers?.intent,
            familiarity: answers?.familiarity
        )
    }

    func chapter(id: String) async -> BibleChapter? {
        if let today, today.chapter.id == id { return today.chapter }
        return try? await content?.chapter(id: id)
    }

    /// A verse from chapter 1 to preview a book: its first theme's key verse, else verse 1.
    func sampleVerse(for book: BibleBook) async -> (verse: BibleVerse, reference: String)? {
        guard let chapter = try? await content?.chapter(bookID: book.id, number: 1) else { return nil }
        let number = chapter.reflection.themes.first?.keyVerse ?? 1
        guard let verse = chapter.verses.first(where: { $0.number == number }) ?? chapter.verses.first else { return nil }
        return (verse, chapter.reference(for: [verse]))
    }

    /// Today's reflection, while it's still today.
    var todaysReflection: ReflectionEntry? {
        guard let today else { return nil }
        return reflections.first { $0.day == today.session.progress.day && $0.chapterID == today.chapter.id }
    }
    #if DEBUG
    var debugBypassPaywall = false
    #endif

    var hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "scriptori.onboarded") {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "scriptori.onboarded") }
    }

    var streakEngine: StreakEngine { completion.engine }

    var phase: Phase {
        if isLaunching { return .launching }
        if !hasCompletedOnboarding { return .onboarding }
        if auth.session == nil || profile == nil { return .signIn }
        if !hasPremiumAccess { return .paywall }
        return .main
    }

    var hasPremiumAccess: Bool {
        #if DEBUG
        if debugBypassPaywall { return true }
        #endif
        return subscriptions.status.hasAccess
    }

    var streakStatus: StreakStatus {
        guard let profile else { return .notStarted }
        return streakEngine.status(of: profile.streak, now: .now)
    }

    var displayedStreak: Int {
        guard let profile else { return 0 }
        return streakEngine.displayedStreak(profile.streak, now: .now)
    }

    // MARK: Lifecycle

    func bootstrap() async {
        defer { isLaunching = false }
        do {
            content = try BundledContentLibrary()
        } catch {
            errorMessage = "Couldn't load today's reading. Please reinstall the app."
        }
        subscriptions.onStatusChange = { [weak self] status in self?.subscriptionChanged(status) }
        await subscriptions.start()

        #if DEBUG
        // `-demo` jumps straight into the feed as a guest; `-demo-paywall` stops at the paywall.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-demo") || arguments.contains("-demo-paywall") {
            if let data = try? JSONEncoder().encode(OnboardingAnswers(bookID: "PHP")) {
                UserDefaults.standard.set(data, forKey: PendingKey.answers)
            }
            hasCompletedOnboarding = true
            debugBypassPaywall = arguments.contains("-demo")
            _ = auth.signInAsGuest()
        }        #endif

        if let session = await auth.restoreSession() {
            await loadProfile(for: session)
        }    }

    func handleBecameActive() async {
        await subscriptions.refreshEntitlements()
        guard let profile else { return }
        if let today, today.session.progress.day != DayKey(.now) {
            await loadToday()
        }
        await notifications.refresh(for: profile, engine: streakEngine)
    }

    func completeOnboarding(answers: OnboardingAnswers, remindersEnabled: Bool, reminderTime: Date, versesPerCard: Int) async {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
        let prefs = ReadingPreferences(
            versesPerCard: versesPerCard,
            remindersEnabled: remindersEnabled,
            reminderHour: parts.hour ?? 8,
            reminderMinute: parts.minute ?? 0
        )
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(prefs) {
            UserDefaults.standard.set(data, forKey: PendingKey.preferences)
        }
        if let data = try? encoder.encode(answers) {
            UserDefaults.standard.set(data, forKey: PendingKey.answers)
        }
        if remindersEnabled { await notifications.requestAuthorization() }
        hasCompletedOnboarding = true
    }

    /// Switches to a book and opens it on the Today tab, ready to read now: from where the
    /// reader left off, or chapter 1.
    func chooseBook(_ bookID: String) async {
        guard var profile, let book = content?.book(id: bookID) else { return }
        let finishedToday = profile.plan.lastCompletedDay == DayKey(.now) && profile.plan.bookID != bookID
            ? profile.plan.lastCompletedChapterID.flatMap(ChapterID.parse)
            : nil
        profile.plan.start(bookID: bookID, chapterCount: book.chapterCount)
        profile.updatedAt = .now
        self.profile = profile
        await persistProfile()
        await loadToday()
        selectedTab = .today

        if let finishedToday, let today {
            let finishedName = content?.book(id: finishedToday.bookID)?.name ?? finishedToday.bookID
            banner = Banner(
                title: "Going the extra mile",
                message: "You already finished \(finishedName) \(finishedToday.number) today. \(today.chapter.reference) is a bonus. Your streak is safe either way."
            )
        }
    }

    /// Keeps an unfinished check-in so closing the sheet doesn't lose the reader's picks.
    func saveReflectionDraft(_ entry: ReflectionEntry) {
        guard let profile, let today, entry.chapterID == today.chapter.id,
              !today.session.progress.isCompleted else { return }
        reflectionDraft = entry
        Task { try? await store.save(entry, for: .reflectionDraft, namespace: profile.id) }
    }

    private func clearReflectionDraft(userID: String) async {
        reflectionDraft = nil
        await store.remove(.reflectionDraft, namespace: userID)
    }

    func didSignIn(_ session: AuthSession) async {
        await loadProfile(for: session)
    }

    func signOut() {
        audio.setSound(.off)
        auth.signOut()
        profile = nil
        today = nil
        bookChoice = nil
        reflectionDraft = nil
        banner = nil
        selectedTab = .today
        reflections = []
    }

    func deleteAccount() async {
        guard let profile else { return }
        try? await sync.deleteAll(userID: profile.id)
        try? await store.removeAll(namespace: profile.id)
        try? await auth.deleteAccount()
        signOut()
    }

    // MARK: Profile & today

    private func loadProfile(for session: AuthSession) async {
        let local = await store.load(UserProfile.self, for: .profile, namespace: session.userID)
        let remote = try? await sync.fetchProfile(userID: session.userID)
        let pendingPreferences = Self.consumePending(ReadingPreferences.self, key: PendingKey.preferences)
        let pendingAnswers = Self.consumePending(OnboardingAnswers.self, key: PendingKey.answers)
        var resolved = [local, remote].compactMap { $0 }.max { $0.updatedAt < $1.updatedAt }
            ?? UserProfile(
                id: session.userID,
                displayName: session.displayName,
                email: session.email,
                authProvider: session.provider,
                preferences: pendingPreferences ?? ReadingPreferences(),
                plan: PlanProgress()
            )
        if let pendingAnswers {
            if resolved.onboarding == nil { resolved.onboarding = pendingAnswers }
            // Profiles from before books could be chosen have no book yet; take the onboarding pick.
            if resolved.plan.bookID == nil, let bookID = pendingAnswers.bookID, let book = content?.book(id: bookID) {
                resolved.plan.start(bookID: bookID, chapterCount: book.chapterCount)
                resolved.updatedAt = .now
            }
        }
        resolved.subscription = subscriptions.status
        profile = resolved

        let localEntries = await store.load([ReflectionEntry].self, for: .reflections, namespace: session.userID) ?? []
        let remoteEntries = (try? await sync.fetchReflections(userID: session.userID)) ?? []
        reflections = ReflectionEntry.merge(localEntries, remoteEntries)

        await persistProfile()
        audio.setSound(resolved.preferences.ambientSound)
        await loadToday()
        await notifications.refresh(for: resolved, engine: streakEngine)
        await retryPendingSync()
    }

    func loadToday() async {
        guard let profile, let content else { return }
        let day = DayKey(.now)
        let assignment: DailyAssignment
        switch DailyReadingResolver.reading(progress: profile.plan, books: content.books, today: day) {
        case .needsBook:
            today = nil
            bookChoice = .firstBook
            return
        case .bookFinished(let bookID):
            today = nil
            bookChoice = content.book(id: bookID).map(BookChoice.finished) ?? .firstBook
            return
        case .chapter(let next):
            assignment = next
            bookChoice = nil
        }
        do {
            let chapter = try await content.chapter(id: assignment.chapterID)
            let saved = await store.load(ChapterProgress.self, for: .chapterProgress, namespace: profile.id)
            let session = ChapterSession(chapter: chapter, day: day, versesPerCard: profile.preferences.versesPerCard, restoring: saved)
            let store = store
            let userID = profile.id
            session.onProgressChange = { progress in
                Task { try? await store.save(progress, for: .chapterProgress, namespace: userID) }
            }
            today = TodayContext(assignment: assignment, chapter: chapter, session: session)
            let draft = await store.load(ReflectionEntry.self, for: .reflectionDraft, namespace: profile.id)
            reflectionDraft = draft.flatMap { $0.chapterID == chapter.id && $0.day == day && !session.progress.isCompleted ? $0 : nil }
        } catch {
            errorMessage = "Couldn't open \(assignment.chapterID)."
        }
    }

    // MARK: Completion

    /// Validates and records the end-of-chapter reflection, returning what to celebrate.
    @discardableResult
    func submitReflection(_ entry: ReflectionEntry) async throws(CompletionError) -> CompletionResult? {
        guard let profile, let today else { return nil }
        let result = try completion.complete(
            chapter: today.chapter,
            progress: today.session.progress,
            reflection: entry,
            profile: profile
        )
        self.profile = result.profile
        reflections.insert(result.entry, at: 0)
        today.session.markCompleted(at: result.progress.completedAt ?? .now)
        var assignment = today.assignment.markingCompleted()
        if let content, case .chapter(let resolved) = DailyReadingResolver.reading(progress: result.profile.plan, books: content.books, today: result.progress.day) {
            assignment = resolved
        }
        self.today = TodayContext(assignment: assignment, chapter: today.chapter, session: today.session)

        if result.streak.milestone != nil { Haptics.milestone() } else { Haptics.chapterComplete() }

        await persistProfile()
        await clearReflectionDraft(userID: result.profile.id)
        try? await store.save(reflections, for: .reflections, namespace: result.profile.id)
        await notifications.refresh(for: result.profile, engine: streakEngine)
        Task { await pushReflection(result.entry, userID: result.profile.id) }
        return result
    }

    /// Saves edits to an existing journal entry. Streak, totals and plan are untouched.
    func updateReflection(_ entry: ReflectionEntry) async {
        guard let profile, let index = reflections.firstIndex(where: { $0.id == entry.id }) else { return }
        var edited = entry
        edited.updatedAt = .now
        edited.syncState = .pending
        reflections[index] = edited
        try? await store.save(reflections, for: .reflections, namespace: profile.id)
        Task { await pushReflection(edited, userID: profile.id) }
    }

    // MARK: Preferences

    func updatePreferences(_ change: (inout ReadingPreferences) -> Void) {
        guard var profile else { return }
        let before = profile.preferences
        change(&profile.preferences)
        guard profile.preferences != before else { return }
        profile.updatedAt = .now
        self.profile = profile

        let prefs = profile.preferences
        if prefs.versesPerCard != before.versesPerCard {
            today?.session.setVersesPerCard(prefs.versesPerCard)
        }
        if prefs.ambientSound != before.ambientSound {
            audio.setSound(prefs.ambientSound)
        }
        Task {
            await persistProfile()
            if prefs.remindersEnabled != before.remindersEnabled || prefs.reminderHour != before.reminderHour || prefs.reminderMinute != before.reminderMinute {
                if prefs.remindersEnabled { await notifications.requestAuthorization() }
                await notifications.refresh(for: profile, engine: streakEngine)
            }
        }
    }

    // MARK: Private

    private func subscriptionChanged(_ status: SubscriptionState) {
        guard var profile else { return }
        let startedTrial = status.isInTrial && !profile.subscription.isInTrial
        profile.subscription = status
        profile.updatedAt = .now
        self.profile = profile
        Task {
            await persistProfile()
            if startedTrial { await notifications.scheduleTrialEndingReminder(expiresAt: status.expiresAt) }
        }
    }

    private func persistProfile() async {
        guard let profile else { return }
        try? await store.save(profile, for: .profile, namespace: profile.id)
        try? await sync.push(profile: profile)
    }

    private func pushReflection(_ entry: ReflectionEntry, userID: String) async {
        do {
            try await sync.push(reflection: entry, userID: userID)
            // A newer edit may have landed while this push was in flight; leave it pending.
            guard let index = reflections.firstIndex(where: { $0.id == entry.id }),
                  reflections[index].lastModified == entry.lastModified else { return }
            reflections[index].syncState = .synced
            try? await store.save(reflections, for: .reflections, namespace: userID)
        } catch {
            // Left as `.pending`; `retryPendingSync()` picks it up on next sign-in.
        }
    }

    func retryPendingSync() async {
        guard let profile else { return }
        for entry in reflections where entry.syncState == .pending {
            await pushReflection(entry, userID: profile.id)
        }
    }

    private enum PendingKey {
        static let preferences = "scriptori.pendingPreferences"
        static let answers = "scriptori.pendingOnboarding"
    }

    private static func consumePending<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
        defer { UserDefaults.standard.removeObject(forKey: key) }
        return UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
    }
}
