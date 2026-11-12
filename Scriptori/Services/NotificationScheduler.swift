import Foundation
import ScriptoriKit
import UserNotifications

/// Local reminders: the daily "Morning Scriptori" nudge, an evening streak rescue,
/// a Streak Repair countdown when yesterday was missed, and a trial-ending heads-up.
@MainActor
final class NotificationScheduler {
    private enum ID {
        static let daily = "scriptori.daily"
        static let streakRescue = "scriptori.streak.rescue"
        static let streakRepair = "scriptori.streak.repair"
        static let trialEnding = "scriptori.trial.ending"
    }

    private var center: UNUserNotificationCenter { .current() }

    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Re-plans all streak-related reminders from the current profile state.
    func refresh(for profile: UserProfile, engine: StreakEngine, now: Date = .now) async {
        center.removePendingNotificationRequests(withIdentifiers: [ID.daily, ID.streakRescue, ID.streakRepair])
        let prefs = profile.preferences
        guard prefs.remindersEnabled else { return }

        let daily = UNMutableNotificationContent()
        daily.title = "Morning Scriptori 🌿"
        if let cue = profile.onboarding?.cue {
            daily.body = "\(cue): trade a few minutes of scrolling for today's chapter."
        } else {
            daily.body = "Trade a few minutes of scrolling for today's chapter."
        }
        daily.sound = .default
        let dailyTrigger = UNCalendarNotificationTrigger(
            dateMatching: DateComponents(hour: prefs.reminderHour, minute: prefs.reminderMinute),
            repeats: true
        )
        try? await center.add(UNNotificationRequest(identifier: ID.daily, content: daily, trigger: dailyTrigger))

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
