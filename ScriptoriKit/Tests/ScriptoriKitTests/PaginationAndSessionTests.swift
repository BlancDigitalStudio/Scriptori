import Foundation
import Testing
@testable import ScriptoriKit

func makeChapter(verseCount: Int = 11, themes: [ChapterTheme] = []) -> BibleChapter {
    BibleChapter(
        id: "TST.1", book: "Test", number: 1, translation: "KJV", title: nil, palette: "dawn",
        verses: (1...verseCount).map { BibleVerse(chapterID: "TST.1", number: $0, text: "Verse \($0)") },
        reflection: ReflectionGuide(
            questions: [ReflectionQuestion(id: "q1", prompt: "Why?", choices: ["A", "B"]), ReflectionQuestion(id: "q2", prompt: "How?")],
            takeaways: ["Peace"],
            themes: themes
        )
    )
}

struct VersePaginatorTests {
    @Test(arguments: 1...3)
    func pagesCoverEveryVerseOnce(size: Int) {
        let chapter = makeChapter()
        let pages = VersePaginator.pages(for: chapter.verses, versesPerCard: size)
        #expect(pages.flatMap(\.verses) == chapter.verses)
        #expect(pages.count == Int((Double(chapter.verses.count) / Double(size)).rounded(.up)))
        #expect(pages.dropLast().allSatisfy { $0.verses.count == size })
    }

    @Test func groupSizeIsClamped() {
        let verses = makeChapter().verses
        #expect(VersePaginator.pages(for: verses, versesPerCard: 0).count == 11)
        #expect(VersePaginator.pages(for: verses, versesPerCard: 9).first?.verses.count == 3)
    }

    @Test func repaginateKeepsAnchorVerseVisible() {
        let verses = makeChapter().verses
        let result = VersePaginator.repaginate(verses, anchoredAt: 7, versesPerCard: 2)
        #expect(result.pages[result.index].contains(verse: 7))
        #expect(result.pages[result.index].firstVerse == 7)

        let coarse = VersePaginator.repaginate(verses, anchoredAt: 8, versesPerCard: 3)
        #expect(coarse.pages[coarse.index].firstVerse == 7)
    }
}

@MainActor
struct ChapterSessionTests {
    let day = DayKey(year: 2026, month: 11, day: 11)

    @Test func feedHasIntroCardsAndReflection() {
        let session = ChapterSession(chapter: makeChapter(), day: day, versesPerCard: 2)
        #expect(session.items.first == .intro)
        #expect(session.items.last == .reflection)
        #expect(session.items.count == 1 + 6 + 1)
        #expect(session.focusedItemID == "intro")
    }

    @Test func themesCardFollowsIntroWhenChapterHasThemes() {
        let themes = (1...4).map { ChapterTheme(title: "T\($0)", summary: "", symbol: "leaf") }
        let chapter = makeChapter(themes: themes)
        #expect(chapter.reflection.themes.count == ReflectionGuide.maxThemes)

        let session = ChapterSession(chapter: chapter, day: day, versesPerCard: 2)
        #expect(Array(session.items.prefix(2)) == [.intro, .themes])
        #expect(session.items.count == 2 + 6 + 1)

        session.focus(on: "themes")
        #expect(session.progress.anchorVerse == 0)
        #expect(session.readFraction == 0)
    }

    @Test func takeawayOptionsListThemesFirstWithoutDuplicates() {
        let guide = ReflectionGuide(
            questions: [],
            takeaways: ["Rest", "Courage", "Joy"],
            themes: [ChapterTheme(title: "Joy", summary: "", symbol: "sun.max"), ChapterTheme(title: "Hope", summary: "", symbol: "sunrise")]
        )
        #expect(guide.takeawayOptions == ["Joy", "Hope", "Rest", "Courage"])
    }

    @Test func changingGroupingPreservesPosition() {
        let session = ChapterSession(chapter: makeChapter(), day: day, versesPerCard: 1)
        session.focus(on: "verses-8")
        session.setVersesPerCard(3)
        #expect(session.focusedPage?.contains(verse: 8) == true)
        #expect(session.focusedItemID == "verses-7")

        session.setVersesPerCard(2)
        #expect(session.focusedItemID == "verses-7")

        session.setVersesPerCard(1)
        #expect(session.focusedItemID == "verses-8")
    }

