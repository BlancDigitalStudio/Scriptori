import Foundation

/// The app's idea of "now" for anything decided by calendar day: which chapter is today's,
/// whether it's done, streaks and streak reminders.
///
/// In Debug builds the `-day-offset N` launch argument moves it N days ahead (or back, with a
/// negative N), so day changes can be tested without touching the Mac's clock. The offset is
/// remembered: opening the app from the home screen, where there are no launch arguments,
/// stays on the same day as the last run from Xcode. `-day-offset 0` goes back to the real
/// date. Sync timestamps (`updatedAt`, `createdAt`) and subscription expiry keep using the
/// real clock.
enum AppClock {
    static var now: Date {
        #if DEBUG
        if dayOffset != 0, let shifted = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) {
            return shifted
        }
        #endif
        return Date()
    }

    #if DEBUG
    static let dayOffsetArgument = "-day-offset"

    private static let dayOffsetKey = "scriptori.debugDayOffset"

    /// Whole days added to the real date: from `-day-offset N`, or the last one given when
    /// the argument is absent.
    static let dayOffset: Int = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: dayOffsetArgument), arguments.indices.contains(index + 1) else {
            return UserDefaults.standard.integer(forKey: dayOffsetKey)
        }
        let offset = Int(arguments[index + 1]) ?? 0
        UserDefaults.standard.set(offset, forKey: dayOffsetKey)
        return offset
    }()
    #endif
}
