import Foundation
import Observation

/// A pause card in long chapters that recaps the stretch just read.
public struct Checkpoint: Hashable, Sendable {
    public let fromVerse: Int
    public let throughVerse: Int

    public init(fromVerse: Int, throughVerse: Int) {
        self.fromVerse = fromVerse
        self.throughVerse = throughVerse
    }

    public var range: ClosedRange<Int> { fromVerse...throughVerse }
}

public enum FeedItem: Hashable, Identifiable, Sendable {
    case intro
    case themes
    case verses(VersePage)
    case checkpoint(Checkpoint)
    case reflection

    public var id: String {
        switch self {
        case .intro: "intro"
        case .themes: "themes"
        case .verses(let page): "verses-\(page.id)"
        case .checkpoint(let checkpoint): "checkpoint-\(checkpoint.throughVerse)"
        case .reflection: "reflection"
        }
    }
}

/// Persisted reading position and completion for the current chapter. `day` is the day it
/// was last opened; an unfinished chapter carries over to the next day it's opened.
public struct ChapterProgress: Codable, Hashable, Sendable {
    public let chapterID: String
    public let day: DayKey
    /// First verse of the card the reader last focused (0 = chapter intro).
    public var anchorVerse: Int
    public var furthestVerse: Int
    public var reachedReflection: Bool
    public var completedAt: Date?
    /// Verses the reader marked as standing out, in order.
    public var markedVerses: [Int]
    /// Quick notes jotted on checkpoint cards, keyed by the checkpoint's last verse.
    public var notes: [Int: String]
    /// When the reader last moved, marked a verse or wrote a note. Decides which copy wins
    /// when two devices hold different progress; `nil` for progress saved before it existed.
    public var updatedAt: Date?

    public init(
        chapterID: String,
        day: DayKey,
        anchorVerse: Int = 0,
        furthestVerse: Int = 0,
        reachedReflection: Bool = false,
        completedAt: Date? = nil,
        markedVerses: [Int] = [],
        notes: [Int: String] = [:],
        updatedAt: Date? = nil
    ) {
        self.chapterID = chapterID
        self.day = day
        self.anchorVerse = anchorVerse
        self.furthestVerse = furthestVerse
        self.reachedReflection = reachedReflection
        self.completedAt = completedAt
        self.markedVerses = markedVerses
        self.notes = notes
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            chapterID: try container.decode(String.self, forKey: .chapterID),
            day: try container.decode(DayKey.self, forKey: .day),
            anchorVerse: try container.decode(Int.self, forKey: .anchorVerse),
            furthestVerse: try container.decode(Int.self, forKey: .furthestVerse),
            reachedReflection: try container.decode(Bool.self, forKey: .reachedReflection),
            completedAt: try container.decodeIfPresent(Date.self, forKey: .completedAt),
            markedVerses: try container.decodeIfPresent([Int].self, forKey: .markedVerses) ?? [],
            notes: try container.decodeIfPresent([Int: String].self, forKey: .notes) ?? [:],
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        )
    }

    public var isCompleted: Bool { completedAt != nil }

    /// The same position, marks and notes, dated `day`, so finishing counts for that day.
    public func carried(to day: DayKey) -> ChapterProgress {
        ChapterProgress(
            chapterID: chapterID,
            day: day,
            anchorVerse: anchorVerse,
            furthestVerse: furthestVerse,
            reachedReflection: reachedReflection,
            completedAt: completedAt,
            markedVerses: markedVerses,
            notes: notes,
            updatedAt: updatedAt
        )
    }

    /// Progress for a chapter known to be finished (the plan and journal say so) when its own
    /// record isn't on this device: the reader lands on the last card, with their marks.
    public static func completed(chapter: BibleChapter, day: DayKey, at date: Date, markedVerses: [Int] = []) -> ChapterProgress {
        ChapterProgress(
            chapterID: chapter.id,
            day: day,
            furthestVerse: chapter.verses.last?.number ?? 0,
            reachedReflection: true,
            completedAt: date,
            markedVerses: markedVerses,
            updatedAt: date
        )
    }

    /// Whether this copy was changed more recently than `other` (another device's, say).
    /// Differences under a millisecond don't count: a time loses that much precision on its
    /// way through the cloud, and a copy must not look newer than itself after a round trip.
    public func isNewer(than other: ChapterProgress) -> Bool {
        (updatedAt ?? .distantPast).timeIntervalSince(other.updatedAt ?? .distantPast) > 0.001
    }

    public func hasFinishedVerses(of chapter: BibleChapter) -> Bool {
        reachedReflection && furthestVerse >= (chapter.verses.last?.number ?? 0)
    }

    /// Non-empty checkpoint notes in reading order.
    public var orderedNotes: [(throughVerse: Int, text: String)] {
        notes
            .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }
}