    @Test func groupingAboveThreeIsClamped() {
        let session = ChapterSession(chapter: makeChapter(), day: day, versesPerCard: 5)
        #expect(session.versesPerCard == 3)
        session.setVersesPerCard(1)
        session.setVersesPerCard(4)
        #expect(session.versesPerCard == 3)
    }

    @Test func introAndReflectionFocusSurviveRegrouping() {
        let session = ChapterSession(chapter: makeChapter(), day: day, versesPerCard: 1)
        session.setVersesPerCard(3)
        #expect(session.focusedItemID == "intro")
        session.focus(on: session.items.last?.id)
        session.setVersesPerCard(2)
        #expect(session.focusedItemID == "reflection")
    }

    @Test func progressTracksFurthestVerseAndReflection() {
        let chapter = makeChapter()
        let session = ChapterSession(chapter: chapter, day: day, versesPerCard: 3)
        var saved: ChapterProgress?
        session.onProgressChange = { saved = $0 }

        session.focus(on: "verses-7")
        #expect(saved?.furthestVerse == 9)
        session.focus(on: "verses-1")
        #expect(saved?.furthestVerse == 9)
        #expect(saved?.hasFinishedVerses(of: chapter) == false)

        session.focus(on: "reflection")
        #expect(saved?.hasFinishedVerses(of: chapter) == true)
    }

    @Test func restoresSavedPositionForSameDay() {
        let chapter = makeChapter()
        let saved = ChapterProgress(chapterID: chapter.id, day: day, anchorVerse: 9, furthestVerse: 10)
        let session = ChapterSession(chapter: chapter, day: day, versesPerCard: 2, restoring: saved)
        #expect(session.focusedItemID == "verses-9")

        let stale = ChapterSession(chapter: chapter, day: day.adding(days: 1), versesPerCard: 2, restoring: saved)
        #expect(stale.focusedItemID == "intro")
    }
}

@MainActor
struct LongChapterTests {
    let day = DayKey(year: 2026, month: 11, day: 11)

    private func checkpoints(_ session: ChapterSession) -> [Checkpoint] {
        session.items.compactMap { if case .checkpoint(let checkpoint) = $0 { checkpoint } else { nil } }
    }

    @Test func shortChaptersHaveNoCheckpoints() {
        let session = ChapterSession(chapter: makeChapter(verseCount: ChapterSession.checkpointThreshold), day: day, versesPerCard: 1)
        #expect(checkpoints(session).isEmpty)
    }

    @Test func longChaptersGetCheckpointsThatTileTheReading() {
        let session = ChapterSession(chapter: makeChapter(verseCount: 100), day: day, versesPerCard: 3)
        let found = checkpoints(session)
        #expect(found.count == 3)
        #expect(found.first?.fromVerse == 1)
        #expect(zip(found, found.dropFirst()).allSatisfy { $0.throughVerse + 1 == $1.fromVerse })
        #expect(found.allSatisfy { $0.range.count >= ChapterSession.checkpointSpacing })

        // A checkpoint always follows a verse card that ends on its last verse.
        for (index, item) in session.items.enumerated() {
            guard case .checkpoint(let checkpoint) = item, case .verses(let page) = session.items[index - 1] else { continue }
            #expect(page.lastVerse == checkpoint.throughVerse)
        }
        // Never right before the reflection.
        if case .checkpoint = session.items[session.items.count - 2] { Issue.record("Checkpoint directly before reflection") }
    }

    @Test func regroupingFromCheckpointLandsOnItsVerses() throws {
        let session = ChapterSession(chapter: makeChapter(verseCount: 100), day: day, versesPerCard: 3)
        let checkpoint = try #require(checkpoints(session).first)
        session.focus(on: FeedItem.checkpoint(checkpoint).id)
        #expect(session.progress.anchorVerse == checkpoint.throughVerse)
        #expect(session.readFraction == Double(checkpoint.throughVerse) / 100)

        session.setVersesPerCard(1)
        #expect(session.focusedItemID == "verses-\(checkpoint.throughVerse)")
    }

    @Test func checkpointsDoNotCountAsReadingVerses() throws {
        let chapter = makeChapter(verseCount: 100)
        let session = ChapterSession(chapter: chapter, day: day, versesPerCard: 3)
        let checkpoint = try #require(checkpoints(session).last)
        session.focus(on: FeedItem.checkpoint(checkpoint).id)
        #expect(session.progress.furthestVerse == 0)
    }

