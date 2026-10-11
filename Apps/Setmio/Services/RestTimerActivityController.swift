import Foundation
import Observation
import SetmioCore
import SetmioUI

#if canImport(ActivityKit)
import ActivityKit

/// Starts, updates and ends the rest-timer Live Activity (rendered by `SetmioWidgets`). The watch owns the
/// timer; the phone mirrors it here at most once per logged set, so while running the widget counts down on its
/// own with `Text(timerInterval:countsDown:)` and needs no further updates.
@MainActor
@Observable
final class RestTimerActivityController {
    private(set) var lastError: String?
    /// The activity this process requested or adopted. Nil in a freshly launched process (a Live Activity button
    /// woke the app), until `currentActivity()` adopts the live one.
    private var activity: Activity<RestTimerActivityAttributes>?
    /// The last content pushed, so pause / resume / +30 s keep the labels. Restored from the activity when adopted.
    private var lastContent: RestTimerActivityAttributes.ContentState?

    var isEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    var isRunning: Bool {
        currentActivity()?.activityState == .active
    }

    /// Updates the current activity when it belongs to the same session and exercise, otherwise ends it and
    /// requests a new one (attributes are immutable once an activity exists).
    func startOrUpdate(sessionID: UUID, exerciseName: String, state: RestTimerActivityAttributes.ContentState) async {
        guard isEnabled else { return }
        let content = ActivityContent(state: state, staleDate: state.endDate.addingTimeInterval(120))

        if let current = currentActivity(),
           current.activityState == .active,
           current.attributes.sessionID == sessionID,
           current.attributes.exerciseName == exerciseName {
            lastContent = state
            // Activity is not Sendable; it is only ever touched from this main-actor object.
            nonisolated(unsafe) let unsafeActivity = current
            await unsafeActivity.update(content)
            return
        }

        await end()
        do {
            activity = try Activity.request(
                attributes: RestTimerActivityAttributes(sessionID: sessionID, exerciseName: exerciseName),
                content: content,
                pushType: nil
            )
            // After `end()`, which clears the previous activity's state; otherwise pause / +30 s find no timer.
            lastContent = state
            lastError = nil
        } catch {
            lastError = "无法启动实时活动：\(error.localizedDescription)"
        }
    }

    /// The timer as the activity currently shows it (nil without a live activity).
    var currentTimer: RestTimerState? {
        guard currentActivity() != nil, let content = lastContent else { return nil }
        return RestTimerState(endDate: content.endDate, totalSeconds: content.remaining(), pausedRemaining: content.isPaused ? content.pausedRemaining : nil)
    }

    /// Shows `timer` (the watch's authoritative state) in the activity, or ends it when the rest is over (`nil`).
    func apply(_ timer: RestTimerState?, now: Date = Date()) async {
        guard let timer else {
            await end()
            return
        }
        guard let current = currentActivity(), var content = lastContent else { return }
        content.endDate = timer.endDate
        content.isPaused = timer.isPaused
        content.pausedRemaining = timer.pausedRemaining
        lastContent = content
        nonisolated(unsafe) let unsafeActivity = current
        await unsafeActivity.update(ActivityContent(state: content, staleDate: content.endDate.addingTimeInterval(120)))
    }

    /// Ends every live rest-timer activity, including one a previous process left behind. The app shows at most one
    /// rest timer at a time, so ending all of them is the same as ending the current one.
    func end() async {
        let live = Activity<RestTimerActivityAttributes>.activities.filter(Self.isLive)
        activity = nil
        lastContent = nil
        for current in live {
            nonisolated(unsafe) let unsafeActivity = current
            await unsafeActivity.end(nil, dismissalPolicy: .immediate)
        }
    }

    // VERIFY: on device, an intent-launched process sees the live activity in `Activity.activities` straight away.
    /// The activity this controller drives. In a process that has none (a Live Activity button launches the app in
    /// the background as a new process), adopts the app's live activity: its `content` carries the timer and the
    /// labels, so `lastContent` is restored from it. Synchronous, because `currentTimer` is a property.
    private func currentActivity() -> Activity<RestTimerActivityAttributes>? {
        if let activity, Self.isLive(activity) { return activity }
        activity = nil
        guard let adopted = Activity<RestTimerActivityAttributes>.activities.first(where: Self.isLive) else {
            lastContent = nil
            return nil
        }
        activity = adopted
        lastContent = adopted.content.state
        return adopted
    }

    /// Pending, active and stale activities can still be shown and updated; ended and dismissed ones cannot.
    private static func isLive(_ activity: Activity<RestTimerActivityAttributes>) -> Bool {
        switch activity.activityState {
        case .ended, .dismissed: false
        default: true
        }
    }

    /// Ends activities left over from a previous process (e.g. after a crash mid-workout).
    func endStaleActivities() async {
        for stale in Activity<RestTimerActivityAttributes>.activities {
            await stale.end(nil, dismissalPolicy: .immediate)
        }
    }
}

#else

@MainActor
@Observable
final class RestTimerActivityController {
    private(set) var lastError: String?
    var isEnabled: Bool { false }
    var isRunning: Bool { false }
    var currentTimer: RestTimerState? { nil }
    func startOrUpdate(sessionID: UUID, exerciseName: String, state: RestTimerActivityAttributes.ContentState) async {}
    func apply(_ timer: RestTimerState?, now: Date = Date()) async {}
    func end() async {}
    func endStaleActivities() async {}
}
#endif