/// Drives the vertical feed for a single chapter: pagination, focus, and progress.
@Observable
@MainActor
public final class ChapterSession {
    /// Chapters longer than this get checkpoint cards.
    public static let checkpointThreshold = 40
    /// Roughly how many verses between checkpoints.
    public static let checkpointSpacing = 30

    public let chapter: BibleChapter
    public private(set) var versesPerCard: Int
    public private(set) var pages: [VersePage]
    public private(set) var items: [FeedItem]
    public private(set) var progress: ChapterProgress
    public private(set) var focusedItemID: String?

    @ObservationIgnored public var onProgressChange: (@MainActor (ChapterProgress) -> Void)?

    public init(chapter: BibleChapter, day: DayKey, versesPerCard: Int, restoring saved: ChapterProgress? = nil) {
        self.chapter = chapter
        let progress: ChapterProgress
        if let saved, saved.chapterID == chapter.id, saved.day == day {
            progress = saved
        } else if let saved, saved.chapterID == chapter.id, !saved.isCompleted {
            // An unfinished chapter picked up on a later day keeps the reader's place and marks.
            progress = saved.carried(to: day)
        } else {
            progress = ChapterProgress(chapterID: chapter.id, day: day)
        }
        self.progress = progress
        self.versesPerCard = versesPerCard.clamped(to: ReadingPreferences.versesPerCardRange)
        let pages = VersePaginator.pages(for: chapter.verses, versesPerCard: versesPerCard)
        self.pages = pages
        self.items = Self.makeItems(pages, chapter: chapter)
        self.focusedItemID = progress.reachedReflection && progress.anchorVerse == 0
            ? FeedItem.reflection.id
            : Self.itemID(forAnchor: progress.anchorVerse, in: pages)
    }

    public var focusedItem: FeedItem? {
        items.first { $0.id == focusedItemID }
    }

    public var focusedPage: VersePage? {
        if case .verses(let page) = focusedItem { return page }
        return nil
    }

    /// 0...1 progress through the chapter's verses, for the progress rail.
    public var readFraction: Double {
        guard let total = chapter.verses.last?.number, total > 0 else { return 0 }
        switch focusedItem {
        case .reflection: return 1
        case .verses(let page): return Double(page.lastVerse) / Double(total)
        case .checkpoint(let checkpoint): return Double(checkpoint.throughVerse) / Double(total)
        case .intro, .themes, nil: return 0
        }
    }

    public func focus(on itemID: String?) {
        guard let itemID, itemID != focusedItemID, let item = items.first(where: { $0.id == itemID }) else { return }
        focusedItemID = itemID

        switch item {
        case .intro, .themes:
            progress.anchorVerse = 0
        case .verses(let page):
            progress.anchorVerse = page.firstVerse
            progress.furthestVerse = max(progress.furthestVerse, page.lastVerse)
        case .checkpoint(let checkpoint):
            progress.anchorVerse = checkpoint.throughVerse
        case .reflection:
            progress.anchorVerse = 0
            progress.reachedReflection = true
            progress.furthestVerse = max(progress.furthestVerse, chapter.verses.last?.number ?? 0)
        }
        progressChanged()
    }

