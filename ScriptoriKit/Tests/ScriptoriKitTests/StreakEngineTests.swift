import Foundation
import Testing
@testable import ScriptoriKit

let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

func date(_ day: Int, hour: Int = 9, month: Int = 11) -> Date {
    utc.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
}

struct StreakEngineTests {
    let engine = StreakEngine(calendar: utc)

    @Test func firstCompletionStartsStreak() {
        let update = engine.recordCompletion(StreakState(), at: date(1))
        #expect(update.event == .started)
        #expect(update.state.current == 1)
        #expect(update.state.longest == 1)
    }

    @Test func consecutiveDaysExtendAndHitMilestone() {
        var state = StreakState()
        var last: StreakUpdate?
        for day in 1...3 {
            last = engine.recordCompletion(state, at: date(day))
            state = last!.state
        }
        #expect(state.current == 3)
        #expect(last?.event == .extended)
        #expect(last?.milestone == 3)
    }

    @Test func sameDayCompletionIsIgnored() {
        let first = engine.recordCompletion(StreakState(), at: date(1, hour: 8)).state
        let second = engine.recordCompletion(first, at: date(1, hour: 22))
        #expect(second.event == .alreadyCompletedToday)
        #expect(second.state == first)
    }

    @Test func missingOneDayIsRepairableWithinGraceWindow() {
        let state = StreakState(current: 5, longest: 5, lastCompletedDay: DayKey(date(1), calendar: utc))
        guard case .repairable = engine.status(of: state, now: date(3, hour: 23)) else {
            Issue.record("expected repairable")
            return
        }
        let update = engine.recordCompletion(state, at: date(3, hour: 23))
        #expect(update.event == .repaired)
        #expect(update.state.current == 6)
        #expect(update.state.lastRepairDay == DayKey(date(3), calendar: utc))
    }

    @Test func shorterGraceWindowExpires() {
        var shortGrace = engine
        shortGrace.policy.graceHours = 6
        let state = StreakState(current: 5, longest: 5, lastCompletedDay: DayKey(date(1), calendar: utc))
        #expect(shortGrace.status(of: state, now: date(3, hour: 7)) == .broken)
        let update = shortGrace.recordCompletion(state, at: date(3, hour: 7))
        #expect(update.event == .restarted(previous: 5))
        #expect(update.state.current == 1)
        #expect(update.state.longest == 5)
    }

    @Test func repairIsRateLimitedByCooldown() {
        let state = StreakState(
            current: 10, longest: 10,
            lastCompletedDay: DayKey(date(5), calendar: utc),
            lastRepairDay: DayKey(date(2), calendar: utc)
        )
        #expect(engine.status(of: state, now: date(7)) == .broken)
        #expect(engine.displayedStreak(state, now: date(7)) == 0)
    }

    @Test func twoMissedDaysBreaksStreak() {
        let state = StreakState(current: 4, longest: 4, lastCompletedDay: DayKey(date(1), calendar: utc))
        #expect(engine.status(of: state, now: date(4)) == .broken)
    }

    @Test func streakSpansMonthBoundary() {
        let state = StreakState(current: 2, longest: 2, lastCompletedDay: DayKey(date(31, month: 10), calendar: utc))
        #expect(engine.recordCompletion(state, at: date(1)).event == .extended)
    }

    @Test func dayKeyRoundTripsAsString() throws {
        let key = DayKey(year: 2026, month: 3, day: 7)
        let data = try JSONEncoder().encode(key)
        #expect(String(data: data, encoding: .utf8) == "\"2026-03-07\"")
        #expect(try JSONDecoder().decode(DayKey.self, from: data) == key)
    }
}
