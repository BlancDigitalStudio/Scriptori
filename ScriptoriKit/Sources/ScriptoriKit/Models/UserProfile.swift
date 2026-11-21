import Foundation

public enum AuthProvider: String, Codable, Sendable {
    case apple, google, email, guest
}

public enum SubscriptionTier: String, Codable, CaseIterable, Sendable {
    case free, monthly, annual

    public var isPremium: Bool { self != .free }
}

public struct SubscriptionState: Codable, Hashable, Sendable {
    public var tier: SubscriptionTier
    public var isInTrial: Bool
    public var expiresAt: Date?
    public var willAutoRenew: Bool

    public init(tier: SubscriptionTier = .free, isInTrial: Bool = false, expiresAt: Date? = nil, willAutoRenew: Bool = false) {
        self.tier = tier
        self.isInTrial = isInTrial
        self.expiresAt = expiresAt
        self.willAutoRenew = willAutoRenew
    }

    public static let free = SubscriptionState()

    public var hasAccess: Bool { tier.isPremium }
}

public enum Typeface: String, Codable, CaseIterable, Sendable {
    case serif, sans
}

public enum AmbientSound: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, rain, waves, wind

    public var id: String { rawValue }

    /// Retired modes (lo-fi, voiceover) decode as `.off`.
    public init(from decoder: Decoder) throws {
        self = AmbientSound(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .off
    }

    public var label: String {
        switch self {
        case .off: "Off"
        case .rain: "Soft rain"
        case .waves: "Waves"
        case .wind: "Wind"
        }
    }

    public var symbol: String {
        switch self {
        case .off: "speaker.slash"
        case .rain: "cloud.rain"
        case .waves: "water.waves"
        case .wind: "wind"
        }
    }
}

public struct ReadingPreferences: Codable, Hashable, Sendable {
    public static let versesPerCardRange = 1...3

    public var versesPerCard: Int {
        didSet { versesPerCard = versesPerCard.clamped(to: Self.versesPerCardRange) }
    }
    public var typeface: Typeface
    public var ambientSound: AmbientSound
    public var remindersEnabled: Bool
    public var reminderHour: Int
    public var reminderMinute: Int

    public init(
        versesPerCard: Int = 2,
        typeface: Typeface = .serif,
        ambientSound: AmbientSound = .off,
        remindersEnabled: Bool = true,
        reminderHour: Int = 8,
        reminderMinute: Int = 0
    ) {
        self.versesPerCard = versesPerCard.clamped(to: Self.versesPerCardRange)
        self.typeface = typeface
        self.ambientSound = ambientSound
        self.remindersEnabled = remindersEnabled
        self.reminderHour = reminderHour
        self.reminderMinute = reminderMinute
    }

    /// Clamps `versesPerCard` saved under an older, wider range (`didSet` doesn't run while decoding).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ReadingPreferences()
        self.init(
            versesPerCard: try container.decodeIfPresent(Int.self, forKey: .versesPerCard) ?? defaults.versesPerCard,
            typeface: try container.decodeIfPresent(Typeface.self, forKey: .typeface) ?? defaults.typeface,
            ambientSound: try container.decodeIfPresent(AmbientSound.self, forKey: .ambientSound) ?? defaults.ambientSound,
            remindersEnabled: try container.decodeIfPresent(Bool.self, forKey: .remindersEnabled) ?? defaults.remindersEnabled,
            reminderHour: try container.decodeIfPresent(Int.self, forKey: .reminderHour) ?? defaults.reminderHour,
            reminderMinute: try container.decodeIfPresent(Int.self, forKey: .reminderMinute) ?? defaults.reminderMinute
        )
    }
}

/// Where the user is in the book they chose: one chapter per day, in order.
public struct PlanProgress: Codable, Hashable, Sendable {
    public static let bookPlanID = "book"

    public var planID: String
    /// Book being read. `nil` until the reader picks one (including profiles created
    /// before books could be chosen).
    public var bookID: String?
    /// Number of chapters of `bookID` completed, i.e. the 0-based index of the next chapter.
    public var position: Int
    public var lastCompletedDay: DayKey?
    /// Chapter finished on `lastCompletedDay`; it stays on screen as "complete" until tomorrow.
    /// Cleared when the reader switches books so the new book can be started right away.
    public var lastCompletedChapterID: String?
    /// Where the reader left off in books they switched away from, so switching back resumes.
    public var savedPositions: [String: Int]
    /// When the reader last picked a book. A check-in after this makes that check-in's book
    /// the current one (see `reconcile(with:books:)`).
    public var bookChosenAt: Date?
    /// Books the reader got into (past the intro of a chapter) without checking in on any chapter
    /// yet, oldest first. They still count as started: Profile lists them with the rest.
    public var startedBookIDs: [String]