    @Test func markingTogglesWholeCardAndPersists() {
        let session = ChapterSession(chapter: makeChapter(), day: day, versesPerCard: 2)
        var saved: ChapterProgress?
        session.onProgressChange = { saved = $0 }
        let page = session.pages[1]

        session.toggleMark(page)
        #expect(session.isMarked(page))
        #expect(saved?.markedVerses == [3, 4])
        #expect(session.markedVerses.map(\.number) == [3, 4])

        session.toggleMark(session.pages[0])
        #expect(saved?.markedVerses == [1, 2, 3, 4])

        session.toggleMark(page)
        #expect(!session.isMarked(page))
        #expect(saved?.markedVerses == [1, 2])
    }

    @Test func checkpointNotesAreSavedInOrder() {
        let session = ChapterSession(chapter: makeChapter(verseCount: 100), day: day, versesPerCard: 3)
        let found = checkpoints(session)
        session.setNote("Later note", for: found[1])
        session.setNote("First note", for: found[0])
        session.setNote("   ", for: found[2])
        #expect(session.note(for: found[0]) == "First note")
        #expect(session.progress.orderedNotes.map(\.text) == ["First note", "Later note"])
    }

    @Test func progressSavedBeforeMarkingStillDecodes() throws {
        let legacy = #"{"chapterID":"TST.1","day":"2026-11-11","anchorVerse":3,"furthestVerse":4,"reachedReflection":false}"#
        let progress = try JSONDecoder().decode(ChapterProgress.self, from: Data(legacy.utf8))
        #expect(progress.anchorVerse == 3)
        #expect(progress.markedVerses.isEmpty)
        #expect(progress.notes.isEmpty)
    }

    @Test func citedVersesAreFoundInPrompts() {
        let chapter = makeChapter()
        #expect(chapter.citedVerses(in: "Verse 8 lists what to think on.").map(\.number) == [8])
        #expect(chapter.citedVerses(in: "Read verses 6–7 again.").map(\.number) == [6, 7])
        #expect(chapter.citedVerses(in: "What stood out?").isEmpty)
        #expect(chapter.citedVerses(in: "Verse 40 is out of range").isEmpty)
    }
}

struct CompletionTests {
    let service = ChapterCompletionService(engine: StreakEngine(calendar: utc))
    let chapter = makeChapter()
    let now = date(11)
    var today: DayKey { DayKey(now, calendar: utc) }

    func profile() -> UserProfile {
        UserProfile(id: "u1", authProvider: .guest, plan: PlanProgress(bookID: "TST", position: 3))
    }

    func finishedProgress() -> ChapterProgress {
        ChapterProgress(chapterID: chapter.id, day: today, furthestVerse: 11, reachedReflection: true)
    }

    func answeredEntry() -> ReflectionEntry {
        var entry = ReflectionEntry(chapter: chapter, day: today, mood: .grateful)
        entry.answers[0].choice = "A"
        return entry
    }

    @Test func completionUpdatesProfile() throws {
        let result = try service.complete(chapter: chapter, progress: finishedProgress(), reflection: answeredEntry(), profile: profile(), now: now)
        #expect(result.profile.streak.current == 1)
        #expect(result.profile.totalChaptersRead == 1)
        #expect(result.profile.reflectionCount == 1)
        #expect(result.profile.plan.position == 4)
        #expect(result.profile.plan.lastCompletedDay == today)
        #expect(result.profile.plan.lastCompletedChapterID == chapter.id)
        #expect(result.progress.isCompleted)
    }

    @Test func requiresAllVersesAndReflection() {
        var unread = finishedProgress()
        unread.reachedReflection = false
        #expect(throws: CompletionError.versesNotFinished) {
            try service.complete(chapter: chapter, progress: unread, reflection: answeredEntry(), profile: profile(), now: now)
        }

