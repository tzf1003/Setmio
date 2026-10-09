#if canImport(HealthKit)
import Foundation
import HealthKit
import SetmioCore

/// Writes Setmio sessions and effort ratings into HealthKit.
///
/// - Watch sessions already have an `HKWorkout` from the live builder; only `writeEffort` is needed.
/// - Phone-only sessions (no watch) are saved with `HKWorkoutBuilder` so Fitness / Training Load see them.
public struct WorkoutWriter: Sendable {
    nonisolated(unsafe) let store: HKHealthStore

    public init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    public enum WriteError: Error, Sendable, Equatable {
        case invalidEffort(Int)
        case builderReturnedNoWorkout
        case sessionNotEnded
    }

    /// Saves a user-rated effort score (1–10) and relates it to the workout (iOS 18+ Training Load).
    public func writeEffort(_ score: Int, for workout: HKWorkout) async throws {
        guard (1...10).contains(score) else { throw WriteError.invalidEffort(score) }
        let quantity = HKQuantity(unit: .appleEffortScore(), doubleValue: Double(score))
        let sample = HKQuantitySample(
            type: HKQuantityType(.workoutEffortScore),
            quantity: quantity,
            start: workout.startDate,
            end: workout.endDate
        )
        // The SDK header does not say whether `relateWorkoutEffortSample` saves a new sample, so save it first:
        // saving is required if it does not, and harmless if it does (same UUID). Needs share authorization for
        // `workoutEffortScore` (in `HealthTypes.mvpShare`). Confirmed on device in M4 step "effort 7 shows in Fitness".
        try await store.save(sample)
        try await store.relateWorkoutEffortSample(sample, with: workout, activity: nil)
    }

    /// Saves a session logged on the phone alone as an indoor traditional-strength workout.
    public func writePhoneOnlyWorkout(session: LoggedSession) async throws -> HKWorkout {
        guard let end = session.end else { throw WriteError.sessionNotEnded }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor

        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        try await builder.beginCollection(at: session.start)
        try await builder.addMetadata(Self.metadata(for: session))
        try await builder.endCollection(at: end)
        // Typed as optional on purpose: compiles whether the async overlay returns HKWorkout or HKWorkout?.
        let finished: HKWorkout? = try await builder.finishWorkout()
        guard let workout = finished else { throw WriteError.builderReturnedNoWorkout }
        if let effort = session.effortScore {
            try await writeEffort(effort, for: workout)
        }
        return workout
    }

    /// Metadata written on every Setmio workout; `com.setmio.sessionID` is what `ImportedWorkout.setmioSessionID`
    /// is read from on import.
    public static func metadata(for session: LoggedSession) -> [String: Any] {
        let working = session.sets.filter { !$0.isWarmup }
        return [
            HKMetadataKeyIndoorWorkout: true,
            SetmioWorkoutMetadata.sessionID: session.id.rawValue.uuidString,
            SetmioWorkoutMetadata.setCount: working.count,
            SetmioWorkoutMetadata.volumeKg: session.totalVolume,
        ]
    }
}
#endif
