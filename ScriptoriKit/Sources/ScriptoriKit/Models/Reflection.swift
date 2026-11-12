import Foundation

public enum Mood: String, Codable, CaseIterable, Identifiable, Sendable {
    case peaceful, grateful, hopeful, curious, weary, struggling

    public var id: String { rawValue }

    public var emoji: String {
        switch self {
        case .peaceful: "🕊️"
        case .grateful: "🙏"
        case .hopeful: "🌱"
        case .curious: "💭"
        case .weary: "🌧️"
        case .struggling: "🪨"
        }
    }

    /// SF Symbol shown for the mood across check-in, reflection and Journal.
    public var symbol: String {
        switch self {
        case .peaceful: "bird.fill"
        case .grateful: "hands.and.sparkles.fill"
        case .hopeful: "sunrise.fill"
        case .curious: "lightbulb.fill"
        case .weary: "cloud.drizzle.fill"
        case .struggling: "mountain.2.fill"
        }
    }

    public var label: String { rawValue.capitalized }
}

public struct ReflectionAnswer: Codable, Hashable, Sendable {
    public let questionID: String
    public let prompt: String
    public var choice: String?
    public var text: String

    public init(questionID: String, prompt: String, choice: String? = nil, text: String = "") {
        self.questionID = questionID
        self.prompt = prompt
        self.choice = choice
        self.text = text
    }

    public var isAnswered: Bool {
        choice != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum SyncState: String, Codable, Sendable {
    case pending, synced
}

public struct ReflectionEntry: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let chapterID: String
    public let chapterReference: String
    public let day: DayKey
    public let createdAt: Date
    public var mood: Mood?
    public var takeaways: [String]
    public var answers: [ReflectionAnswer]
    /// Verses the reader marked while reading.
    public var highlights: [Int]
    public var syncState: SyncState
    /// Last edit after the entry was first saved; `nil` if never edited.
    public var updatedAt: Date?

    public init(
        id: UUID = UUID(),
        chapter: BibleChapter,
        day: DayKey,
        createdAt: Date = .now,
        mood: Mood? = nil,
        takeaways: [String] = [],
        answers: [ReflectionAnswer]? = nil,
        highlights: [Int] = [],
        syncState: SyncState = .pending,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.chapterID = chapter.id
        self.chapterReference = chapter.reference
        self.day = day
        self.createdAt = createdAt
        self.mood = mood
        self.takeaways = takeaways
        self.answers = answers ?? chapter.reflection.questions.map {
            ReflectionAnswer(questionID: $0.id, prompt: $0.prompt)
        }
        self.highlights = highlights
        self.syncState = syncState
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        chapterID = try container.decode(String.self, forKey: .chapterID)
        chapterReference = try container.decode(String.self, forKey: .chapterReference)
        day = try container.decode(DayKey.self, forKey: .day)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        mood = try container.decodeIfPresent(Mood.self, forKey: .mood)
        takeaways = try container.decodeIfPresent([String].self, forKey: .takeaways) ?? []
        answers = try container.decodeIfPresent([ReflectionAnswer].self, forKey: .answers) ?? []
        highlights = try container.decodeIfPresent([Int].self, forKey: .highlights) ?? []
        syncState = try container.decodeIfPresent(SyncState.self, forKey: .syncState) ?? .pending
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    /// When the entry last changed, for picking the newest copy during sync.
    public var lastModified: Date { updatedAt ?? createdAt }

    /// Merges two copies of the same journal, keeping the most recently edited version
    /// of each entry. Newest entries first.
    public static func merge(_ local: [ReflectionEntry], _ remote: [ReflectionEntry]) -> [ReflectionEntry] {
        var byID: [UUID: ReflectionEntry] = [:]
        for entry in remote + local {
            if let existing = byID[entry.id], existing.lastModified >= entry.lastModified { continue }
            byID[entry.id] = entry
        }
        return byID.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// A reflection "passes" once the user has checked in their mood and engaged
    /// with at least one guided question (quick choice or written answer).
    public var isSubmittable: Bool {
        mood != nil && answers.contains(where: \.isAnswered)
    }
}
