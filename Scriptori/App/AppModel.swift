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
        case launching, signIn, onboarding, subscriptionLocked, paywall, main
    }

    let auth = AuthService()
    let subscriptions = SubscriptionService()
    let audio = AmbientAudioService()
    let notifications = NotificationScheduler()
    @ObservationIgnored private let store = LocalStore()
    @ObservationIgnored private let sync: ProfileSyncing = SyncFactory.make()
    @ObservationIgnored private let completion = ChapterCompletionService()
    @ObservationIgnored private var content: BibleContentProviding?
    @ObservationIgnored private var draftWrite: Task<Void, Never>?
    /// The latest reading position not yet sent to the cloud, and the timer that sends it.
    @ObservationIgnored private var unsentProgress: (progress: ChapterProgress, userID: String)?
    @ObservationIgnored private var progressPush: Task<Void, Never>?
    @ObservationIgnored private var unsentDraft: (draft: ReflectionEntry, userID: String)?
    @ObservationIgnored private var draftPush: Task<Void, Never>?
    /// Listens for reading done on the account's other devices while this one is open.
    @ObservationIgnored private var cloudReadingUpdates: (userID: String, task: Task<Void, Never>)?
    /// The same for journal entries added or edited on the account's other devices.
    @ObservationIgnored private var cloudJournalUpdates: Task<Void, Never>?
    /// `updatedAt` of the last cloud position acted on when returning to the app, so one
    /// that can't be used here isn't reconsidered on every return.
    @ObservationIgnored private var handledCloudProgressAt: Date?

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
        case today, journal, chapters, profile
    }

    /// Chapters checked in on, derived from the journal.
    var history: ReadingHistory { ReadingHistory(entries: reflections) }

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

    /// Keeps the paywall on screen for a beat after a purchase succeeds, so the reader sees
    /// the leaf finish its pulse instead of the screen vanishing the instant access flips on.
    var isHoldingPaywall = false

    var streakEngine: StreakEngine { completion.engine }

    var phase: Phase {
        if isLaunching { return .launching }
        guard auth.session != nil, let profile else { return .signIn }
        // A subscription locked to another account can't be used here, so a brand-new account
        // goes straight to that screen instead of answering onboarding it will never finish.
        // Only while it's still renewing: a cancelled plan is on its way out, so the reader
        // gets the paywall (with a note about when they can subscribe) instead of a dead end.
        if subscriptionOwnership == .other, otherAccountPlanEndsAt == nil { return .subscriptionLocked }
        if Self.needsOnboarding(profile) { return .onboarding }
        if isHoldingPaywall { return .paywall }
        if hasPremiumAccess { return .main }
        return .paywall
    }

    /// Onboarding follows the account, not the device: a profile that has neither answered
    /// the questions nor picked a book goes through it, whichever sign-in button created it.
    private static func needsOnboarding(_ profile: UserProfile) -> Bool {
        profile.onboarding == nil && profile.plan.bookID == nil
    }

    var hasPremiumAccess: Bool {
        #if DEBUG
        if debugBypassPaywall { return true }
        #endif
        return subscriptions.status.hasAccess && subscriptionOwnership == .mine
    }

    /// `appAccountToken`s of accounts deleted on this device while they held a subscription.
    /// Their purchases are open to any account here (see `SubscriptionOwnership`).
    private(set) var releasedPurchasers = Set(
        (UserDefaults.standard.stringArray(forKey: AppModel.releasedPurchasersKey) ?? []).compactMap(UUID.init(uuidString:))
    )
    private static let releasedPurchasersKey = "scriptori.releasedSubscriptionPurchasers"

    /// Whether the Apple ID's subscription belongs to the signed-in account. It is locked to
    /// the account that bought it, so a second account on the same Apple ID gets `.other`.
    var subscriptionOwnership: SubscriptionOwnership {
        guard let profile else { return .none }
        return .resolve(
            entitlement: subscriptions.entitlement,
            userToken: SubscriptionService.appAccountToken(for: profile.id),
            releasedPurchasers: releasedPurchasers
        )
    }

    /// When another account's cancelled plan on this Apple ID runs out, or `nil` if there is no
    /// such plan. It still has paid time left, so it can't be bought again from this account yet.
    var otherAccountPlanEndsAt: Date? {
        guard subscriptionOwnership == .other, !subscriptions.status.willAutoRenew else { return nil }
        return subscriptions.status.expiresAt
    }

    /// Checked before a new account is created: `true` when the Apple ID has a trial or
    /// subscription that belongs to an existing account, so a new one could never use it.
    func subscriptionBlocksNewAccounts() async -> Bool {
        await subscriptions.refreshEntitlements()
        return SubscriptionOwnership.isLocked(subscriptions.entitlement, releasedPurchasers: releasedPurchasers)
    }

    /// What the signed-in account is entitled to: the store's status, unless the
    /// subscription belongs to another account.
    private var ownedSubscription: SubscriptionState {
        subscriptionOwnership == .mine ? subscriptions.status : .free
    }

    /// Copies the subscription this account owns onto its profile.
    private func mirrorSubscription() async {
        guard var profile else { return }
        let status = ownedSubscription
        guard status != profile.subscription else { return }
        let startedTrial = status.isInTrial && !profile.subscription.isInTrial
        profile.subscription = status
        // Not a change to the profile itself: it is what the store says on this device, so it
        // neither counts as the newest copy nor sends the rest of the profile anywhere.
        self.profile = profile
        try? await store.save(profile, for: .profile, namespace: profile.id)
        try? await sync.push(subscription: status, userID: profile.id)
        if startedTrial { await notifications.scheduleTrialEndingReminder(expiresAt: status.expiresAt) }
    }

    var streakStatus: StreakStatus {
        guard let profile else { return .notStarted }
        return streakEngine.status(of: profile.streak, now: AppClock.now)
    }

    var displayedStreak: Int {
        guard let profile else { return 0 }
        return streakEngine.displayedStreak(profile.streak, now: AppClock.now)
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
            debugBypassPaywall = arguments.contains("-demo")
            _ = auth.signInAsGuest()
        }        #endif

        if let session = await auth.restoreSession() {
            await loadProfile(for: session)
        }    }

    func handleBecameActive() async {
        audio.resumeIfNeeded()
        await subscriptions.refreshEntitlements()
        guard let profile else { return }
        if let today, today.session.progress.day != DayKey(AppClock.now) {
            await loadToday()
        }
        await pullReading()
        await pullJournal()
        await notifications.refresh(for: profile, engine: streakEngine)
    }

    /// Leaving the app is when another device is most likely to be picked up next.
    func handleEnteredBackground() async {
        await sendUnsentProgress()
        await sendUnsentDraft()
    }

    func completeOnboarding(answers: OnboardingAnswers, remindersEnabled: Bool, reminderTime: Date, versesPerCard: Int) async {
        if remindersEnabled { await notifications.requestAuthorization() }
        guard var profile else { return }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
        profile.preferences.versesPerCard = versesPerCard
        profile.preferences.remindersEnabled = remindersEnabled
        profile.preferences.reminderHour = parts.hour ?? 8
        profile.preferences.reminderMinute = parts.minute ?? 0
        profile.onboarding = answers
        if let bookID = answers.bookID, let book = content?.book(id: bookID) {
            profile.plan.start(bookID: bookID, chapterCount: book.chapterCount)
        }
        profile.updatedAt = .now
        self.profile = profile
        await persistProfile()
        await loadToday()
        await notifications.refresh(for: profile, engine: streakEngine)
    }

    /// Switches to a book and opens it on the Today tab, ready to read now: from where the
    /// reader left off, or chapter 1.
    func chooseBook(_ bookID: String) async {
        guard var profile, let book = content?.book(id: bookID) else { return }
        let finishedToday = profile.plan.lastCompletedDay == DayKey(AppClock.now) && profile.plan.bookID != bookID
            ? profile.plan.lastCompletedChapterID.flatMap(ChapterID.parse)
            : nil
        // Leaving a chapter the reader was midway through still counts that book as started.
        if let left = today?.session.progress, left.furthestVerse > 0, let leftBook = ChapterID.parse(left.chapterID)?.bookID {
            profile.plan.markStarted(leftBook)
        }
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

    /// Keeps an unfinished check-in as it is filled in, so the reader's picks and answers
    /// survive however the sheet goes away: closed, replaced by the paywall, or the app quit.
    func saveReflectionDraft(_ entry: ReflectionEntry) {
        guard let profile, let today, entry.chapterID == today.chapter.id,
              !today.session.progress.isCompleted else { return }
        // `updatedAt` is this method's own stamp (newest draft wins across devices), so it
        // is left out when checking whether anything the reader entered has changed.
        var entry = entry
        entry.updatedAt = reflectionDraft?.updatedAt
        guard entry != reflectionDraft else { return }
        entry.updatedAt = .now
        reflectionDraft = entry
        let store = store
        let userID = profile.id
        let saved = entry
        writeDraft { try? await store.save(saved, for: .reflectionDraft, namespace: userID) }
        queueDraftPush(entry, userID: userID)
    }

    // MARK: Check-in sheet left open

    private static func openCheckInKey(_ userID: String) -> String { "scriptori.openCheckIn.\(userID)" }

    /// Records that the check-in sheet for `chapterID` is on screen, so a relaunch can reopen it.
    /// Closing the sheet (or leaving the screen it sits on) clears this; quitting doesn't.
    func checkInSheetChanged(isOpen: Bool, chapterID: String) {
        guard let profile else { return }
        let key = Self.openCheckInKey(profile.id)
        if isOpen {
            UserDefaults.standard.set(chapterID, forKey: key)
        } else if UserDefaults.standard.string(forKey: key) == chapterID {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// The unfinished check-in to reopen: the reader had its sheet open when the app was quit.
    func checkInToResume() -> ReflectionEntry? {
        guard let profile, let today, !today.session.progress.isCompleted,
              UserDefaults.standard.string(forKey: Self.openCheckInKey(profile.id)) == today.chapter.id,
              let draft = reflectionDraft, draft.chapterID == today.chapter.id, draft.mood != nil else { return nil }
        return draft
    }

    private func clearReflectionDraft(userID: String) async {
        reflectionDraft = nil
        dropUnsentDraft()
        let store = store
        await writeDraft { await store.remove(.reflectionDraft, namespace: userID) }.value
        try? await sync.push(draft: nil, userID: userID)
    }

    /// Draft writes run one after another, in the order they were made; a save per keystroke
    /// must never land after a newer one, or after the draft was cleared.
    @discardableResult
    private func writeDraft(_ write: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let task = Task { [previous = draftWrite] in
            await previous?.value
            await write()
        }
        draftWrite = task
        return task
    }

    func didSignIn(_ session: AuthSession) async {
        // Which account owns the subscription is decided as soon as the profile loads; make
        // sure that isn't judged on a subscription that has since expired.
        await subscriptions.refreshEntitlements()
        await loadProfile(for: session)
    }

    func signOut() {
        audio.reset()
        stopFollowingCloudReading()
        dropUnsentProgress()
        dropUnsentDraft()
        auth.signOut()
        profile = nil
        today = nil
        bookChoice = nil
        reflectionDraft = nil
        banner = nil
        selectedTab = .today
        reflections = []
    }

    /// Deletes the reader's synced data and their sign-in account. Throws
    /// `AuthError.requiresRecentLogin` if they need to confirm their identity first, in which
    /// case nothing local is removed and they stay signed in to retry.
    func deleteAccount() async throws {
        guard let profile else { return }
        try auth.requireRecentSignIn()
        let token = SubscriptionService.appAccountToken(for: profile.id)
        let heldSubscription = subscriptions.entitlement?.purchaserToken == token
        // A position or draft sent after the delete would bring the account's document back.
        stopFollowingCloudReading()
        dropUnsentProgress()
        dropUnsentDraft()
        // Remote data must go while still signed in; Firestore rules only allow the owner.
        try? await sync.deleteAll(userID: profile.id)
        try await auth.deleteAccount()
        try? await store.removeAll(namespace: profile.id)
        // The subscription keeps billing after the account is gone, so don't leave it locked
        // to an account nobody can sign in to.
        if heldSubscription {
            releasedPurchasers.insert(token)
            UserDefaults.standard.set(releasedPurchasers.map(\.uuidString), forKey: Self.releasedPurchasersKey)
        }
        signOut()
    }

    // MARK: Profile & today

    private func loadProfile(for session: AuthSession) async {
        let local = await store.load(UserProfile.self, for: .profile, namespace: session.userID)
        let remote = try? await sync.fetchProfile(userID: session.userID)
        // Answers saved before sign-in: the `-demo` launch arguments, or onboarding finished on a
        // build where it came first.
        let pendingAnswers = Self.consumePending(OnboardingAnswers.self, key: PendingKey.answers)
        var resolved = UserProfile.resolving(local, remote)
            ?? UserProfile(
                id: session.userID,
                displayName: session.displayName,
                email: session.email,
                authProvider: session.provider,
                plan: PlanProgress()
            )
        if let pendingAnswers {
            // They only fill gaps; an account that already onboarded keeps its own answers and book.
            if resolved.onboarding == nil {
                resolved.onboarding = pendingAnswers
                resolved.updatedAt = .now
            }
            if resolved.plan.bookID == nil, let bookID = pendingAnswers.bookID, let book = content?.book(id: bookID) {
                resolved.plan.start(bookID: bookID, chapterCount: book.chapterCount)
                resolved.updatedAt = .now
            }
        }
        profile = resolved
        // Needs `profile` set: ownership depends on who is signed in.
        resolved.subscription = ownedSubscription
        profile = resolved

        let localEntries = await store.load([ReflectionEntry].self, for: .reflections, namespace: session.userID) ?? []
        let remoteEntries = (try? await sync.fetchReflections(userID: session.userID)) ?? []
        reflections = ReflectionEntry.merge(localEntries, remoteEntries)
        if let books = content?.books {
            var plan = resolved.plan
            plan.reconcile(with: history, books: books)
            if plan != resolved.plan {
                resolved.plan = plan
                resolved.updatedAt = .now
                profile = resolved
            }
        }

        await persistProfile()
        audio.setSound(resolved.preferences.ambientSound)
        await loadToday(cloud: await fetchCloudReading(userID: session.userID))
        followCloudReading(userID: session.userID)
        await notifications.refresh(for: resolved, engine: streakEngine)
        await retryPendingSync()
    }

    // MARK: Reading position and unfinished check-in across devices

    /// What the account holds for the chapter in progress, or `.unavailable` when it couldn't
    /// be read (offline), which must not be mistaken for "nothing saved yet".
    private enum Cloud {
        case unavailable
        case fetched(CloudReading)
    }

    private func fetchCloudReading(userID: String) async -> Cloud {
        do {
            return .fetched(try await sync.fetchReading(userID: userID))
        } catch {
            return .unavailable
        }
    }

    /// Picks between this device's saved position and the account's for `chapterID`: whichever
    /// was changed last. Progress for any other chapter is never adopted, so it can't replace
    /// where the reader is on this device. If this device is ahead, the account is updated.
    private func settleProgress(local: ChapterProgress?, cloud: Cloud, chapterID: String, userID: String) async -> ChapterProgress? {
        guard case .fetched(let reading) = cloud else { return local }
        let remote = reading.progress
        let localIsCurrent = local?.chapterID == chapterID
        if let remote, remote.chapterID == chapterID, !localIsCurrent || remote.isNewer(than: local!) {
            handledCloudProgressAt = remote.updatedAt
            try? await store.save(remote, for: .chapterProgress, namespace: userID)
            return remote
        }
        if let local, localIsCurrent, remote.map({ $0.chapterID != chapterID || local.isNewer(than: $0) }) ?? true {
            try? await sync.push(progress: local, userID: userID)
        }
        return local
    }

    /// The same choice for an unfinished check-in on `chapterID`: the copy changed last wins.
    private func settleDraft(local: ReflectionEntry?, cloud: Cloud, chapterID: String, userID: String) async -> ReflectionEntry? {
        guard case .fetched(let reading) = cloud else { return local }
        let remote = reading.draft
        let localIsCurrent = local?.chapterID == chapterID
        if let remote, remote.chapterID == chapterID, !localIsCurrent || remote.isNewer(than: local!) {
            let store = store
            await writeDraft { try? await store.save(remote, for: .reflectionDraft, namespace: userID) }.value
            return remote
        }
        if let local, localIsCurrent, remote.map({ $0.chapterID != chapterID || local.isNewer(than: $0) }) ?? true {
            try? await sync.push(draft: local, userID: userID)
        }
        return local
    }

    /// A book counts as started once the reader gets past a chapter's intro, even if they never
    /// finish the chapter, so Profile lists it. Only the first time is news.
    private func noteBookStarted(by progress: ChapterProgress) {
        guard progress.furthestVerse > 0, var profile, let bookID = ChapterID.parse(progress.chapterID)?.bookID,
              profile.plan.markStarted(bookID) else { return }
        profile.updatedAt = .now
        self.profile = profile
        Task { await persistProfile() }
    }

    /// Sends the position a couple of seconds after the reader stops swiping, not per card.
    private func queueProgressPush(_ progress: ChapterProgress, userID: String) {
        unsentProgress = (progress, userID)
        progressPush?.cancel()
        progressPush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.sendUnsentProgress()
        }
    }

    private func sendUnsentProgress() async {
        guard let unsent = unsentProgress else { return }
        unsentProgress = nil
        try? await sync.push(progress: unsent.progress, userID: unsent.userID)
    }

    private func dropUnsentProgress() {
        progressPush?.cancel()
        progressPush = nil
        unsentProgress = nil
    }

    /// Sends the check-in a couple of seconds after the reader stops typing, not per keystroke.
    private func queueDraftPush(_ draft: ReflectionEntry, userID: String) {
        unsentDraft = (draft, userID)
        draftPush?.cancel()
        draftPush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.sendUnsentDraft()
        }
    }

    private func sendUnsentDraft() async {
        guard let unsent = unsentDraft else { return }
        unsentDraft = nil
        try? await sync.push(draft: unsent.draft, userID: unsent.userID)
    }

    private func dropUnsentDraft() {
        draftPush?.cancel()
        draftPush = nil
        unsentDraft = nil
    }

    /// Keeps this device in step with the account's other devices while the app is open,
    /// so reading on one shows up on the other without relaunching.
    private func followCloudReading(userID: String) {
        guard cloudReadingUpdates?.userID != userID else { return }
        stopFollowingCloudReading()
        let updates = sync.readingUpdates(userID: userID)
        let task = Task { [weak self] in
            for await reading in updates {
                await self?.applyCloudReading(reading, userID: userID)
            }
        }
        cloudReadingUpdates = (userID, task)
        let journal = sync.reflectionUpdates(userID: userID)
        cloudJournalUpdates = Task { [weak self] in
            for await entries in journal {
                await self?.applyCloudJournal(entries, userID: userID)
            }
        }
    }

    private func stopFollowingCloudReading() {
        cloudReadingUpdates?.task.cancel()
        cloudReadingUpdates = nil
        cloudJournalUpdates?.cancel()
        cloudJournalUpdates = nil
    }

    /// On returning to the app: picks up journal entries added or edited on another device.
    private func pullJournal() async {
        guard let profile, let entries = try? await sync.fetchReflections(userID: profile.id) else { return }
        await applyCloudJournal(entries, userID: profile.id)
    }

    /// Takes the account's copy of each journal entry when it was edited more recently than
    /// the one here. Entries only on this device (not sent yet) are kept.
    private func applyCloudJournal(_ entries: [ReflectionEntry], userID: String) async {
        guard let profile, profile.id == userID else { return }
        let merged = ReflectionEntry.merge(reflections, entries)
        guard merged != reflections else { return }
        reflections = merged
        try? await store.save(merged, for: .reflections, namespace: userID)
    }

    /// On returning to the app: picks up reading and check-in answers from another device.
    private func pullReading() async {
        guard let profile, case .fetched(let reading) = await fetchCloudReading(userID: profile.id) else { return }
        await applyCloudReading(reading, userID: profile.id)
    }

    /// Takes what another device saved to the account when it is newer than what's here.
    private func applyCloudReading(_ reading: CloudReading, userID: String) async {
        guard let profile, profile.id == userID, let session = auth.session, let current = today else { return }

        if let remote = reading.progress, remote.updatedAt != handledCloudProgressAt,
           remote.isNewer(than: current.session.progress) {
            handledCloudProgressAt = remote.updatedAt
            guard remote.chapterID == current.chapter.id, !remote.isCompleted else {
                // The other device finished this chapter or moved to another: that is in the profile.
                await loadProfile(for: session)
                return
            }
            current.session.adopt(remote)
            try? await store.save(current.session.progress, for: .chapterProgress, namespace: userID)
        }

        // Same place in the chapter; the check-in may still have moved on elsewhere.
        guard !current.session.progress.isCompleted else { return }
        let settled = await settleDraft(local: reflectionDraft, cloud: .fetched(reading), chapterID: current.chapter.id, userID: profile.id)
        let draft = settled?.carried(to: current.session.progress.day)
        if draft != reflectionDraft { reflectionDraft = draft }
    }

    func loadToday() async {
        await loadToday(cloud: .unavailable)
    }

    /// There is one "current chapter" record, and the next book's reading replaces it. So
    /// before that happens, an unfinished chapter other than `currentChapterID` is set aside
    /// here, to be picked up when the reader comes back to its book, on any device.
    private func pausedChapters(keeping local: ChapterProgress?, cloud: Cloud, currentChapterID: String, userID: String) async -> [String: ChapterProgress] {
        let stored = await store.load([String: ChapterProgress].self, for: .pausedChapters, namespace: userID) ?? [:]
        var paused = stored
        var inCloud: [String: ChapterProgress]?
        if case .fetched(let reading) = cloud {
            inCloud = reading.paused
            for (id, remote) in reading.paused where paused[id].map({ remote.isNewer(than: $0) }) ?? true {
                paused[id] = remote
            }
        }
        if let local, local.chapterID != currentChapterID, !local.isCompleted, local.hasStarted,
           paused[local.chapterID].map({ local.isNewer(than: $0) }) ?? true {
            paused[local.chapterID] = local
        }
        // A chapter checked in on since it was set aside is done with.
        paused = paused.filter { id, progress in
            !reflections.contains { $0.chapterID == id && $0.createdAt > (progress.updatedAt ?? .distantPast) }
        }
        if paused != stored {
            try? await store.save(paused, for: .pausedChapters, namespace: userID)
        }
        // Compared by which copy is newer, not for equality: times lose precision in storage.
        if let inCloud, Set(inCloud.keys) != Set(paused.keys) || paused.contains(where: { $0.value.isNewer(than: inCloud[$0.key]!) }) {
            try? await sync.push(paused: paused, userID: userID)
        }
        return paused
    }

    private func forgetPausedChapter(_ chapterID: String, userID: String) async {
        var paused = await store.load([String: ChapterProgress].self, for: .pausedChapters, namespace: userID) ?? [:]
        if paused.removeValue(forKey: chapterID) != nil {
            try? await store.save(paused, for: .pausedChapters, namespace: userID)
            try? await sync.push(paused: paused, userID: userID)
        }
        var drafts = await store.load([String: ReflectionEntry].self, for: .pausedDrafts, namespace: userID) ?? [:]
        if drafts.removeValue(forKey: chapterID) != nil {
            try? await store.save(drafts, for: .pausedDrafts, namespace: userID)
            try? await sync.push(pausedDrafts: drafts, userID: userID)
        }
    }

    /// The same for an unfinished check-in: there is one "current draft", which a check-in
    /// started in another book replaces, so a draft for any other chapter is set aside first.
    private func pausedDrafts(keeping local: ReflectionEntry?, cloud: Cloud, currentChapterID: String, userID: String) async -> [String: ReflectionEntry] {
        let stored = await store.load([String: ReflectionEntry].self, for: .pausedDrafts, namespace: userID) ?? [:]
        var paused = stored
        var inCloud: [String: ReflectionEntry]?
        if case .fetched(let reading) = cloud {
            inCloud = reading.pausedDrafts
            for (id, remote) in reading.pausedDrafts where paused[id].map({ remote.isNewer(than: $0) }) ?? true {
                paused[id] = remote
            }
        }
        if let local, local.chapterID != currentChapterID,
           paused[local.chapterID].map({ local.isNewer(than: $0) }) ?? true {
            paused[local.chapterID] = local
        }
        // A draft that was completed is in the journal under the same ID.
        let journal = Set(reflections.map(\.id))
        paused = paused.filter { !journal.contains($0.value.id) }
        if paused != stored {
            try? await store.save(paused, for: .pausedDrafts, namespace: userID)
        }
        // Compared by which copy is newer, not for equality: times lose precision in storage.
        if let inCloud, Set(inCloud.keys) != Set(paused.keys) || paused.contains(where: { $0.value.isNewer(than: inCloud[$0.key]!) }) {
            try? await sync.push(pausedDrafts: paused, userID: userID)
        }
        return paused
    }

    private func loadToday(cloud: Cloud) async {
        guard let profile, let content else { return }
        let day = DayKey(AppClock.now)
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
            let local = await store.load(ChapterProgress.self, for: .chapterProgress, namespace: profile.id)
            let paused = await pausedChapters(keeping: local, cloud: cloud, currentChapterID: chapter.id, userID: profile.id)
            var saved = await settleProgress(local: local, cloud: cloud, chapterID: chapter.id, userID: profile.id)
            // Back in a book that was switched away from: carry on where it was left.
            if saved?.chapterID != chapter.id, let resumed = paused[chapter.id] { saved = resumed }
            // Marked finished today, yet the plan never counted it: a check-in that went wrong.
            // Left alone it blocks the check-in and stops its draft from being saved, so the
            // mark is dropped (here and for the other devices) and the place and marks kept.
            if !assignment.isCompletedToday, var finished = saved, finished.chapterID == chapter.id, finished.isCompleted {
                if reflections.contains(where: { $0.chapterID == chapter.id && $0.day == finished.day }) {
                    // Read before and checked in on: this is the book being read again, so the
                    // earlier round's record is history and the chapter starts from its intro.
                    let fresh = ChapterProgress(chapterID: chapter.id, day: day, updatedAt: .now)
                    saved = fresh
                    try? await store.save(fresh, for: .chapterProgress, namespace: profile.id)
                    try? await sync.push(progress: fresh, userID: profile.id)
                } else if finished.day == day {
                    finished.completedAt = nil
                    finished.updatedAt = .now
                    saved = finished
                    try? await store.save(finished, for: .chapterProgress, namespace: profile.id)
                    try? await sync.push(progress: finished, userID: profile.id)
                }
            }
            // Finished today according to the plan, but the reading record for it isn't here
            // (it was finished on another device): rebuild it from the journal entry, so Today
            // opens on the finished last card with the verses that were marked.
            if assignment.isCompletedToday, !(saved?.chapterID == chapter.id && saved?.isCompleted == true) {
                let entry = reflections.first { $0.chapterID == chapter.id && $0.day == day }
                    ?? reflections.first { $0.chapterID == chapter.id }
                saved = .completed(chapter: chapter, day: day, at: entry?.createdAt ?? .now, markedVerses: entry?.highlights ?? [])
            }
            let session = ChapterSession(chapter: chapter, day: day, versesPerCard: profile.preferences.versesPerCard, restoring: saved)
            let store = store
            let userID = profile.id
            session.onProgressChange = { [weak self] progress in
                Task { try? await store.save(progress, for: .chapterProgress, namespace: userID) }
                self?.queueProgressPush(progress, userID: userID)
                self?.noteBookStarted(by: progress)
            }
            today = TodayContext(assignment: assignment, chapter: chapter, session: session)
            let localDraft = await store.load(ReflectionEntry.self, for: .reflectionDraft, namespace: profile.id)
            let pausedDrafts = await pausedDrafts(keeping: localDraft, cloud: cloud, currentChapterID: chapter.id, userID: profile.id)
            // Like the reading position, an unfinished check-in carries over to a later day.
            if session.progress.isCompleted {
                reflectionDraft = nil
            } else {
                var draft = await settleDraft(local: localDraft, cloud: cloud, chapterID: chapter.id, userID: profile.id)
                // Back in a book that was switched away from: its check-in is where it was left.
                if draft?.chapterID != chapter.id { draft = pausedDrafts[chapter.id] }
                reflectionDraft = draft.flatMap { $0.chapterID == chapter.id ? $0.carried(to: day) : nil }
            }
        } catch {
            errorMessage = "Couldn't open \(assignment.chapterID)."
        }
    }

    // MARK: Completion

    /// Validates and records the end-of-chapter reflection, returning what to celebrate.
    @discardableResult
    func submitReflection(_ entry: ReflectionEntry) async throws(CompletionError) -> CompletionResult? {
        // The chapter on Today can change under an open check-in (another device moved on);
        // an entry for one chapter must never complete a different one.
        guard let profile, let today, entry.chapterID == today.chapter.id else { return nil }
        // A check-in resumed from a draft carries the draft's save time; a new entry has no edits.
        var entry = entry
        entry.updatedAt = nil
        let result = try completion.complete(
            chapter: today.chapter,
            progress: today.session.progress,
            reflection: entry,
            profile: profile,
            now: AppClock.now
        )
        self.profile = result.profile
        // The day counted comes from `AppClock`; which copy of the profile is newer never does.
        self.profile?.updatedAt = .now
        reflections.insert(result.entry, at: 0)
        today.session.markCompleted(at: result.progress.completedAt ?? AppClock.now)
        var assignment = today.assignment.markingCompleted()
        if let content, case .chapter(let resolved) = DailyReadingResolver.reading(progress: result.profile.plan, books: content.books, today: result.progress.day) {
            assignment = resolved
        }
        self.today = TodayContext(assignment: assignment, chapter: today.chapter, session: today.session)

        if result.streak.milestone != nil { Haptics.milestone() } else { Haptics.chapterComplete() }

        await persistProfile()
        await clearReflectionDraft(userID: result.profile.id)
        await forgetPausedChapter(today.chapter.id, userID: result.profile.id)
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
        Task { await mirrorSubscription() }
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
        static let answers = "scriptori.pendingOnboarding"
    }

    private static func consumePending<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
        defer { UserDefaults.standard.removeObject(forKey: key) }
        return UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
    }
}
