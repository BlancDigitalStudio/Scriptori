import Foundation

/// The app's idea of "now" for anything decided by calendar day: which chapter is today's,
/// whether it's done, streaks and streak reminders.
///
/// In Debug builds the `-day-offset N` launch argument moves it N days ahead (or back, with a
/// negative N), so day changes can be tested without touching the Mac's clock. Sync
/// timestamps (`updatedAt`, `createdAt`) and subscription expiry keep using the real clock.
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

    /// Whole days added to the real date, from `-day-offset N`. 0 when the argument is absent.
    static let dayOffset: Int = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: dayOffsetArgument), arguments.indices.contains(index + 1) else { return 0 }
        return Int(arguments[index + 1]) ?? 0
    }()
    #endif
}
