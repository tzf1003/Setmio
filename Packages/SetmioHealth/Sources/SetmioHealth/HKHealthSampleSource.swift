#if canImport(HealthKit)
import Foundation
import HealthKit
import SetmioCore

/// `HealthSampleSource` backed by a real `HKHealthStore`. Only this file (plus `WorkoutWriter` and the
/// session classes) touches HealthKit sample objects; everything it returns is a Core value type.
public final class HKHealthSampleSource: HealthSampleSource, Sendable {
    // HKHealthStore is documented as thread-safe. If the SDK already marks it Sendable this attribute is
    // redundant but harmless (verified by the Xcode 26.6 CI build).
    nonisolated(unsafe) let store: HKHealthStore

    public init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    // MARK: Availability and authorization

    public func isAvailable() -> Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    public func requestAuthorization(read: Set<HealthMetricKind>, share: Set<HealthMetricKind>) async throws {
        try await HealthKitAuthorizer(store: store).requestAuthorization(readKinds: read, shareKinds: share)
    }

    // MARK: Anchored import

    public func anchoredSamples(of kind: HealthMetricKind, since anchor: Data?, limit: Int) async throws -> AnchoredBatch {
        guard let sampleType = HealthTypes.sampleType(for: kind) else {
            // No system type on this OS (RMSSD before iOS 27): nothing to import, anchor untouched.
            return AnchoredBatch(samples: [], deletedUUIDs: [], newAnchor: anchor)
        }
        let hkAnchor: HKQueryAnchor?
        do {
            hkAnchor = try anchor.flatMap(Self.unarchiveAnchor)
        } catch {
            // A corrupt anchor must not wedge the import forever: start over from the beginning.
            hkAnchor = nil
        }
        let descriptor = HKAnchoredObjectQueryDescriptor(
            predicates: [.sample(type: sampleType)],
            anchor: hkAnchor,
            limit: limit
        )
        let result = try await descriptor.result(for: store)
        let samples = result.addedSamples.compactMap { Self.convert($0, kind: kind) }
        let deleted = result.deletedObjects.map(\.uuid)
        let newAnchor: HKQueryAnchor? = result.newAnchor
        return AnchoredBatch(samples: samples, deletedUUIDs: deleted, newAnchor: try Self.archiveAnchor(newAnchor) ?? anchor)
    }

    // MARK: Range queries

