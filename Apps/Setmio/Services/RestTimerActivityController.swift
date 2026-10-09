import Foundation
import Observation
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

        if let activity,
           activity.activityState == .active,
           activity.attributes.sessionID == sessionID,
           activity.attributes.exerciseName == exerciseName {
            await activity.update(content)
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

    func end() async {
        guard let activity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
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
