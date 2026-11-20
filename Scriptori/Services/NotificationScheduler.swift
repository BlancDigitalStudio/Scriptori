import Foundation
import ScriptoriKit
import UserNotifications

/// Local reminders: the daily "Morning Scriptori" nudge, an evening streak rescue,
/// a Streak Repair countdown when yesterday was missed, and a trial-ending heads-up.
@MainActor
final class NotificationScheduler {
    private enum ID {
        /// The old repeating reminder; removed so it can't fire alongside the per-day ones.
        static let daily = "scriptori.daily"
        /// One reminder per day, e.g. `scriptori.daily.2026-11-20`, so a finished day can be skipped.
        static let dailyPrefix = "scriptori.daily."
        static let streakRescue = "scriptori.streak.rescue"
        static let streakRepair = "scriptori.streak.repair"
        static let trialEnding = "scriptori.trial.ending"
    }

    private var center: UNUserNotificationCenter { .current() }

    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// How many days of daily reminders are queued ahead. Re-planned every time the app opens or a
    /// chapter is completed, so this only matters for someone who stops opening the app.
    private static let dailyDaysAhead = 14

    /// Re-plans all streak-related reminders from the current profile state.
    func refresh(for profile: UserProfile, engine: StreakEngine, now: Date = AppClock.now) async {
        let pendingDaily = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(ID.dailyPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pendingDaily + [ID.daily, ID.streakRescue, ID.streakRepair])
        let prefs = profile.preferences
        guard prefs.remindersEnabled else { return }

        await scheduleDailyReminders(for: profile, now: now)

        switch engine.status(of: profile.streak, now: now) {
        case .active(let deadline):
            await schedule(
                id: ID.streakRescue,
                title: "Keep your \(profile.streak.current)-day streak 🔥",
                body: "Your chapter is waiting — it only takes a few swipes.",
                at: min(deadline.addingTimeInterval(-3 * 3600), Self.today(atHour: 20, from: now))
            )
        case .repairable(let deadline):
            await schedule(
                id: ID.streakRepair,
                title: "Streak Repair is open ⏳",
                body: "Finish today's chapter to save your \(profile.streak.current)-day streak.",
                at: max(now.addingTimeInterval(60), deadline.addingTimeInterval(-4 * 3600))
            )
        case .notStarted, .completedToday, .broken:
            break
        }
    }

    /// A reminder at the chosen time on each upcoming day, except today once today's chapter
    /// has been checked in on.
    private func scheduleDailyReminders(for profile: UserProfile, now: Date) async {
        let prefs = profile.preferences
        let body = profile.onboarding?.cue.map { "\($0): trade a few minutes of scrolling for today's chapter." }
            ?? "Trade a few minutes of scrolling for today's chapter."
        let today = DayKey(now)
        let doneToday = profile.streak.lastCompletedDay == today || profile.plan.lastCompletedDay == today
        for offset in (doneToday ? 1 : 0)..<Self.dailyDaysAhead {
            let day = today.adding(days: offset)
            guard let fireDate = Calendar.current.date(bySettingHour: prefs.reminderHour, minute: prefs.reminderMinute, second: 0, of: day.startDate()) else { continue }
            await schedule(id: ID.dailyPrefix + day.description, title: "Morning Scriptori 🌿", body: body, at: fireDate)
        }
    }

    func scheduleTrialEndingReminder(expiresAt: Date?) async {
        center.removePendingNotificationRequests(withIdentifiers: [ID.trialEnding])
        guard let expiresAt else { return }
        await schedule(
            id: ID.trialEnding,
            title: "Your free trial ends tomorrow",
            body: "No surprises: manage or cancel anytime in Settings.",
            at: expiresAt.addingTimeInterval(-24 * 3600)
        )
    }

    private func schedule(id: String, title: String, body: String, at date: Date) async {
        guard date > .now else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    private static func today(atHour hour: Int, from now: Date) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
    }
}
