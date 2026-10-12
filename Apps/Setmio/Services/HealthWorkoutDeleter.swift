#if canImport(HealthKit)
import Foundation
import HealthKit

/// Deletes workouts from 「健康」 with `HKHealthStore.delete`. HealthKit only lets an app delete samples it wrote, so
/// a workout it refuses (for example one saved by the watch app) stays in Health and is counted as failed.
///
/// Counts come from re-reading the workouts afterwards, not from the delete call's own result: a workout is
/// `deleted` only when it is confirmed gone.
struct HealthKitWorkoutDeleter: HealthWorkoutDeleting {
    /// HKHealthStore is documented as thread-safe (the same reasoning as `WorkoutWriter`).
    nonisolated(unsafe) let store: HKHealthStore

    func deleteWorkouts(uuids: [UUID]) async -> (deleted: Int, failed: Int) {
        let wanted = Set(uuids)
        guard !wanted.isEmpty else { return (0, 0) }
        guard HKHealthStore.isHealthDataAvailable() else { return (0, wanted.count) }

        // Nothing readable means nothing can be confirmed: report failure, never success.
        guard let found = try? await workouts(with: wanted), !found.isEmpty else {
            return (0, wanted.count)
        }
        let foundIDs = Set(found.map(\.uuid))

        // The delete may succeed for some objects and fail for others; the re-read below counts what is left.
        _ = try? await store.delete(found)

        guard let remaining = try? await workouts(with: foundIDs) else {
            return (0, wanted.count)
        }
        let deleted = foundIDs.subtracting(Set(remaining.map(\.uuid))).count
        return (deleted, wanted.count - deleted)
    }

    private func workouts(with ids: Set<UUID>) async throws -> [HKWorkout] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForObjects(with: ids))],
            sortDescriptors: []
        )
        return try await descriptor.result(for: store)
    }
}
#endif
