import Foundation

/// "Why are you here?" — the first onboarding question.
public enum ReadingIntent: String, Codable, CaseIterable, Identifiable, Sendable {
    case peace, habit, understand, hardSeason, grow

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .peace: "Finding peace"
        case .habit: "Building a daily habit"
        case .understand: "Understanding the Bible"
        case .hardSeason: "Getting through a hard season"
        case .grow: "Growing in faith"
        }
    }

    public var symbol: String {
        switch self {
        case .peace: "leaf.fill"
        case .habit: "calendar.badge.checkmark"
        case .understand: "book.fill"
        case .hardSeason: "cloud.sun.fill"
        case .grow: "chart.line.uptrend.xyaxis"
        }
    }

    /// Lowercase phrase for sentences like "Philippians, for finding peace".
    public var phrase: String { label.prefix(1).lowercased() + label.dropFirst() }
}

public enum BibleFamiliarity: String, Codable, CaseIterable, Identifiable, Sendable {
    case new, some, often

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .new: "New to the Bible"
        case .some: "Some experience"
        case .often: "I read it often"
        }
    }

    public var symbol: String {
        switch self {
        case .new: "sparkle"
        case .some: "book.closed.fill"
        case .often: "books.vertical.fill"
        }
    }

    /// Highest `BibleBook.level` that fits comfortably.
    var comfortableLevel: Int {
        switch self {
        case .new: 1
        case .some: 2
        case .often: 3
        }
    }
}

/// What the reader told us during onboarding; kept on the profile to personalize copy.
public struct OnboardingAnswers: Codable, Hashable, Sendable {
    public var intent: ReadingIntent?
    public var familiarity: BibleFamiliarity?
    public var bookID: String?
    /// Everyday moment the reader tied their reading to, e.g. "With morning coffee".
    public var cue: String?

    public init(intent: ReadingIntent? = nil, familiarity: BibleFamiliarity? = nil, bookID: String? = nil, cue: String? = nil) {
        self.intent = intent
        self.familiarity = familiarity
        self.bookID = bookID
        self.cue = cue
    }
}

public enum BookRecommender {
    /// Ranks books by how well they match the reader's intent and familiarity.
    /// Matching intent dominates (without one, books that suit many intents rank first);
    /// books above the reader's comfort level are pushed down, and shorter books win ties
    /// so a first plan feels finishable.
    public static func recommend(
        from books: [BibleBook],
        intent: ReadingIntent?,
        familiarity: BibleFamiliarity?,
        limit: Int = 3
    ) -> [BibleBook] {
        let comfort = familiarity?.comfortableLevel ?? 1
        let scored = books.enumerated().map { index, book -> (book: BibleBook, score: Int, index: Int) in
            var score = 0
            if let intent {
                if let rank = book.intents.firstIndex(of: intent) { score += 100 - rank * 10 }
            } else {
                score += book.intents.count * 10
            }
            if book.level > comfort { score -= 40 * (book.level - comfort) }
            if familiarity == .new, book.chapterCount <= 6 { score += 5 }
            return (book, score, index)
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.book.chapterCount != rhs.book.chapterCount { return lhs.book.chapterCount < rhs.book.chapterCount }
                return lhs.index < rhs.index
            }
            .prefix(limit)
            .map(\.book)
    }
}
