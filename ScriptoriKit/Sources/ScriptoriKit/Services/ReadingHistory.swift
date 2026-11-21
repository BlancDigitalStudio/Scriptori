import Foundation

/// What the reader has actually checked in on, derived from their journal. Every completed
/// chapter produces exactly one reflection, so the journal is the source of truth for
/// progress; `PlanProgress` counters are reconciled against it.
///
/// A chapter can be checked in on more than once: the reader finishes a book, then reads it
/// again. Each check-in is its own journal entry; the chapter list shows the latest one.
public struct ReadingHistory: Equatable, Sendable {
    public struct CompletedChapter: Equatable, Identifiable, Sendable {
        public let chapterID: String
        public let bookID: String
        public let number: Int
        /// The most recent check-in on this chapter.
        public let entryID: UUID
        public let day: DayKey
        /// When the most recent check-in happened.
        public let completedAt: Date
        /// How many times the chapter has been checked in on (2+ once reread).
        public let checkInCount: Int
        public var id: String { chapterID }
    }

    /// The reader's progress through one book in the current round of reading it.
    public struct BookProgress: Equatable, Sendable {
        /// Chapters checked in on in this round.
        public let read: Int
        /// 1 for the first time through the book, 2 once it's being read again, and so on.
        public let round: Int
        /// Every chapter of this round is done.
        public let isComplete: Bool

        public var isRereading: Bool { round > 1 && !isComplete }
    }

    private struct CheckIn: Equatable, Sendable {
        let number: Int
        let at: Date
    }

    /// Newest first, one per chapter (its most recent check-in).
    public let chapters: [CompletedChapter]
    private let checkIns: [String: [CheckIn]]

    public init(entries: [ReflectionEntry]) {
        var latest: [String: ReflectionEntry] = [:]
        var counts: [String: Int] = [:]
        var byBook: [String: [CheckIn]] = [:]
        for entry in entries {
            guard let parsed = ChapterID.parse(entry.chapterID) else { continue }
            counts[entry.chapterID, default: 0] += 1
            byBook[parsed.bookID, default: []].append(CheckIn(number: parsed.number, at: entry.createdAt))
            if let existing = latest[entry.chapterID], existing.createdAt >= entry.createdAt { continue }
            latest[entry.chapterID] = entry
        }
        chapters = latest.values
            .compactMap { entry -> CompletedChapter? in
                guard let parsed = ChapterID.parse(entry.chapterID) else { return nil }
                return CompletedChapter(chapterID: entry.chapterID, bookID: parsed.bookID, number: parsed.number, entryID: entry.id, day: entry.day, completedAt: entry.createdAt, checkInCount: counts[entry.chapterID] ?? 1)
            }
            .sorted { $0.completedAt != $1.completedAt ? $0.completedAt > $1.completedAt : $0.chapterID < $1.chapterID }
        checkIns = byBook.mapValues { $0.sorted { $0.at < $1.at } }
    }

    /// Chapters checked in on at least once, in any round.
    public func completedNumbers(in bookID: String) -> Set<Int> {
        Set(chapters.lazy.filter { $0.bookID == bookID }.map(\.number))
    }

    /// Distinct chapters checked in on, across every round.
    public func chaptersRead(in bookID: String) -> Int {
        completedNumbers(in: bookID).count
    }

    /// The chapters of the round the reader is in, and which round that is. A new round starts
    /// when a chapter is checked in on again after every chapter of the book was done.
    private func currentRound(in bookID: String, chapterCount: Int) -> (numbers: Set<Int>, round: Int) {
        var numbers = Set<Int>()
        var round = 1
        for checkIn in checkIns[bookID] ?? [] {
            if numbers.contains(checkIn.number) {
                // A repeat only means "reading again" once the book was finished; otherwise it's
                // the same chapter recorded twice (say, from two devices) and changes nothing.
                guard Self.isComplete(numbers, chapterCount: chapterCount) else { continue }
                numbers = [checkIn.number]
                round += 1
            } else {
                numbers.insert(checkIn.number)
            }
        }
        return (numbers, round)
    }

    private static func isComplete(_ numbers: Set<Int>, chapterCount: Int) -> Bool {
        chapterCount > 0 && (1...chapterCount).allSatisfy(numbers.contains)
    }

    /// Progress through `bookID` in the current round. Once a finished book is started again, the
    /// new round shows from its first chapter, before any chapter of it is checked in on.
    public func progress(in bookID: String, chapterCount: Int, plan: PlanProgress) -> BookProgress {
        let current = currentRound(in: bookID, chapterCount: chapterCount)
        if Self.isComplete(current.numbers, chapterCount: chapterCount), plan.bookID == bookID, plan.position < chapterCount {
            return BookProgress(read: plan.position, round: current.round + 1, isComplete: false)
        }
        return BookProgress(
            read: min(current.numbers.count, chapterCount),
            round: current.round,
            isComplete: Self.isComplete(current.numbers, chapterCount: chapterCount)
        )
    }

    /// 0-based index of the first chapter without a check-in in the current round
    /// (`chapterCount` when every chapter is done).
    public func nextPosition(in bookID: String, chapterCount: Int) -> Int {
        let done = currentRound(in: bookID, chapterCount: chapterCount).numbers
        return ((1...max(chapterCount, 1)).first { !done.contains($0) } ?? (chapterCount + 1)) - 1
    }

    /// When `bookID` was last checked in on, if ever.
    public func lastCheckIn(in bookID: String) -> Date? {
        checkIns[bookID]?.last?.at
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
    /// - every book resumes on its first chapter without a check-in in the current round;
    /// - a finished book the reader started again keeps its place, until it's checked in on.
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
            let next = history.nextPosition(in: bookID, chapterCount: chapterCount)
            let startedAgain = next >= chapterCount && position < chapterCount
                && (bookChosenAt.map { chosen in history.lastCheckIn(in: bookID).map { chosen > $0 } ?? true } ?? false)
            if !startedAgain { position = next }
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
