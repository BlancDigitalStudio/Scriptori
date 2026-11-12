import Foundation

public struct DailyAssignment: Equatable, Sendable {
    public let chapterID: String
    public let chapterNumber: Int
    /// Chapters in the book `chapterID` belongs to.
    public let chapterCount: Int
    public let isCompletedToday: Bool
    /// Every chapter of the reader's current book is done; offer the next book.
    public let isBookFinished: Bool
    /// Chapter that will be served tomorrow, when there is one.
    public let nextChapterID: String?

    public init(chapterID: String, chapterNumber: Int, chapterCount: Int, isCompletedToday: Bool, isBookFinished: Bool = false, nextChapterID: String? = nil) {
        self.chapterID = chapterID
        self.chapterNumber = chapterNumber
        self.chapterCount = chapterCount
        self.isCompletedToday = isCompletedToday
        self.isBookFinished = isBookFinished
        self.nextChapterID = nextChapterID
    }

    public var progressLabel: String { "Chapter \(chapterNumber) of \(chapterCount)" }

    public func markingCompleted() -> DailyAssignment {
        DailyAssignment(chapterID: chapterID, chapterNumber: chapterNumber, chapterCount: chapterCount, isCompletedToday: true, isBookFinished: isBookFinished, nextChapterID: nextChapterID)
    }
}

public enum DailyReading: Equatable, Sendable {
    /// No book chosen yet.
    case needsBook
    /// The current book is finished and nothing was completed today.
    case bookFinished(bookID: String)
    case chapter(DailyAssignment)
}

public enum DailyReadingResolver {
    /// One chapter per day from the chosen book: today's chapter stays on screen (as
    /// completed) until tomorrow, then the next chapter is served.
    public static func reading(progress: PlanProgress, books: [BibleBook], today: DayKey) -> DailyReading {
        guard let bookID = progress.bookID, let book = books.first(where: { $0.id == bookID }) else { return .needsBook }
        let isFinished = progress.position >= book.chapterCount
        let next = isFinished ? nil : ChapterID.make(bookID: bookID, number: progress.position + 1)

        // Hold today's finished chapter on screen. Without a recorded chapter (the reader just
        // switched books, or the profile predates it) there's nothing to hold: serve the next one.
        if progress.lastCompletedDay == today, let shownID = progress.lastCompletedChapterID {
            if let parsed = ChapterID.parse(shownID), let shownBook = books.first(where: { $0.id == parsed.bookID }) {
                return .chapter(DailyAssignment(
                    chapterID: shownID,
                    chapterNumber: parsed.number,
                    chapterCount: shownBook.chapterCount,
                    isCompletedToday: true,
                    isBookFinished: isFinished,
                    nextChapterID: next
                ))
            }
        }

        guard let next else { return .bookFinished(bookID: bookID) }
        let nextIsLast = progress.position + 1 >= book.chapterCount
        return .chapter(DailyAssignment(
            chapterID: next,
            chapterNumber: progress.position + 1,
            chapterCount: book.chapterCount,
            isCompletedToday: false,
            nextChapterID: nextIsLast ? nil : ChapterID.make(bookID: bookID, number: progress.position + 2)
        ))
    }
}

public enum CompletionError: Error, Equatable, Sendable {
    case versesNotFinished
    case reflectionIncomplete
    case alreadyCompletedToday
}

public struct CompletionResult: Sendable {
    public let profile: UserProfile
    public let entry: ReflectionEntry
    public let progress: ChapterProgress
    public let streak: StreakUpdate
}

/// Applies the "chapter complete" transaction: validates the reading and reflection,
/// then updates streak, totals and plan position in one pure step.
public struct ChapterCompletionService: Sendable {
    public var engine: StreakEngine

    public init(engine: StreakEngine = StreakEngine()) {
        self.engine = engine
    }

    public func complete(
        chapter: BibleChapter,
        progress: ChapterProgress,
        reflection: ReflectionEntry,
        profile: UserProfile,
        now: Date = .now
    ) throws(CompletionError) -> CompletionResult {
        let today = DayKey(now, calendar: engine.calendar)
        // A different chapter on the same day (after switching books) still counts as reading;
        // the streak engine treats it as a no-op for the streak itself.
        let finishedThisChapterToday = profile.plan.lastCompletedDay == today && profile.plan.lastCompletedChapterID == chapter.id
        guard !finishedThisChapterToday, !progress.isCompleted else { throw .alreadyCompletedToday }
        guard progress.hasFinishedVerses(of: chapter) else { throw .versesNotFinished }
        guard reflection.isSubmittable else { throw .reflectionIncomplete }

        let streak = engine.recordCompletion(profile.streak, at: now)

        var updated = profile
        updated.streak = streak.state
        updated.totalChaptersRead += 1
        updated.reflectionCount += 1
        updated.plan.position += 1
        updated.plan.lastCompletedDay = today
        updated.plan.lastCompletedChapterID = chapter.id
        updated.updatedAt = now

        var finished = progress
        finished.completedAt = now

        return CompletionResult(profile: updated, entry: reflection, progress: finished, streak: streak)
    }
}
