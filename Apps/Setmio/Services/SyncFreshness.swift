import Foundation

/// Decides whether the on-screen health data is old enough to refresh when the app comes to the foreground.
///
/// HealthKit cannot wake the app while the phone is locked (its data is unreadable then), so the app catches up when
/// it is opened: if the last sync is older than `maxAge` it refreshes in the background and the screen shows
/// 「刷新中」 until it finishes.
struct SyncFreshness: Sendable, Equatable {
    /// Older than this, the data counts as stale. Ten minutes: a night's HRV and sleep do not change faster than that,
    /// and opening the app repeatedly in a short time should not re-run a 60-day aggregation each time.
    var maxAge: TimeInterval = 10 * 60

    func isStale(lastSyncedAt: Date?, now: Date) -> Bool {
        guard let lastSyncedAt else { return true }
        // A clock set backwards makes the last sync look like it is in the future: treat that as stale too.
        return lastSyncedAt > now || now.timeIntervalSince(lastSyncedAt) > maxAge
    }
}