        let noMood = ReflectionEntry(chapter: chapter, day: today)
        #expect(throws: CompletionError.reflectionIncomplete) {
            try service.complete(chapter: chapter, progress: finishedProgress(), reflection: noMood, profile: profile(), now: now)
        }
    }

    @Test func cannotCompleteTwiceInADay() throws {
        let first = try service.complete(chapter: chapter, progress: finishedProgress(), reflection: answeredEntry(), profile: profile(), now: now)
        #expect(throws: CompletionError.alreadyCompletedToday) {
            try service.complete(chapter: chapter, progress: finishedProgress(), reflection: answeredEntry(), profile: first.profile, now: now)
        }
    }

    @Test func anotherBooksChapterCanBeCompletedTheSameDay() throws {
        let first = try service.complete(chapter: chapter, progress: finishedProgress(), reflection: answeredEntry(), profile: profile(), now: now)
        var switched = first.profile
        switched.plan.start(bookID: "GEN", chapterCount: 50)

        let genesis = BibleChapter(id: "GEN.1", book: "Genesis", number: 1, translation: "KJV", title: nil, palette: "dawn", verses: chapter.verses, reflection: chapter.reflection)
        let progress = ChapterProgress(chapterID: genesis.id, day: today, furthestVerse: 11, reachedReflection: true)
        var entry = ReflectionEntry(chapter: genesis, day: today, mood: .curious)
        entry.answers[0].choice = "A"
        let second = try service.complete(chapter: genesis, progress: progress, reflection: entry, profile: switched, now: now.addingTimeInterval(600))

        #expect(second.streak.event == .alreadyCompletedToday)
        #expect(second.profile.streak.current == 1)
        #expect(second.profile.totalChaptersRead == 2)
        #expect(second.profile.plan.position == 1)
        #expect(second.profile.plan.lastCompletedChapterID == "GEN.1")

        let upNext = DailyReadingResolver.reading(
            progress: second.profile.plan,
            books: [BibleBook(id: "GEN", name: "Genesis", testament: .old, category: "Law", chapterCount: 50)],
            today: today
        )
        guard case .chapter(let assignment) = upNext else { Issue.record("Expected a chapter"); return }
        #expect(assignment.chapterID == "GEN.1")
        #expect(assignment.isCompletedToday)
        #expect(assignment.nextChapterID == "GEN.2")
    }

    @Test func streakCountsChaptersFromAnyBookAndSwitchingBackResumes() throws {
        // Day 1: check in on TST 4 (position 3 → 4).
        let day1 = try service.complete(chapter: chapter, progress: finishedProgress(), reflection: answeredEntry(), profile: profile(), now: now)
        var switched = day1.profile
        switched.plan.start(bookID: "GEN", chapterCount: 50)
        #expect(switched.plan.position == 0)

        // Day 2: check in on Genesis 1 instead; the streak still grows.
        let nextDay = now.addingTimeInterval(86_400)
        let nextKey = DayKey(nextDay, calendar: utc)
        let genesis = BibleChapter(id: "GEN.1", book: "Genesis", number: 1, translation: "KJV", title: nil, palette: "dawn", verses: chapter.verses, reflection: chapter.reflection)
        var entry = ReflectionEntry(chapter: genesis, day: nextKey, mood: .peaceful)
        entry.answers[0].choice = "A"
        let day2 = try service.complete(
            chapter: genesis,
            progress: ChapterProgress(chapterID: genesis.id, day: nextKey, furthestVerse: 11, reachedReflection: true),
            reflection: entry,
            profile: switched,
            now: nextDay
        )
        #expect(day2.profile.streak.current == 2)

        // Back to TST: resumes on chapter 5, the first one without a check-in.
        var back = day2.profile
        back.plan.start(bookID: "TST", chapterCount: 10)
        #expect(back.plan.position == 4)
        #expect(back.plan.savedPositions["GEN"] == 1)
        let resumed = DailyReadingResolver.reading(
            progress: back.plan,
            books: [BibleBook(id: "TST", name: "Test", testament: .old, category: "Law", chapterCount: 10)],
            today: nextKey
        )
        guard case .chapter(let assignment) = resumed else { Issue.record("Expected a chapter"); return }
        #expect(assignment.chapterID == "TST.5")
        #expect(!assignment.isCompletedToday)
    }

    @Test func editingAnEntryCannotCountTwice() throws {
        let first = try service.complete(chapter: chapter, progress: finishedProgress(), reflection: answeredEntry(), profile: profile(), now: now)
        var edited = first.entry
        edited.answers[1].text = "Changed my mind"
        edited.updatedAt = now.addingTimeInterval(60)
        #expect(throws: CompletionError.alreadyCompletedToday) {
            try service.complete(chapter: chapter, progress: first.progress, reflection: edited, profile: first.profile, now: now.addingTimeInterval(60))
        }
        #expect(first.profile.streak.current == 1)
        #expect(first.profile.reflectionCount == 1)
    }
}

