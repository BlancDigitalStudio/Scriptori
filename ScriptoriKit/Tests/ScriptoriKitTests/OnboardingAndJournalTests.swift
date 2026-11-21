import Foundation
import Testing
@testable import ScriptoriKit

struct BookRecommenderTests {
    @Test func peaceForNewReadersSuggestsShortFriendlyBooks() throws {
        let books = try BundledContentLibrary().books
        let picks = BookRecommender.recommend(from: books, intent: .peace, familiarity: .new)
        #expect(picks.count == 3)
        #expect(picks.map(\.id).contains("PHP"))
        #expect(picks.allSatisfy { $0.level == 1 && $0.intents.contains(.peace) })
    }

    @Test(arguments: ReadingIntent.allCases)
    func everyIntentHasMatchingBeginnerBooks(intent: ReadingIntent) throws {
        let books = try BundledContentLibrary().books
        let picks = BookRecommender.recommend(from: books, intent: intent, familiarity: .new)
        #expect(picks.count == 3)
        #expect(picks.allSatisfy { $0.intents.contains(intent) })
    }

    @Test func experiencedReadersCanGetHarderBooks() {
        let easy = BibleBook(id: "E", name: "Easy", testament: .new, category: "", level: 1, chapterCount: 20, intents: [.understand])
        let hard = BibleBook(id: "H", name: "Hard", testament: .old, category: "", level: 3, chapterCount: 10, intents: [.understand])
        #expect(BookRecommender.recommend(from: [hard, easy], intent: .understand, familiarity: .new, limit: 1).first?.id == "E")
        #expect(BookRecommender.recommend(from: [hard, easy], intent: .understand, familiarity: .often, limit: 1).first?.id == "H")
    }

    @Test func skippingQuestionsStillRecommends() throws {
        let books = try BundledContentLibrary().books
        let picks = BookRecommender.recommend(from: books, intent: nil, familiarity: nil)
        #expect(picks.map(\.id) == ["PHP", "JHN", "PSA"])
    }
}

struct PreferencesTests {
    @Test func oldWiderGroupingIsClampedOnDecode() throws {
        let json = #"{"versesPerCard":5,"typeface":"sans","ambientSound":"rain","remindersEnabled":false,"reminderHour":7,"reminderMinute":30}"#
        let prefs = try JSONDecoder().decode(ReadingPreferences.self, from: Data(json.utf8))
        #expect(prefs.versesPerCard == 3)
        #expect(prefs.typeface == .sans)
        #expect(prefs.ambientSound == .rain)
        #expect(prefs.remindersEnabled == false)
        #expect(prefs.reminderHour == 7)
    }

    @Test func retiredAmbientModesDecodeAsOff() throws {
        for legacy in ["lofi", "voice"] {
            let json = #"{"versesPerCard":3,"typeface":"serif","ambientSound":"\#(legacy)","remindersEnabled":true,"reminderHour":8,"reminderMinute":0}"#
            let prefs = try JSONDecoder().decode(ReadingPreferences.self, from: Data(json.utf8))
            #expect(prefs.ambientSound == .off)
        }
        #expect(AmbientSound.allCases == [.off, .rain, .waves, .wind])
    }

    @Test func profilesFromTheFixedPlanStillDecode() throws {
        let profile = UserProfile(id: "u1", authProvider: .apple, plan: PlanProgress(planID: "foundations", position: 2))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
        json["plan"] = ["planID": "foundations", "position": 2]
        json.removeValue(forKey: "onboarding")
        let decoded = try JSONDecoder().decode(UserProfile.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.plan.bookID == nil)
        #expect(decoded.plan.position == 2)
        #expect(decoded.onboarding == nil)
    }

    @Test func onboardingAnswersRoundTrip() throws {
        var profile = UserProfile(id: "u1", authProvider: .apple, plan: PlanProgress(bookID: "PHP"))
        profile.onboarding = OnboardingAnswers(intent: .hardSeason, familiarity: .some, bookID: "PHP", cue: "Before bed")
        let decoded = try JSONDecoder().decode(UserProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded.onboarding == profile.onboarding)
        #expect(ReadingIntent.hardSeason.phrase == "getting through a hard season")
    }
}

struct JournalTests {
    let chapter = makeChapter()
    let day = DayKey(year: 2026, month: 11, day: 11)

    @Test func mergeKeepsTheMostRecentlyEditedCopy() {
        let original = ReflectionEntry(chapter: chapter, day: day, createdAt: Date(timeIntervalSince1970: 1_000), mood: .weary, syncState: .synced)
        var edited = original
        edited.mood = .hopeful
        edited.updatedAt = Date(timeIntervalSince1970: 2_000)
        edited.syncState = .pending

        #expect(ReflectionEntry.merge([edited], [original]).first?.mood == .hopeful)
        #expect(ReflectionEntry.merge([original], [edited]).first?.mood == .hopeful)
        #expect(ReflectionEntry.merge([original], [original]).first?.syncState == .synced)
    }