    public func samples(of kind: HealthMetricKind, in range: ClosedRange<Date>) async throws -> [HealthSample] {
        guard let sampleType = HealthTypes.sampleType(for: kind) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: range.lowerBound, end: range.upperBound, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.sample(type: sampleType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)],
            limit: nil
        )
        let results = try await descriptor.result(for: store)
        return results.compactMap { Self.convert($0, kind: kind) }
    }

    public func heartbeatSeries(in range: ClosedRange<Date>) async throws -> [HeartbeatSeries] {
        let predicate = HKQuery.predicateForSamples(withStart: range.lowerBound, end: range.upperBound, options: [.strictStartDate])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.sample(type: HealthTypes.heartbeatSeriesType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)],
            limit: nil
        )
        let results = try await descriptor.result(for: store)
        var series: [HeartbeatSeries] = []
        for case let sample as HKHeartbeatSeriesSample in results {
            series.append(try await enumerate(sample))
        }
        return series
    }

    /// Enumerates one series with the classic `HKHeartbeatSeriesQuery` (no descriptor form exists).
    private func enumerate(_ sample: HKHeartbeatSeriesSample) async throws -> HeartbeatSeries {
        final class Accumulator: @unchecked Sendable {   // HealthKit calls the handler serially on its own queue
            var beatTimes: [Double] = []
            var gapIndices: [Int] = []
            var finished = false
        }
        let accumulator = Accumulator()
        let uuid = sample.uuid
        let start = sample.startDate
        let end = sample.endDate
        let boxedStore = UncheckedSendable(store)
        let boxedSample = UncheckedSendable(sample)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HeartbeatSeries, any Error>) in
            let query = HKHeartbeatSeriesQuery(heartbeatSeries: boxedSample.value) { _, timeSinceSeriesStart, precededByGap, done, error in
                if accumulator.finished { return }
                if let error {
                    accumulator.finished = true
                    continuation.resume(throwing: error)
                    return
                }
                if precededByGap { accumulator.gapIndices.append(accumulator.beatTimes.count) }
                accumulator.beatTimes.append(timeSinceSeriesStart)
                if done {
                    accumulator.finished = true
                    continuation.resume(returning: HeartbeatSeries(
                        hkUUID: uuid, start: start, end: end,
                        beatTimes: accumulator.beatTimes, gapIndices: accumulator.gapIndices
                    ))
                }
            }
            boxedStore.value.execute(query)
        }
    }

    public func dailyTotal(of kind: HealthMetricKind, on day: DayKey, calendar: Calendar) async throws -> Double? {
        guard kind.isCumulative, let quantityType = HealthTypes.quantityType(for: kind), let unit = HealthTypes.unit(for: kind) else {
            return nil
        }
        let start = day.startOfDay(calendar: calendar)
        let end = day.adding(days: 1, calendar: calendar).startOfDay(calendar: calendar)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: quantityType, predicate: predicate),
            options: [.cumulativeSum]
        )
        let statistics = try await descriptor.result(for: store)
        return statistics?.sumQuantity()?.doubleValue(for: unit)
    }

    public func workouts(in range: ClosedRange<Date>) async throws -> [ImportedWorkout] {
        let predicate = HKQuery.predicateForSamples(withStart: range.lowerBound, end: range.upperBound, options: [.strictStartDate])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)],
            limit: nil
        )
        let workouts = try await descriptor.result(for: store)
        var imported: [ImportedWorkout] = []
        imported.reserveCapacity(workouts.count)
        for workout in workouts {
            let effort = try? await effortScore(for: workout)
            imported.append(Self.convert(workout, effortScore: effort))
        }
        return imported
    }

    /// The most recent user-rated effort score related to `workout`, if any.
    private func effortScore(for workout: HKWorkout) async throws -> Int? {
        let predicate = HKQuery.predicateForWorkoutEffortSamplesRelated(workout: workout, activity: nil)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.workoutEffortScore), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        let samples = try await descriptor.result(for: store)
        guard let latest = samples.first, let unit = HealthTypes.unit(for: .workoutEffort) else { return nil }
        return Int(latest.quantity.doubleValue(for: unit).rounded())
    }

    // MARK: Background delivery and observation

    public func enableBackgroundDelivery(for kind: HealthMetricKind, frequency: BackgroundFrequency) async throws {
        guard let objectType = HealthTypes.objectType(for: kind) else { return }
        try await store.enableBackgroundDelivery(for: objectType, frequency: frequency.hkFrequency)
    }

    public func disableAllBackgroundDelivery() async throws {
        try await store.disableAllBackgroundDelivery()
    }

    public func observe(
        _ kind: HealthMetricKind,
        handler: @escaping @Sendable (_ completion: @escaping @Sendable () -> Void) -> Void
    ) -> ObservationToken {
        guard let sampleType = HealthTypes.sampleType(for: kind) else { return .noop() }
        let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { _, completionHandler, error in
            // HealthKit's completion handler must be called on every callback, including errors.
            let completion = UncheckedSendable(completionHandler)
            guard error == nil else {
                completion.value()
                return
            }
            handler { completion.value() }
        }
        store.execute(query)
        let boxedQuery = UncheckedSendable(query)
        let boxedStore = UncheckedSendable(store)
        return ObservationToken { boxedStore.value.stop(boxedQuery.value) }
    }

    // MARK: Anchors

    static func archiveAnchor(_ anchor: HKQueryAnchor?) throws -> Data? {
        guard let anchor else { return nil }
        return try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }

    static func unarchiveAnchor(_ data: Data) throws -> HKQueryAnchor? {
        try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    // MARK: Conversion

    /// HKSample → Core value type. Returns nil for sample classes we do not model.
    static func convert(_ sample: HKSample, kind: HealthMetricKind) -> HealthSample? {
        let source = sample.sourceRevision.source.bundleIdentifier
        switch sample {
        case let quantity as HKQuantitySample:
            guard let unit = HealthTypes.unit(for: kind) else { return nil }
            return HealthSample(
                hkUUID: quantity.uuid,
                kind: kind,
                value: quantity.quantity.doubleValue(for: unit),
                unit: kind.canonicalUnit,
                start: quantity.startDate,
                end: quantity.endDate,
                sourceBundleID: source,
                categoryValue: nil
            )
        case let category as HKCategorySample:
            return HealthSample(
                hkUUID: category.uuid,
                kind: kind,
                value: Double(category.value),
                unit: kind.canonicalUnit,
                start: category.startDate,
                end: category.endDate,
                sourceBundleID: source,
                categoryValue: category.value
            )
        case let workout as HKWorkout:
            return HealthSample(
                hkUUID: workout.uuid,
                kind: .workout,
                value: workout.duration / 60,
                unit: HealthMetricKind.workout.canonicalUnit,
                start: workout.startDate,
                end: workout.endDate,
                sourceBundleID: source,
                categoryValue: Int(workout.workoutActivityType.rawValue)
            )
        default:
            return nil
        }
    }

    static func convert(_ workout: HKWorkout, effortScore: Int?) -> ImportedWorkout {
        let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
        let sessionID = (workout.metadata?[SetmioWorkoutMetadata.sessionID] as? String).flatMap { ID<LoggedSession>(uuidString: $0) }
        return ImportedWorkout(
            hkUUID: workout.uuid,
            start: workout.startDate,
            end: workout.endDate,
            activityTypeRawValue: Int(workout.workoutActivityType.rawValue),
            totalEnergy: energy,
            effortScore: effortScore,
            sourceBundleID: workout.sourceRevision.source.bundleIdentifier,
            setmioSessionID: sessionID
        )
    }
}
#endif
