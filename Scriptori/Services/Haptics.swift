import UIKit

@MainActor
enum Haptics {
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let notification = UINotificationFeedbackGenerator()

    /// Light tick as a verse card snaps into place.
    static func cardSnap() {
        soft.impactOccurred(intensity: 0.6)
    }

    static func selection() {
        rigid.impactOccurred(intensity: 0.4)
    }

    static func chapterComplete() {
        notification.notificationOccurred(.success)
    }

    /// Escalating triple-tap for streak milestones.
    static func milestone() {
        notification.notificationOccurred(.success)
        Task { @MainActor in
            for intensity in [0.5, 0.75, 1.0] {
                try? await Task.sleep(for: .milliseconds(180))
                rigid.impactOccurred(intensity: intensity)
            }
        }
    }
}
