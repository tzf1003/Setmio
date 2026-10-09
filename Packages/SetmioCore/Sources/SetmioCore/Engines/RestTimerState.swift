import Foundation

/// Wall-clock state of one rest period, shared by the watch (source of truth) and the iPhone Live Activity (mirror)
/// so both sides apply pause / resume / +30 s identically and independently (方案.md §7.7). Pure value type:
/// every transition takes `now` explicitly.
public struct RestTimerState: Sendable, Codable, Equatable, Hashable {
    /// When the rest ends. Meaningless while paused (`pausedRemaining != nil`).
    public var endDate: Date
    /// Length of the whole rest including extensions, for progress rings.
    public var totalSeconds: TimeInterval
    /// Seconds that were left when the timer was paused; nil while running.
    public var pausedRemaining: TimeInterval?

    public init(endDate: Date, totalSeconds: TimeInterval, pausedRemaining: TimeInterval? = nil) {
        self.endDate = endDate
        self.totalSeconds = totalSeconds
        self.pausedRemaining = pausedRemaining
    }

    /// A fresh running rest of `seconds` starting at `now`.
    public init(startingAt now: Date, seconds: TimeInterval) {
        self.init(endDate: now.addingTimeInterval(max(0, seconds)), totalSeconds: max(0, seconds))
    }

    public var isPaused: Bool { pausedRemaining != nil }

    public func remaining(at now: Date = Date()) -> TimeInterval {
        if let pausedRemaining { return max(0, pausedRemaining) }
        return max(0, endDate.timeIntervalSince(now))
    }

    public func isFinished(at now: Date = Date()) -> Bool {
        !isPaused && remaining(at: now) <= 0
    }

    /// Freezes the remainder. Pausing a paused or finished timer changes nothing.
    public func paused(at now: Date) -> RestTimerState {
        guard !isPaused, !isFinished(at: now) else { return self }
        var copy = self
        copy.pausedRemaining = remaining(at: now)
        return copy
    }

    /// Continues from the frozen remainder. Resuming a running timer changes nothing.
    public func resumed(at now: Date) -> RestTimerState {
        guard let pausedRemaining else { return self }
        var copy = self
        copy.endDate = now.addingTimeInterval(max(0, pausedRemaining))
        copy.pausedRemaining = nil
        return copy
    }

    /// Adds `seconds` to the rest (running or paused). An already finished timer restarts from `now`.
    public func extended(by seconds: TimeInterval, at now: Date) -> RestTimerState {
        var copy = self
        if let pausedRemaining {
            copy.pausedRemaining = pausedRemaining + seconds
        } else {
            copy.endDate = max(endDate, now).addingTimeInterval(seconds)
        }
        copy.totalSeconds = totalSeconds + seconds
        return copy
    }
}