struct DailyReadingResolverTests {
    let books = [
        BibleBook(id: "AAA", name: "Alpha", testament: .old, category: "Law", chapterCount: 3),
        BibleBook(id: "BBB", name: "Beta", testament: .new, category: "Letters", chapterCount: 2),
    ]
    let today = DayKey(year: 2026, month: 11, day: 11)

    private func chapter(_ reading: DailyReading) -> DailyAssignment? {
        if case .chapter(let assignment) = reading { return assignment }
        return nil
    }

    @Test func needsBookWhenNoneChosen() {
        #expect(DailyReadingResolver.reading(progress: PlanProgress(), books: books, today: today) == .needsBook)
        #expect(DailyReadingResolver.reading(progress: PlanProgress(bookID: "ZZZ"), books: books, today: today) == .needsBook)
    }

    @Test func servesNextChapterOfChosenBook() throws {
        let assignment = try #require(chapter(DailyReadingResolver.reading(progress: PlanProgress(bookID: "AAA", position: 1), books: books, today: today)))
        #expect(assignment.chapterID == "AAA.2")
        #expect(assignment.progressLabel == "Chapter 2 of 3")
        #expect(!assignment.isCompletedToday)
        #expect(assignment.nextChapterID == "AAA.3")
    }

    @Test func holdsCompletedChapterUntilTomorrow() throws {
        let done = PlanProgress(bookID: "AAA", position: 2, lastCompletedDay: today, lastCompletedChapterID: "AAA.2")
        let assignment = try #require(chapter(DailyReadingResolver.reading(progress: done, books: books, today: today)))
        #expect(assignment.chapterID == "AAA.2")
        #expect(assignment.isCompletedToday)
        #expect(assignment.nextChapterID == "AAA.3")

        let tomorrow = try #require(chapter(DailyReadingResolver.reading(progress: done, books: books, today: today.adding(days: 1))))
        #expect(tomorrow.chapterID == "AAA.3")
        #expect(tomorrow.nextChapterID == nil)
    }

    @Test func finishingABookOffersTheNext() throws {
        let done = PlanProgress(bookID: "AAA", position: 3, lastCompletedDay: today, lastCompletedChapterID: "AAA.3")
        let assignment = try #require(chapter(DailyReadingResolver.reading(progress: done, books: books, today: today)))
        #expect(assignment.isCompletedToday)
        #expect(assignment.isBookFinished)
        #expect(assignment.nextChapterID == nil)

        #expect(DailyReadingResolver.reading(progress: done, books: books, today: today.adding(days: 1)) == .bookFinished(bookID: "AAA"))
    }

    @Test func switchingBooksAfterCompletingTodayStartsTheNewBookNow() throws {
        var plan = PlanProgress(bookID: "AAA", position: 3, lastCompletedDay: today, lastCompletedChapterID: "AAA.3")
        plan.start(bookID: "BBB", chapterCount: 2)
        #expect(plan.position == 0)

        let todayView = try #require(chapter(DailyReadingResolver.reading(progress: plan, books: books, today: today)))
        #expect(todayView.chapterID == "BBB.1")
        #expect(!todayView.isCompletedToday)
        #expect(todayView.nextChapterID == "BBB.2")
    }

    @Test func switchingBackResumesWhereTheReaderLeftOff() {
        var plan = PlanProgress(bookID: "AAA", position: 2)
        plan.start(bookID: "BBB", chapterCount: 2)
        #expect(plan.resumePosition(for: "AAA", chapterCount: 3) == 2)
        plan.position = 1
        plan.start(bookID: "AAA", chapterCount: 3)
        #expect(plan.position == 2)
        #expect(plan.savedPositions == ["BBB": 1])

        // A finished book restarts from chapter 1.
        plan.position = 3
        plan.start(bookID: "BBB", chapterCount: 2)
        plan.start(bookID: "AAA", chapterCount: 3)
        #expect(plan.position == 0)
        #expect(plan.resumePosition(for: "AAA", chapterCount: 3) == nil)
    }

    @Test func choosingTheCurrentBookChangesNothing() {
        var plan = PlanProgress(bookID: "AAA", position: 2, lastCompletedDay: today, lastCompletedChapterID: "AAA.2")
        plan.start(bookID: "AAA", chapterCount: 3)
        #expect(plan.position == 2)
        #expect(plan.lastCompletedChapterID == "AAA.2")
    }

