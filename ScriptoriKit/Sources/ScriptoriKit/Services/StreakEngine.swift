import Foundation

public struct StreakState: Codable, Hashable, Sendable {
    public var current: Int
    public var longest: Int
    public var lastCompletedDay: DayKey?
    public var lastRepairDay: DayKey?
    /// Most recent completion days (newest last), capped for calendar display.
    public var recentDays: [DayKey]

    public init(current: Int = 0, longest: Int = 0, lastCompletedDay: DayKey? = nil, lastRepairDay: DayKey? = nil, recentDays: [DayKey] = []) {
        self.current = current
        self.longest = longest
        self.lastCompletedDay = lastCompletedDay
        self.lastRepairDay = lastRepairDay
        self.recentDays = recentDays
    }
}

public struct StreakPolicy: Sendable {
    /// How long after a missed day ends the streak can still be repaired by completing a chapter.
    public var graceHours: Int
    /// Minimum days between two repairs, so the buffer stays a safety net rather than a loophole.
    public var repairCooldownDays: Int
    public var milestones: Set<Int>
    public var historyLimit: Int

    public init(graceHours: Int = 24, repairCooldownDays: Int = 7, milestones: Set<Int> = [3, 7, 14, 30, 50, 100, 200, 365], historyLimit: Int = 60) {
        self.graceHours = graceHours
        self.repairCooldownDays = repairCooldownDays
        self.milestones = milestones
        self.historyLimit = historyLimit
    }
}

public enum StreakStatus: Equatable, Sendable {
    case notStarted
    case completedToday
    /// Streak is alive; complete today's chapter before `deadline` to extend it.
    case active(deadline: Date)
    /// Yesterday was missed but completing before `deadline` keeps the streak.
    case repairable(deadline: Date)
    case broken
}

public enum StreakEvent: Equatable, Sendable {
    case started
    case extended
    case repaired
    case restarted(previous: Int)
    case alreadyCompletedToday
}

public struct StreakUpdate: Equatable, Sendable {
    public let state: StreakState
    public let event: StreakEvent
    public let milestone: Int?
}

public struct StreakEngine: Sendable {
    public var calendar: Calendar
    public var policy: StreakPolicy

    public init(calendar: Calendar = .current, policy: StreakPolicy = StreakPolicy()) {
        self.calendar = calendar
        self.policy = policy
    }

    public func status(of state: StreakState, now: Date) -> StreakStatus {
        guard let last = state.lastCompletedDay, state.current > 0 else { return .notStarted }
        let today = DayKey(now, calendar: calendar)
        switch last.days(until: today, calendar: calendar) {
        case ...0:
            return .completedToday
        case 1:
            return .active(deadline: today.endDate(in: calendar))
        case 2:
            let deadline = repairDeadline(missedDay: last.adding(days: 1, calendar: calendar))
            return canRepair(state, today: today) && now < deadline ? .repairable(deadline: deadline) : .broken
        default:
            return .broken
        }
    }

    /// The streak number to show right now (0 once it's irrecoverably broken).
    public func displayedStreak(_ state: StreakState, now: Date) -> Int {
        status(of: state, now: now) == .broken ? 0 : state.current
    }

    public func recordCompletion(_ state: StreakState, at now: Date) -> StreakUpdate {
        let today = DayKey(now, calendar: calendar)
        var next = state
        let event: StreakEvent

        switch status(of: state, now: now) {
        case .notStarted:
            next.current = 1
            event = .started
        case .completedToday:
            return StreakUpdate(state: state, event: .alreadyCompletedToday, milestone: nil)
        case .active:
            next.current += 1
            event = .extended
        case .repairable:
            next.current += 1
            next.lastRepairDay = today
            event = .repaired
        case .broken:
            next.current = 1
            event = .restarted(previous: state.current)
        }

        next.lastCompletedDay = today
        next.longest = max(next.longest, next.current)
        next.recentDays = Array((next.recentDays + [today]).suffix(policy.historyLimit))

        let milestone = policy.milestones.contains(next.current) ? next.current : nil
        return StreakUpdate(state: next, event: event, milestone: milestone)
    }

    private func repairDeadline(missedDay: DayKey) -> Date {
        let end = missedDay.endDate(in: calendar)
        return calendar.date(byAdding: .hour, value: policy.graceHours, to: end) ?? end
    }

    private func canRepair(_ state: StreakState, today: DayKey) -> Bool {
        guard let lastRepair = state.lastRepairDay else { return true }
        return lastRepair.days(until: today, calendar: calendar) >= policy.repairCooldownDays
    }
}
