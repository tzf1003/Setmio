import Foundation
import SetmioCore
import SetmioData

/// The 「健康」 part of a test-data deletion. Best effort: it reports counts only, and never claims a workout is gone
/// unless it confirmed that afterwards.
protocol HealthWorkoutDeleting: Sendable {
    /// Returns how many of `uuids` are confirmed gone (`deleted`) and how many are still there or unconfirmed (`failed`).
    func deleteWorkouts(uuids: [UUID]) async -> (deleted: Int, failed: Int)
}

/// Used where HealthKit is unavailable: nothing can be deleted there, so every workout counts as failed.
struct UnavailableWorkoutDeleter: HealthWorkoutDeleting {
    func deleteWorkouts(uuids: [UUID]) async -> (deleted: Int, failed: Int) {
        (0, Set(uuids).count)
    }
}

/// What deleting the tagged sessions would remove. Only tagged sessions are counted.
struct TestDataPreview: Equatable, Sendable {
    var sessionCount: Int
    var setCount: Int
    /// 「健康」 workouts the deletion would try to remove (Setmio-written workouts only).
    var healthWorkoutCount: Int
    var oldest: Date?
    var newest: Date?
}

struct TestDataDeletionReport: Equatable, Sendable {
    var sessionsDeleted: Int
    var setsDeleted: Int
    var healthDeleted: Int
    var healthFailed: Int
}

/// The whole history, for the one-time 「把现有所有训练标记为测试」 confirmation.
struct HistorySummary: Equatable, Sendable {
    var sessionCount: Int
    var oldest: Date?
    var newest: Date?
}

enum TestDataError: LocalizedError, Equatable {
    case workoutInProgress

    var errorDescription: String? {
        switch self {
        case .workoutInProgress:
            "有进行中的训练。请先结束训练（手表训练请先在手表上结束），再删除测试数据。"
        }
    }
}

/// Deletes test training data: only sessions in the `TestDataRegistry` are touched, locally and in Health.
///
/// Order of a deletion: refuse while a workout is active → delete the tagged sessions (cascades to their sets) →
/// delete their Setmio-written workouts from 「健康」 → forget the tags of the deleted sessions.
struct TestDataCleaner: Sendable {
    let store: SetmioStore
    let registry: TestDataRegistry
    let health: any HealthWorkoutDeleting

    /// Same window the Training tab restores an open session from, so "active" here means "visible as in progress".
    private static let activeLookupLimit = 30

    /// A workout is active when the watch is mirroring, or the phone has an unfinished session. A phone session is
    /// saved as soon as it starts, so it is found here even after a relaunch.
    func hasActiveWorkout(watchMirroring: Bool) async throws -> Bool {
        if watchMirroring { return true }
        let recent = try await store.loggedSessions(limit: Self.activeLookupLimit)
        return recent.contains { $0.origin == .phone && $0.end == nil }
    }

    func preview() async throws -> TestDataPreview {
        let tagged = try await taggedSessions()
        return TestDataPreview(
            sessionCount: tagged.count,
            setCount: tagged.reduce(0) { $0 + $1.sets.count },
            healthWorkoutCount: Self.healthWorkoutIDs(in: tagged).count,
            oldest: tagged.map(\.start).min(),
            newest: tagged.map(\.start).max()
        )
    }

    func deleteAll(watchMirroring: Bool) async throws -> TestDataDeletionReport {
        guard try await !hasActiveWorkout(watchMirroring: watchMirroring) else {
            throw TestDataError.workoutInProgress
        }

        let tagged = try await taggedSessions()
        var deleted: [LoggedSession] = []
        var storeFailure: Error?
        for session in tagged {
            do {
                try await store.deleteLoggedSession(id: session.id)
                deleted.append(session)
            } catch {
                storeFailure = error
                break
            }
        }

        var health = (deleted: 0, failed: 0)
        let workoutIDs = Self.healthWorkoutIDs(in: deleted)
        if !workoutIDs.isEmpty {
            health = await self.health.deleteWorkouts(uuids: workoutIDs)
        }

        // A tag whose session is gone matches nothing, so failing to forget it does not undo the deletion.
        try? await registry.forget(deleted.map(\.id))

        if let storeFailure {
            throw storeFailure
        }
        return TestDataDeletionReport(
            sessionsDeleted: deleted.count,
            setsDeleted: deleted.reduce(0) { $0 + $1.sets.count },
            healthDeleted: health.deleted,
            healthFailed: health.failed
        )
    }

    /// Every session in the store, regardless of tags.
    func history() async throws -> HistorySummary {
        let all = try await allSessions()
        return HistorySummary(sessionCount: all.count, oldest: all.map(\.start).min(), newest: all.map(\.start).max())
    }

    /// Tags every existing session as test data. Deletes nothing. Returns how many sessions were tagged.
    func markAllExistingAsTest() async throws -> Int {
        let all = try await allSessions()
        guard !all.isEmpty else { return 0 }
        try await registry.markMany(all.map(\.id))
        return all.count
    }

    // MARK: Private

    private func allSessions() async throws -> [LoggedSession] {
        try await store.loggedSessions(in: Date.distantPast...Date.distantFuture)
    }

    private func taggedSessions() async throws -> [LoggedSession] {
        let tags = await registry.testSessionIDs()
        guard !tags.isEmpty else { return [] }
        return try await allSessions().filter { tags.contains($0.id) }
    }

    /// Workouts Setmio wrote for these sessions. A session imported from Health is another app's workout, which this
    /// app must not try to delete, so it is left out (HealthKit would refuse it anyway).
    static func healthWorkoutIDs(in sessions: [LoggedSession]) -> [UUID] {
        let ids = sessions
            .filter { $0.origin != .importedFromHealth }
            .compactMap(\.hkWorkoutUUID)
        return Array(Set(ids)).sorted { $0.uuidString < $1.uuidString }
    }
}
