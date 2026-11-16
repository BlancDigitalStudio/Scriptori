import Foundation

/// What the reader has actually checked in on, derived from their journal. Every completed
/// chapter produces exactly one reflection, so the journal is the source of truth for
/// progress; `PlanProgress` counters are reconciled against it.
public struct ReadingHistory: Equatable, Sendable {
    public struct CompletedChapter: Equatable, Identifiable, Sendable {
        public let chapterID: String
        public let bookID: String
        public let number: Int
        public let entryID: UUID
        public let day: DayKey
        public let completedAt: Date
        public var id: String { chapterID }
    }

    /// Newest first, one per chapter (the first check-in on it).
    public let chapters: [CompletedChapter]

    public init(entries: [ReflectionEntry]) {
        var firstCheckIn: [String: CompletedChapter] = [:]
        for entry in entries {
            guard let parsed = ChapterID.parse(entry.chapterID) else { continue }
            let chapter = CompletedChapter(chapterID: entry.chapterID, bookID: parsed.bookID, number: parsed.number, entryID: entry.id, day: entry.day, completedAt: entry.createdAt)
            if let existing = firstCheckIn[entry.chapterID], existing.completedAt <= entry.createdAt { continue }
            firstCheckIn[entry.chapterID] = chapter
        }
        chapters = firstCheckIn.values.sorted { $0.completedAt > $1.completedAt }
    }

    public func completedNumbers(in bookID: String) -> Set<Int> {
        Set(chapters.lazy.filter { $0.bookID == bookID }.map(\.number))
    }

    public func chaptersRead(in bookID: String) -> Int {
        completedNumbers(in: bookID).count
    }

    /// 0-based index of the first chapter without a check-in (`chapterCount` when all are done).
    public func nextPosition(in bookID: String, chapterCount: Int) -> Int {
        let done = completedNumbers(in: bookID)
        return ((1...max(chapterCount, 1)).first { !done.contains($0) } ?? (chapterCount + 1)) - 1
    }

    /// Books with at least one check-in, most recently checked-in first.
    public var startedBookIDs: [String] {
        var seen = Set<String>()
        return chapters.compactMap { seen.insert($0.bookID).inserted ? $0.bookID : nil }
    }

    public var latest: CompletedChapter? { chapters.first }
}

extension PlanProgress {
    /// Brings the plan in line with what was actually checked in on:
    /// - the current book is the one with the most recent check-in, unless the reader picked
    ///   a book after that check-in;
    /// - every book resumes on its first chapter without a check-in.
    public mutating func reconcile(with history: ReadingHistory, books: [BibleBook]) {
        func count(_ id: String) -> Int? { books.first { $0.id == id }?.chapterCount }

        if let latest = history.latest, latest.bookID != bookID, count(latest.bookID) != nil,
           bookChosenAt.map({ latest.completedAt > $0 }) ?? true {
            bookID = latest.bookID
            planID = Self.bookPlanID
            // Keep showing that chapter as done if it was today's check-in.
            lastCompletedChapterID = lastCompletedDay == latest.day ? latest.chapterID : nil
        }

        if let bookID, let chapterCount = count(bookID) {
            position = history.nextPosition(in: bookID, chapterCount: chapterCount)
        }
        for started in history.startedBookIDs where started != bookID {
            guard let chapterCount = count(started) else { continue }
            savedPositions[started] = history.nextPosition(in: started, chapterCount: chapterCount)
        }
        if let bookID { savedPositions.removeValue(forKey: bookID) }

        if let held = lastCompletedChapterID, ChapterID.parse(held)?.bookID != bookID {
            lastCompletedChapterID = nil
        }
    }
}
