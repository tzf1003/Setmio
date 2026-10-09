import Foundation

#if canImport(WatchKit)
import WatchKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Rest-timer haptics: taps on the wrist while the app is frontmost, and a local notification as the fallback
/// when the wrist is down during the workout session.
///
/// VERIFY (kept on purpose — can only be observed on a watch): whether `WKInterfaceDevice.play` is delivered while the
/// wrist is down and the app is in the background of a running `HKWorkoutSession`. Either way the scheduled
/// notification fires, so the rest end is never silent; M4 device step "休息计时归零手表震动" settles which path is used.
@MainActor
final class HapticsController {
    enum Cue: Sendable {
        /// 10 s before the rest ends.
        case warning
        /// Rest over — next set.
        case finished
        /// A set was logged.
        case setLogged
    }

    nonisolated static let notificationCategory = "com.setmio.rest-timer"

    private(set) var notificationsAuthorized = false

    func requestNotificationAuthorization() async {
        #if canImport(UserNotifications)
        do {
            notificationsAuthorized = try await UNUserNotificationCenter.current().requestAuthorization(options: [.sound, .alert])
        } catch {
            notificationsAuthorized = false
        }
        #endif
    }

    func play(_ cue: Cue) {
        #if canImport(WatchKit)
        switch cue {
        case .warning: WKInterfaceDevice.current().play(.directionUp)
        case .finished: WKInterfaceDevice.current().play(.notification)
        case .setLogged: WKInterfaceDevice.current().play(.success)
        }
        #endif
    }

    /// Schedules the "rest over" notification for `date`; replaces any pending one.
    func scheduleRestOverNotification(at date: Date, exerciseName: String) {
        #if canImport(UserNotifications)
        cancelScheduledNotifications()
        guard notificationsAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "休息结束"
        content.body = "下一组：\(exerciseName)"
        content.sound = .default
        content.categoryIdentifier = Self.notificationCategory
        let interval = max(1, date.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: Self.notificationCategory, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { _ in }
        #endif
    }

    func cancelScheduledNotifications() {
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.notificationCategory])
        #endif
    }
}