    @Test func mergeCombinesAndSortsNewestFirst() {
        let older = ReflectionEntry(chapter: chapter, day: day, createdAt: Date(timeIntervalSince1970: 1_000))
        let newer = ReflectionEntry(chapter: chapter, day: day.adding(days: 1), createdAt: Date(timeIntervalSince1970: 90_000))
        let merged = ReflectionEntry.merge([older], [newer])
        #expect(merged.map(\.id) == [newer.id, older.id])
    }

    @Test func entriesSavedBeforeEditingStillDecode() throws {
        let entry = ReflectionEntry(chapter: chapter, day: day, mood: .grateful)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as! [String: Any]
        json.removeValue(forKey: "highlights")
        json.removeValue(forKey: "updatedAt")
        let decoded = try JSONDecoder().decode(ReflectionEntry.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.id == entry.id)
        #expect(decoded.highlights.isEmpty)
        #expect(decoded.updatedAt == nil)
        #expect(decoded.lastModified == decoded.createdAt)
    }

    @Test func unfinishedCheckInCarriesOverToALaterDay() {
        var draft = ReflectionEntry(chapter: chapter, day: day, createdAt: Date(timeIntervalSince1970: 1_000), mood: .weary)
        draft.takeaways = ["rest"]
        let tomorrow = day.adding(days: 1)
        let resumedAt = Date(timeIntervalSince1970: 90_000)

        let carried = draft.carried(to: tomorrow, at: resumedAt)
        #expect(carried.id == draft.id)
        #expect(carried.day == tomorrow)
        #expect(carried.createdAt == resumedAt)
        #expect(carried.mood == .weary)
        #expect(carried.takeaways == ["rest"])
        #expect(carried.answers == draft.answers)

        #expect(draft.carried(to: day, at: resumedAt) == draft)
    }

    @Test func newestCheckInDraftWinsAcrossDevices() {
        let opened = Date(timeIntervalSince1970: 1_000)
        let phone = ReflectionEntry(chapter: chapter, day: day, createdAt: opened, mood: .weary)
        var tablet = phone
        tablet.mood = .hopeful
        tablet.updatedAt = opened.addingTimeInterval(60)

        #expect(tablet.isNewer(than: phone))
        #expect(!phone.isNewer(than: tablet))
        #expect(!tablet.isNewer(than: tablet))

        // The cloud stores times less precisely; the same draft must not look newer than itself.
        var roundTripped = tablet
        roundTripped.updatedAt = tablet.updatedAt?.addingTimeInterval(0.0000004)
        #expect(!roundTripped.isNewer(than: tablet))
    }

    @Test func everyMoodHasAnIcon() {
        #expect(Set(Mood.allCases.map(\.symbol)).count == Mood.allCases.count)
    }
}

struct ProfileResolvingTests {
    private func profile(read: Int, lastDay: DayKey?, chapter: String?, updatedAt: Date, versesPerCard: Int = 2) -> UserProfile {
        var profile = UserProfile(
            id: "u",
            authProvider: .email,
            streak: StreakState(current: read, longest: read, lastCompletedDay: lastDay),
            totalChaptersRead: read,
            reflectionCount: read,
            plan: PlanProgress(bookID: "COL", position: read, lastCompletedDay: lastDay, lastCompletedChapterID: chapter),
            updatedAt: updatedAt
        )
        profile.preferences.versesPerCard = versesPerCard
        return profile
    }

    @Test func newestCopyWinsWhenItHasAllTheReading() {
        let old = profile(read: 1, lastDay: DayKey(year: 2026, month: 11, day: 20), chapter: "COL.1", updatedAt: Date(timeIntervalSince1970: 100))
        let new = profile(read: 2, lastDay: DayKey(year: 2026, month: 11, day: 23), chapter: "COL.2", updatedAt: Date(timeIntervalSince1970: 200))
        #expect(UserProfile.resolving(old, new) == new)
        #expect(UserProfile.resolving(new, old) == new)
        #expect(UserProfile.resolving(nil, old) == old)
        #expect(UserProfile.resolving(old, nil) == old)
        #expect(UserProfile.resolving(nil, nil) == nil)
    }

    @Test func aChapterFinishedOnTheOlderCopyIsNotLost() {
        let finishedDay = DayKey(year: 2026, month: 11, day: 23)
        let finished = profile(read: 2, lastDay: finishedDay, chapter: "COL.2", updatedAt: Date(timeIntervalSince1970: 100))
        // A device that hasn't caught up, changed afterwards (a setting).
        let behind = profile(read: 1, lastDay: DayKey(year: 2026, month: 11, day: 21), chapter: nil, updatedAt: Date(timeIntervalSince1970: 200), versesPerCard: 3)
        let now = Date(timeIntervalSince1970: 300)

        let resolved = UserProfile.resolving(behind, finished, now: now)
        #expect(resolved?.totalChaptersRead == 2)
        #expect(resolved?.streak == finished.streak)
        #expect(resolved?.plan.lastCompletedDay == finishedDay)
        #expect(resolved?.plan.lastCompletedChapterID == "COL.2")
        #expect(resolved?.preferences.versesPerCard == 3)
        #expect(resolved?.updatedAt == now)
        #expect(UserProfile.resolving(finished, behind, now: now) == resolved)
    }
}
