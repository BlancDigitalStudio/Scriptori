import Foundation

/// One swipe card's worth of verses.
public struct VersePage: Hashable, Identifiable, Sendable {
    public let verses: [BibleVerse]

    /// Pages are identified by their first verse so a card keeps its identity
    /// whenever the grouping lands on the same starting verse.
    public var id: Int { firstVerse }
    public var firstVerse: Int { verses.first?.number ?? 0 }
    public var lastVerse: Int { verses.last?.number ?? 0 }

    public func contains(verse number: Int) -> Bool {
        (firstVerse...lastVerse).contains(number)
    }
}

public enum VersePaginator {
    public static func pages(for verses: [BibleVerse], versesPerCard: Int) -> [VersePage] {
        let size = versesPerCard.clamped(to: ReadingPreferences.versesPerCardRange)
        return stride(from: 0, to: verses.count, by: size).map { start in
            VersePage(verses: Array(verses[start..<min(start + size, verses.count)]))
        }
    }

    /// Index of the page containing `verse`, or the closest page when it's out of range.
    public static func pageIndex(containing verse: Int, in pages: [VersePage]) -> Int {
        if let index = pages.firstIndex(where: { $0.contains(verse: verse) }) {
            return index
        }
        return verse < (pages.first?.firstVerse ?? 0) ? 0 : max(pages.count - 1, 0)
    }

    /// Re-groups the chapter while keeping the reader anchored on the verse they were looking at.
    public static func repaginate(
        _ verses: [BibleVerse],
        anchoredAt anchorVerse: Int,
        versesPerCard: Int
    ) -> (pages: [VersePage], index: Int) {
        let pages = pages(for: verses, versesPerCard: versesPerCard)
        return (pages, pageIndex(containing: anchorVerse, in: pages))
    }
}