    /// Re-groups cards (1–3 verses each) while keeping the reader on the same verse.
    /// The anchor is the verse the reader last scrolled to, so 1 → 3 → 1 lands back
    /// on the exact verse rather than the start of the wider card.
    public func setVersesPerCard(_ count: Int) {
        let count = count.clamped(to: ReadingPreferences.versesPerCardRange)
        guard count != versesPerCard else { return }
        let wasInVerses: Bool
        switch focusedItem {
        case .verses, .checkpoint: wasInVerses = true
        default: wasInVerses = false
        }
        versesPerCard = count

        let result = VersePaginator.repaginate(chapter.verses, anchoredAt: max(progress.anchorVerse, 1), versesPerCard: count)
        pages = result.pages
        items = Self.makeItems(result.pages, chapter: chapter)

        if wasInVerses, result.pages.indices.contains(result.index) {
            focusedItemID = FeedItem.verses(result.pages[result.index]).id
        }
    }

    /// Takes on reading done on another device in this chapter: moves to that card and shows
    /// its marks and notes. Nothing is reported through `onProgressChange`; this isn't a
    /// change the reader made here, so it must not be sent back as one.
    public func adopt(_ remote: ChapterProgress) {
        guard remote.chapterID == chapter.id else { return }
        progress = remote.day == progress.day ? remote : remote.carried(to: progress.day)
        focusedItemID = progress.reachedReflection && progress.anchorVerse == 0
            ? FeedItem.reflection.id
            : Self.itemID(forAnchor: progress.anchorVerse, in: pages)
    }

    public func markCompleted(at date: Date = .now) {
        progress.completedAt = date
        // `updatedAt` decides which device's copy is newer, so it is always the real time,
        // even when `date` isn't (a debug day offset).
        progressChanged()
    }

    // MARK: Marking & notes

    public func isMarked(_ page: VersePage) -> Bool {
        page.verses.contains { progress.markedVerses.contains($0.number) }
    }

    /// Marks every verse on the card, or clears them if any were already marked.
    public func toggleMark(_ page: VersePage) {
        let numbers = page.verses.map(\.number)
        if isMarked(page) {
            progress.markedVerses.removeAll { numbers.contains($0) }
        } else {
            progress.markedVerses = Array(Set(progress.markedVerses + numbers)).sorted()
        }
        progressChanged()
    }

    public var markedVerses: [BibleVerse] {
        chapter.verses.filter { progress.markedVerses.contains($0.number) }
    }

    public func note(for checkpoint: Checkpoint) -> String {
        progress.notes[checkpoint.throughVerse] ?? ""
    }

    public func setNote(_ text: String, for checkpoint: Checkpoint) {
        progress.notes[checkpoint.throughVerse] = text
        progressChanged()
    }

    private func progressChanged() {
        progress.updatedAt = .now
        onProgressChange?(progress)
    }

    // MARK: Items

    static func makeItems(_ pages: [VersePage], chapter: BibleChapter) -> [FeedItem] {
        var items: [FeedItem] = [.intro]
        if !chapter.reflection.themes.isEmpty { items.append(.themes) }

        let total = chapter.verses.last?.number ?? 0
        let usesCheckpoints = total > checkpointThreshold
        var stretchStart = 1
        for page in pages {
            items.append(.verses(page))
            // Never right before the reflection, which recaps the whole chapter anyway.
            if usesCheckpoints, page.lastVerse - stretchStart + 1 >= checkpointSpacing, total - page.lastVerse >= checkpointSpacing / 3 {
                items.append(.checkpoint(Checkpoint(fromVerse: stretchStart, throughVerse: page.lastVerse)))
                stretchStart = page.lastVerse + 1
            }
        }
        items.append(.reflection)
        return items
    }

    private static func itemID(forAnchor anchor: Int, in pages: [VersePage]) -> String {
        guard anchor > 0, !pages.isEmpty else { return FeedItem.intro.id }
        return FeedItem.verses(pages[VersePaginator.pageIndex(containing: anchor, in: pages)]).id
    }
}
