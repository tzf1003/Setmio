#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import Foundation

/// Rest-timer Live Activity (Lock Screen + Dynamic Island). Declared once here so the iOS app (which starts and
/// updates the activity) and the widget extension (which renders it) compile the identical type.
///
/// The watch owns the timer state (方案.md §7.7); the phone mirrors it into `ContentState` at most once per set.
/// While running, the widget shows `Text(timerInterval: state.timerRange, countsDown: true)` and needs no updates.
public struct RestTimerActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        /// When the current rest period ends (wall clock). Meaningful only while `isPaused == false`.
        public var endDate: Date
        public var isPaused: Bool
        /// Seconds left at the moment the timer was paused; nil while running.
        public var pausedRemaining: TimeInterval?
        /// e.g. "第 3 组 · 60 kg × 12"
        public var setLabel: String
        /// e.g. "下一组 62.5 kg × 8–12 RIR 2"
        public var nextTarget: String?

        public init(endDate: Date, isPaused: Bool = false, pausedRemaining: TimeInterval? = nil, setLabel: String, nextTarget: String? = nil) {
            self.endDate = endDate
            self.isPaused = isPaused
            self.pausedRemaining = pausedRemaining
            self.setLabel = setLabel
            self.nextTarget = nextTarget
        }

        /// Seconds left at `now`, honouring a pause.
        public func remaining(at now: Date = Date()) -> TimeInterval {
            if isPaused { return max(0, pausedRemaining ?? 0) }
            return max(0, endDate.timeIntervalSince(now))
        }

        /// Range for `Text(timerInterval:countsDown:)`; when paused the range is frozen at the paused remainder.
        public func timerRange(now: Date = Date()) -> ClosedRange<Date> {
            let end = isPaused ? now.addingTimeInterval(remaining(at: now)) : endDate
            return min(now, end)...end
        }
    }

    /// `LoggedSession.id.rawValue` of the session this rest belongs to.
    public var sessionID: UUID
    public var exerciseName: String

    public init(sessionID: UUID, exerciseName: String) {
        self.sessionID = sessionID
        self.exerciseName = exerciseName
    }
}
#endif
