import Foundation

public struct BibleVerse: Codable, Hashable, Identifiable, Sendable {
    public let chapterID: String
    public let number: Int
    public let text: String

    public var id: String { "\(chapterID).\(number)" }

    public init(chapterID: String, number: Int, text: String) {
        self.chapterID = chapterID
        self.number = number
        self.text = text
    }
}

public struct BibleChapter: Codable, Hashable, Identifiable, Sendable {
    /// OSIS-style identifier, e.g. `PSA.23`.
    public let id: String
    public let book: String
    public let number: Int
    public let translation: String
    public let title: String?
    /// Name of the gradient palette the UI should use for this chapter.
    public let palette: String
    public let verses: [BibleVerse]
    public let reflection: ReflectionGuide

    public var reference: String { "\(book) \(number)" }
    public var bookID: String { ChapterID.parse(id)?.bookID ?? id }

    public init(
        id: String,
        book: String,
        number: Int,
        translation: String,
        title: String?,
        palette: String,
        verses: [BibleVerse],
        reflection: ReflectionGuide
    ) {
        self.id = id
        self.book = book
        self.number = number
        self.translation = translation
        self.title = title
        self.palette = palette
        self.verses = verses
        self.reflection = reflection
    }

    public func reference(for verses: [BibleVerse]) -> String {
        guard let first = verses.first?.number, let last = verses.last?.number else { return reference }
        return first == last ? "\(reference):\(first)" : "\(reference):\(first)–\(last)"
    }

    public func verses(in range: ClosedRange<Int>) -> [BibleVerse] {
        verses.filter { range.contains($0.number) }
    }

    /// Verses a prompt points at, e.g. "Verse 8 lists…" or "verses 6–7".
    public func citedVerses(in prompt: String) -> [BibleVerse] {
        guard let match = prompt.firstMatch(of: /[Vv]erses? (\d+)(?:\s*[–-]\s*(\d+))?/),
              let first = Int(match.1) else { return [] }
        let last = match.2.flatMap { Int($0) } ?? first
        return verses(in: first...max(first, last))
    }
}

public enum ChapterID {
    public static func make(bookID: String, number: Int) -> String { "\(bookID).\(number)" }

    public static func parse(_ id: String) -> (bookID: String, number: Int)? {
        let parts = id.split(separator: ".")
        guard parts.count == 2, let number = Int(parts[1]) else { return nil }
        return (String(parts[0]), number)
    }
}

public enum Testament: String, Codable, CaseIterable, Sendable {
    case old, new

    public var label: String {
        switch self {
        case .old: "Old Testament"
        case .new: "New Testament"
        }
    }
}

/// Catalog entry for one book, used by onboarding and the library.
public struct BibleBook: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let testament: Testament
    public let category: String
    public let palette: String
    /// 1 = a good first book, 3 = best read with some background.
    public let level: Int
    public let chapterCount: Int
    public let minutesPerDay: Int
    public let blurb: String
    public let themes: [String]
    public let intents: [ReadingIntent]

    public init(
        id: String,
        name: String,
        testament: Testament,
        category: String,
        palette: String = "dawn",
        level: Int = 1,
        chapterCount: Int,
        minutesPerDay: Int = 3,
        blurb: String = "",
        themes: [String] = [],
        intents: [ReadingIntent] = []
    ) {
        self.id = id
        self.name = name
        self.testament = testament
        self.category = category
        self.palette = palette
        self.level = level
        self.chapterCount = chapterCount
        self.minutesPerDay = minutesPerDay
        self.blurb = blurb
        self.themes = themes
        self.intents = intents
    }
}

/// One of the (at most three) big ideas shown on the card after a chapter's intro.
public struct ChapterTheme: Codable, Hashable, Identifiable, Sendable {
    public let title: String
    public let summary: String
    /// SF Symbol name.
    public let symbol: String
    public let keyVerse: Int?

    public var id: String { title }

    public init(title: String, summary: String, symbol: String, keyVerse: Int? = nil) {
        self.title = title
        self.summary = summary
        self.symbol = symbol
        self.keyVerse = keyVerse
    }
}

/// Chapter-specific guided reflection shown after the final verse card.
public struct ReflectionGuide: Codable, Hashable, Sendable {
    public static let maxThemes = 3

    public let questions: [ReflectionQuestion]
    /// One-tap "Key Takeaway" tags offered before the open prompts.
    public let takeaways: [String]
    public let themes: [ChapterTheme]

    public init(questions: [ReflectionQuestion], takeaways: [String], themes: [ChapterTheme] = []) {
        self.questions = questions
        self.takeaways = takeaways
        self.themes = Array(themes.prefix(Self.maxThemes))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            questions: try container.decode([ReflectionQuestion].self, forKey: .questions),
            takeaways: try container.decode([String].self, forKey: .takeaways),
            themes: try container.decodeIfPresent([ChapterTheme].self, forKey: .themes) ?? []
        )
    }

    /// Takeaway chips: the chapter's themes first, then its other tags.
    public var takeawayOptions: [String] {
        var seen = Set<String>()
        return (themes.map(\.title) + takeaways).filter { seen.insert($0).inserted }
    }

    /// General reflection for chapters that don't have an authored guide yet.
    public static func fallback(for book: BibleBook, chapter: Int) -> ReflectionGuide {
        let prefix = "\(book.id.lowercased())\(chapter)-g"
        return ReflectionGuide(
            questions: [
                ReflectionQuestion(id: "\(prefix)1", prompt: "What stood out to you most in this chapter?", choices: ["A promise", "A warning", "An example", "A question"]),
                ReflectionQuestion(id: "\(prefix)2", prompt: "Which verse do you want to carry into today, and why?"),
                ReflectionQuestion(id: "\(prefix)3", prompt: "What is one small way to live this out before tomorrow?"),
            ],
            takeaways: book.themes + ["Something new", "A reminder"]
        )
    }
}

public struct ReflectionQuestion: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let prompt: String
    /// Optional quick-choice answers; an empty list means open text only.
    public let choices: [String]

    public init(id: String, prompt: String, choices: [String] = []) {
        self.id = id
        self.prompt = prompt
        self.choices = choices
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        prompt = try container.decode(String.self, forKey: .prompt)
        choices = try container.decodeIfPresent([String].self, forKey: .choices) ?? []
    }
}
