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
    private var activity: Activity<RestTimerActivityAttributes>?
    /// The last content pushed, so pause / resume / +30 s keep the labels.
    private var lastContent: RestTimerActivityAttributes.ContentState?

    var isEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    var isRunning: Bool {
        activity?.activityState == .active
    }

    /// Updates the current activity when it belongs to the same session and exercise, otherwise ends it and
    /// requests a new one (attributes are immutable once an activity exists).
    func startOrUpdate(sessionID: UUID, exerciseName: String, state: RestTimerActivityAttributes.ContentState) async {
        guard isEnabled else { return }
        let content = ActivityContent(state: state, staleDate: state.endDate.addingTimeInterval(120))
        lastContent = state

        if let current = activity,
           current.activityState == .active,
           current.attributes.sessionID == sessionID,
           current.attributes.exerciseName == exerciseName {
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
            lastError = nil
        } catch {
            lastError = "无法启动实时活动：\(error.localizedDescription)"
        }
    }

    /// The timer as the activity currently shows it (nil without a running activity).
    var currentTimer: RestTimerState? {
        guard activity != nil, let content = lastContent else { return nil }
        return RestTimerState(endDate: content.endDate, totalSeconds: content.remaining(), pausedRemaining: content.isPaused ? content.pausedRemaining : nil)
    }

    /// Shows `timer` (the watch's authoritative state) in the activity, or ends it when the rest is over (`nil`).
    func apply(_ timer: RestTimerState?, now: Date = Date()) async {
        guard let timer else {
            await end()
            return
        }
        guard let current = activity, var content = lastContent else { return }
        content.endDate = timer.endDate
        content.isPaused = timer.isPaused
        content.pausedRemaining = timer.pausedRemaining
        lastContent = content
        nonisolated(unsafe) let unsafeActivity = current
        await unsafeActivity.update(ActivityContent(state: content, staleDate: content.endDate.addingTimeInterval(120)))
    }

    func end() async {
        lastContent = nil
        guard let current = activity else { return }
        self.activity = nil
        nonisolated(unsafe) let unsafeActivity = current
        await unsafeActivity.end(nil, dismissalPolicy: .immediate)
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
    func startOrUpdate(sessionID: UUID, exerciseName: String, state: RestTimerActivityAttributes.ContentState) async {}
    func end() async {}
    func endStaleActivities() async {}
}
#endif
