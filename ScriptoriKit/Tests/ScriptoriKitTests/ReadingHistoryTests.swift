import Foundation
import Testing
@testable import ScriptoriKit

struct ReadingHistoryTests {
    let books = [
        BibleBook(id: "GEN", name: "Genesis", testament: .old, category: "Law", chapterCount: 50),
        BibleBook(id: "PSA", name: "Psalms", testament: .old, category: "Wisdom", chapterCount: 150),
        BibleBook(id: "PHP", name: "Philippians", testament: .new, category: "Letters", chapterCount: 4),
    ]

    func entry(_ chapterID: String, day: String, hour: Int) -> ReflectionEntry {
        let parsed = ChapterID.parse(chapterID)!
        let chapter = BibleChapter(id: chapterID, book: parsed.bookID, number: parsed.number, translation: "KJV", title: nil, palette: "dawn", verses: [], reflection: ReflectionGuide(questions: [], takeaways: []))
        let parts = day.split(separator: "-").map { Int($0)! }
        let key = DayKey(year: parts[0], month: parts[1], day: parts[2])
        return ReflectionEntry(chapter: chapter, day: key, createdAt: key.startDate(in: utc).addingTimeInterval(Double(hour) * 3600))
    }

    @Test func progressComesFromCheckIns() {
        let history = ReadingHistory(entries: [entry("GEN.2", day: "2026-11-12", hour: 17), entry("GEN.1", day: "2026-11-11", hour: 17), entry("PSA.1", day: "2026-11-11", hour: 15)])
        #expect(history.chaptersRead(in: "GEN") == 2)
        #expect(history.chaptersRead(in: "PSA") == 1)
        #expect(history.nextPosition(in: "PSA", chapterCount: 150) == 1)
        #expect(history.startedBookIDs == ["GEN", "PSA"])
        #expect(history.latest?.chapterID == "GEN.2")
    }

    @Test func resumesAtTheFirstChapterWithoutACheckIn() {
        let history = ReadingHistory(entries: [entry("PHP.1", day: "2026-11-01", hour: 9), entry("PHP.3", day: "2026-11-03", hour: 9)])
        #expect(history.nextPosition(in: "PHP", chapterCount: 4) == 1)
        let all = ReadingHistory(entries: (1...4).map { entry("PHP.\($0)", day: "2026-11-0\($0)", hour: 9) })
        #expect(all.nextPosition(in: "PHP", chapterCount: 4) == 4)
    }

    /// The reported profile: Psalm 1's check-in was lost from the counter by an older build.
    @Test func repairsAProfileWhoseCountersLostACheckIn() throws {
        let history = ReadingHistory(entries: [entry("GEN.2", day: "2026-11-12", hour: 17), entry("GEN.1", day: "2026-11-11", hour: 17), entry("PSA.1", day: "2026-11-11", hour: 15)])
        var plan = PlanProgress(bookID: "PSA", position: 0, lastCompletedDay: DayKey(year: 2026, month: 11, day: 11), savedPositions: ["GEN": 1, "PHP": 0])
        plan.reconcile(with: history, books: books)
        #expect(plan.bookID == "GEN")
        #expect(plan.position == 2)
        #expect(plan.savedPositions["PSA"] == 1)
        #expect(plan.savedPositions["GEN"] == nil)

        var psalms = plan
        psalms.start(bookID: "PSA", chapterCount: 150)
        let reading = DailyReadingResolver.reading(progress: psalms, books: books, today: DayKey(year: 2026, month: 11, day: 13))
        guard case .chapter(let assignment) = reading else { Issue.record("Expected a chapter"); return }
        #expect(assignment.chapterID == "PSA.2")
    }

    @Test func nextDayServesTheFollowingChapterOfTheLatestBook() throws {
        let history = ReadingHistory(entries: [entry("PSA.1", day: "2026-11-11", hour: 15)])
        var plan = PlanProgress(bookID: "PSA", position: 0, lastCompletedDay: DayKey(year: 2026, month: 11, day: 11))
        plan.reconcile(with: history, books: books)
        let reading = DailyReadingResolver.reading(progress: plan, books: books, today: DayKey(year: 2026, month: 11, day: 12))
        guard case .chapter(let assignment) = reading else { Issue.record("Expected a chapter"); return }
        #expect(assignment.chapterID == "PSA.2")
        #expect(!assignment.isCompletedToday)
    }

    @Test func aBookPickedAfterTheLatestCheckInStaysCurrent() {
        let history = ReadingHistory(entries: [entry("GEN.1", day: "2026-11-11", hour: 9)])
        var plan = PlanProgress(bookID: "GEN", position: 1)
        plan.start(bookID: "PHP", chapterCount: 4, at: DayKey(year: 2026, month: 11, day: 11).startDate(in: utc).addingTimeInterval(12 * 3600))
        plan.reconcile(with: history, books: books)
        #expect(plan.bookID == "PHP")
        #expect(plan.position == 0)
        #expect(plan.savedPositions["GEN"] == 1)
    }

    @Test func autoSwitchKeepsTodaysCheckInOnScreen() throws {
        let today = DayKey(year: 2026, month: 11, day: 12)
        let history = ReadingHistory(entries: [entry("GEN.2", day: "2026-11-12", hour: 17), entry("GEN.1", day: "2026-11-11", hour: 17)])
        var plan = PlanProgress(bookID: "PSA", position: 0, lastCompletedDay: today)
        plan.reconcile(with: history, books: books)
        let reading = DailyReadingResolver.reading(progress: plan, books: books, today: today)
        guard case .chapter(let assignment) = reading else { Issue.record("Expected a chapter"); return }
        #expect(assignment.chapterID == "GEN.2")
        #expect(assignment.isCompletedToday)
        #expect(assignment.nextChapterID == "GEN.3")
    }

    @Test func plansWithoutBookChosenAtStillDecode() throws {
        let json = #"{"planID":"book","bookID":"GEN","position":2,"savedPositions":{"PSA":0}}"#
        let plan = try JSONDecoder().decode(PlanProgress.self, from: Data(json.utf8))
        #expect(plan.bookChosenAt == nil)
        #expect(plan.position == 2)
    }
}
