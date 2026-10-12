import Foundation

/// Decides whether the on-screen health data is old enough to refresh when the app comes to the foreground.
///
/// HealthKit cannot wake the app while the phone is locked (its data is unreadable then), so the app catches up when
/// it is opened: if the last sync is older than `maxAge` it refreshes in the background and the screen shows
/// 「刷新中」 until it finishes.
struct SyncFreshness: Sendable, Equatable {
    /// Older than this, the data counts as stale. One minute: a refresh only pulls new samples through the anchors and
    /// recomputes the last two days, so it is cheap, and the user expects data added in Health a few minutes ago to
    /// show up when they come back (10 minutes was too long: a 3-minute-old sync did not refresh on device). The limit
    /// only stops flicking between apps from starting a sync each time.
    var maxAge: TimeInterval = 60

    func isStale(lastSyncedAt: Date?, now: Date) -> Bool {
        guard let lastSyncedAt else { return true }
        // A clock set backwards makes the last sync look like it is in the future: treat that as stale too.
        return lastSyncedAt > now || now.timeIntervalSince(lastSyncedAt) > maxAge
    }
}
