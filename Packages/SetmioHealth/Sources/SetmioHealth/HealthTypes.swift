#if canImport(HealthKit)
import Foundation
import HealthKit
import SetmioCore

/// Single place that maps `HealthMetricKind` to HealthKit types and units (方案.md §7.5 "类型集").
/// Adding a kind to Core means adding a row here, in `HKHealthSampleSource.convert` and in the fake.
public enum HealthTypes {
    // MARK: Per-kind mapping

    public static func quantityIdentifier(for kind: HealthMetricKind) -> HKQuantityTypeIdentifier? {
        switch kind {
        case .bodyMass: return .bodyMass
        case .bodyFatPercentage: return .bodyFatPercentage
        case .leanBodyMass: return .leanBodyMass
        case .heartRate: return .heartRate
        case .restingHeartRate: return .restingHeartRate
        case .hrvSDNN: return .heartRateVariabilitySDNN
        case .hrvRMSSD:
            // The iOS 26.x SDK has no RMSSD quantity type (verified against Xcode 26.6 in CI); RMSSD is computed
            // locally from HKHeartbeatSeriesSample beat-to-beat intervals instead. Revisit when building with iOS 27.
            return nil
        case .respiratoryRate: return .respiratoryRate
        case .wristTemperature: return .appleSleepingWristTemperature
        case .steps: return .stepCount
        case .activeEnergy: return .activeEnergyBurned
        case .basalEnergy: return .basalEnergyBurned
        case .workoutEffort: return .workoutEffortScore
        case .sleep, .workout: return nil
        }
    }

    public static func quantityType(for kind: HealthMetricKind) -> HKQuantityType? {
        quantityIdentifier(for: kind).map { HKQuantityType($0) }
    }

    /// The object type used for authorization and background delivery.
    public static func objectType(for kind: HealthMetricKind) -> HKObjectType? {
        switch kind {
        case .sleep: return HKCategoryType(.sleepAnalysis)
        case .workout: return HKObjectType.workoutType()
        default: return quantityType(for: kind)
        }
    }

    /// The sample type used for sample / anchored / observer queries.
    public static func sampleType(for kind: HealthMetricKind) -> HKSampleType? {
        switch kind {
        case .sleep: return HKCategoryType(.sleepAnalysis)
        case .workout: return HKObjectType.workoutType()
        default: return quantityType(for: kind)
        }
    }

    /// The unit every quantity of `kind` is converted to before leaving this package (see
    /// `HealthMetricKind.canonicalUnit` for the matching label).
    public static func unit(for kind: HealthMetricKind) -> HKUnit? {
        switch kind {
        case .bodyMass, .leanBodyMass: return .gramUnit(with: .kilo)
        case .bodyFatPercentage: return .percent()
        case .heartRate, .restingHeartRate, .respiratoryRate: return HKUnit.count().unitDivided(by: .minute())
        case .hrvSDNN, .hrvRMSSD: return .secondUnit(with: .milli)
        case .wristTemperature: return .degreeCelsius()
        case .steps: return .count()
        case .activeEnergy, .basalEnergy: return .kilocalorie()
        case .workoutEffort: return .appleEffortScore()
        case .sleep, .workout: return nil
        }
    }

    public static let heartbeatSeriesType: HKSeriesType = HKSeriesType.heartbeat()
    public static let estimatedWorkoutEffortType: HKQuantityType = HKQuantityType(.estimatedWorkoutEffortScore)
    public static let heartRateUnit: HKUnit = HKUnit.count().unitDivided(by: .minute())

    // MARK: Authorization sets

    /// Read types for a set of kinds, plus the companion types they imply: the heartbeat series for HRV
    /// (RMSSD is computed locally) and the estimated effort score next to the user-rated one.
    public static func readTypes(for kinds: Set<HealthMetricKind>) -> Set<HKObjectType> {
        var types = Set(kinds.compactMap(objectType(for:)))
        if kinds.contains(.hrvSDNN) || kinds.contains(.hrvRMSSD) {
            types.insert(heartbeatSeriesType)
        }
        if kinds.contains(.workoutEffort) {
            types.insert(estimatedWorkoutEffortType)
        }
        return types
    }

    public static func shareTypes(for kinds: Set<HealthMetricKind>) -> Set<HKSampleType> {
        Set(kinds.compactMap(sampleType(for:)))
    }

    public static let mvpReadKinds: Set<HealthMetricKind> = Set(HealthMetricKind.mvp)
    public static let mvpShareKinds: Set<HealthMetricKind> = [.workout, .heartRate, .activeEnergy, .workoutEffort]

    /// MVP: body composition, overnight vitals, activity, sleep, heartbeat series, workouts and effort.
    public static var mvpRead: Set<HKObjectType> { readTypes(for: mvpReadKinds) }
    public static var mvpShare: Set<HKSampleType> { shareTypes(for: mvpShareKinds) }

    /// Added on iOS 27 when the system RMSSD type exists; empty before that.
    public static var iOS27Read: Set<HKObjectType> {
        if #available(iOS 27, watchOS 27, *), let type = objectType(for: .hrvRMSSD) {
            return [type]
        }
        return []
    }

    /// V1 adds dietary intake (both directions) and medication dose events (read).
    public static var v1Read: Set<HKObjectType> {
        var types = mvpRead.union(iOS27Read).union(dietaryTypes.map { $0 as HKObjectType })
        if #available(iOS 26, *) {
            types.formUnion(medicationTypes)
        }
        return types
    }

    public static var v1Share: Set<HKSampleType> {
        mvpShare.union(dietaryTypes.map { $0 as HKSampleType })
    }

    public static let dietaryTypes: Set<HKQuantityType> = [
        HKQuantityType(.dietaryEnergyConsumed),
        HKQuantityType(.dietaryProtein),
        HKQuantityType(.dietaryCarbohydrates),
        HKQuantityType(.dietaryFatTotal),
        HKQuantityType(.dietaryFiber),
    ]

    @available(iOS 26, *)
    public static var medicationTypes: Set<HKObjectType> {
        #if os(iOS)
        return [HKObjectType.medicationDoseEventType()] // VERIFY: iOS 26 medication dose event object type accessor name (WWDC25 "Meet the HealthKit Medications API")
        #else
        return []
        #endif
    }
}

public extension BackgroundFrequency {
    var hkFrequency: HKUpdateFrequency {
        switch self {
        case .immediate: .immediate
        case .hourly: .hourly
        case .daily: .daily
        }
    }
}
#endif