    @Test func legacyCompletionWithoutChapterIDServesAReadableChapter() throws {
        // Completed today before the finished chapter was recorded: nothing to hold, so the
        // chapter is open for reading (and its reflection) rather than shown as already done.
        let legacy = PlanProgress(bookID: "BBB", position: 0, lastCompletedDay: today)
        let assignment = try #require(chapter(DailyReadingResolver.reading(progress: legacy, books: books, today: today)))
        #expect(assignment.chapterID == "BBB.1")
        #expect(!assignment.isCompletedToday)
        #expect(assignment.nextChapterID == "BBB.2")
    }
}

struct ContentTests {
    @Test func bundlesTheWholeBible() async throws {
        let library = try BundledContentLibrary()
        #expect(library.books.count == 66)
        #expect(library.books.reduce(0) { $0 + $1.chapterCount } == 1189)
        #expect(library.books.filter { $0.testament == .old }.count == 39)
        #expect(Set(library.books.map(\.id)).count == 66)
        #expect(library.books.allSatisfy { !$0.blurb.isEmpty && !$0.themes.isEmpty && !$0.intents.isEmpty })

        for book in library.books {
            let last = try await library.chapter(bookID: book.id, number: book.chapterCount)
            #expect(!last.verses.isEmpty, "\(book.id) \(book.chapterCount)")
        }
        #expect(try await library.chapter(id: "PSA.119").verses.count == 176)
        #expect(try await library.chapter(id: "GEN.1").verses.first?.text.hasPrefix("In the beginning") == true)
    }

    @Test func authoredGuidesAreMergedWithText() async throws {
        let library = try BundledContentLibrary()
        let psalm = try await library.chapter(id: "PSA.23")
        #expect(psalm.verses.count == 6)
        #expect(psalm.title == "The Lord Is My Shepherd")
        #expect(psalm.palette == "meadow")
        #expect(psalm.reflection.themes.map(\.title) == ["Provision", "Rest", "Presence"])
        #expect(try await library.chapter(id: "PHP.4").verses[12].text.hasPrefix("I can do all things"))
    }

    @Test(arguments: ["PSA.1", "PSA.23", "PSA.46", "PSA.121", "PHP.1", "PHP.2", "PHP.3", "PHP.4"])
    func everyGuideIsWellFormed(id: String) async throws {
        let chapter = try await BundledContentLibrary().chapter(id: id)
        let guide = chapter.reflection
        #expect(chapter.title != nil)
        #expect((1...ReflectionGuide.maxThemes).contains(guide.themes.count))
        #expect((2...3).contains(guide.questions.count))
        #expect(!guide.takeaways.isEmpty)
        #expect(Set(guide.questions.map(\.id)).count == guide.questions.count)
        for theme in guide.themes {
            let verse = try #require(theme.keyVerse)
            #expect(chapter.verses.indices.contains(verse - 1), "\(id) \(theme.title) v.\(verse)")
        }
    }

    @Test func chaptersWithoutGuidesGetFallback() async throws {
        let library = try BundledContentLibrary()
        let genesis = try await library.chapter(id: "GEN.1")
        #expect(genesis.title == nil)
        #expect(genesis.reflection.themes.isEmpty)
        #expect(genesis.reflection.questions.count == 3)
        #expect(genesis.reflection.takeaways.starts(with: ["Creation", "Promise", "Family"]))
        #expect(genesis.palette == library.book(id: "GEN")?.palette)

        let other = try await library.chapter(id: "GEN.2")
        #expect(Set(genesis.reflection.questions.map(\.id)).isDisjoint(with: other.reflection.questions.map(\.id)))
    }

    @Test func unknownChaptersThrow() async throws {
        let library = try BundledContentLibrary()
        await #expect(throws: ContentError.self) { try await library.chapter(id: "PHP.5") }
        await #expect(throws: ContentError.self) { try await library.chapter(id: "XYZ.1") }
        await #expect(throws: ContentError.self) { try await library.chapter(id: "nonsense") }
    }

    @Test func localStoreRoundTrips() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LocalStore(directory: dir)
        let profile = UserProfile(id: "u1", authProvider: .apple, plan: PlanProgress(bookID: "PHP"))
        try await store.save(profile, for: .profile, namespace: "u1")
        let loaded = await store.load(UserProfile.self, for: .profile, namespace: "u1")
        #expect(loaded?.id == "u1")
        #expect(loaded?.plan.bookID == "PHP")
        try await store.removeAll(namespace: "u1")
        #expect(await store.load(UserProfile.self, for: .profile, namespace: "u1") == nil)
    }
}