    public init(
        planID: String = PlanProgress.bookPlanID,
        bookID: String? = nil,
        position: Int = 0,
        lastCompletedDay: DayKey? = nil,
        lastCompletedChapterID: String? = nil,
        savedPositions: [String: Int] = [:],
        bookChosenAt: Date? = nil,
        startedBookIDs: [String] = []
    ) {
        self.startedBookIDs = startedBookIDs
        self.planID = planID
        self.bookID = bookID
        self.position = position
        self.lastCompletedDay = lastCompletedDay
        self.lastCompletedChapterID = lastCompletedChapterID
        self.savedPositions = savedPositions
        self.bookChosenAt = bookChosenAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            planID: try container.decodeIfPresent(String.self, forKey: .planID) ?? Self.bookPlanID,
            bookID: try container.decodeIfPresent(String.self, forKey: .bookID),
            position: try container.decodeIfPresent(Int.self, forKey: .position) ?? 0,
            lastCompletedDay: try container.decodeIfPresent(DayKey.self, forKey: .lastCompletedDay),
            lastCompletedChapterID: try container.decodeIfPresent(String.self, forKey: .lastCompletedChapterID),
            savedPositions: try container.decodeIfPresent([String: Int].self, forKey: .savedPositions) ?? [:],
            bookChosenAt: try container.decodeIfPresent(Date.self, forKey: .bookChosenAt),
            startedBookIDs: try container.decodeIfPresent([String].self, forKey: .startedBookIDs) ?? []
        )
    }

    /// Notes that the reader got into `bookID`. Returns whether that was news.
    @discardableResult
    public mutating func markStarted(_ bookID: String) -> Bool {
        guard !startedBookIDs.contains(bookID) else { return false }
        startedBookIDs.append(bookID)
        return true
    }

    /// Chapters already read in `bookID`, if the reader started it before and didn't finish.
    public func resumePosition(for bookID: String, chapterCount: Int) -> Int? {
        let saved = bookID == self.bookID ? position : savedPositions[bookID]
        guard let saved, saved > 0, saved < chapterCount else { return nil }
        return saved
    }

    /// Switches to `bookID` and makes its next chapter available today: from where the
    /// reader left off, or chapter 1 if it's new or was finished. The streak is unaffected.
    /// Choosing the book already being read changes nothing, unless it's finished: then it
    /// is read again from chapter 1.
    public mutating func start(bookID: String, chapterCount: Int, at date: Date = .now) {
        guard bookID != self.bookID else {
            guard chapterCount > 0, position >= chapterCount else { return }
            bookChosenAt = date
            position = 0
            lastCompletedChapterID = nil
            return
        }
        bookChosenAt = date
        if let current = self.bookID { savedPositions[current] = position }
        let saved = savedPositions.removeValue(forKey: bookID) ?? 0
        planID = Self.bookPlanID
        self.bookID = bookID
        position = saved < chapterCount ? saved : 0
        lastCompletedChapterID = nil
    }
}

public struct UserProfile: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var displayName: String?
    public var email: String?
    public var authProvider: AuthProvider
    public let createdAt: Date
    public var streak: StreakState
    public var totalChaptersRead: Int
    public var reflectionCount: Int
    public var subscription: SubscriptionState
    public var preferences: ReadingPreferences
    public var plan: PlanProgress
    public var onboarding: OnboardingAnswers?
    public var updatedAt: Date

    public init(
        id: String,
        displayName: String? = nil,
        email: String? = nil,
        authProvider: AuthProvider,
        createdAt: Date = .now,
        streak: StreakState = StreakState(),
        totalChaptersRead: Int = 0,
        reflectionCount: Int = 0,
        subscription: SubscriptionState = .free,
        preferences: ReadingPreferences = ReadingPreferences(),
        plan: PlanProgress,
        onboarding: OnboardingAnswers? = nil,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.authProvider = authProvider
        self.createdAt = createdAt
        self.streak = streak
        self.totalChaptersRead = totalChaptersRead
        self.reflectionCount = reflectionCount
        self.subscription = subscription
        self.preferences = preferences
        self.plan = plan
        self.onboarding = onboarding
        self.updatedAt = updatedAt
    }
}

extension UserProfile {
    /// Chooses between this device's copy of the profile and the account's. The copy changed
    /// last wins, except that reading is never lost to it: a device that hasn't caught up yet
    /// can hold the later change (a setting, say) while the other holds a finished chapter.
    /// In that case the streak, totals and last finished chapter come from the copy with
    /// more chapters read, and the result counts as a new change so it reaches both.
    public static func resolving(_ local: UserProfile?, _ remote: UserProfile?, now: Date = .now) -> UserProfile? {
        guard let local, let remote else { return local ?? remote }
        let localIsNewest = local.updatedAt >= remote.updatedAt
        var newest = localIsNewest ? local : remote
        let other = localIsNewest ? remote : local
        guard other.totalChaptersRead > newest.totalChaptersRead else { return newest }

        newest.streak = other.streak
        newest.totalChaptersRead = other.totalChaptersRead
        newest.reflectionCount = max(newest.reflectionCount, other.reflectionCount)
        if let finished = other.plan.lastCompletedDay, newest.plan.lastCompletedDay.map({ finished > $0 }) ?? true {
            newest.plan.lastCompletedDay = finished
            newest.plan.lastCompletedChapterID = other.plan.lastCompletedChapterID
        }
        newest.updatedAt = now
        return newest
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
