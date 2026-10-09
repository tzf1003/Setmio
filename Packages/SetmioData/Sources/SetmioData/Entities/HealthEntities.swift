#if canImport(SwiftData)
import Foundation
import SwiftData

// HealthKit-derived entities. Every row that mirrors an HK object keeps its `hkUUID` unique so a re-import after
// losing the anchors (reinstall) is idempotent. All of this stays on device: `ModelContainerFactory` pins
// `cloudKitDatabase: .none`.

extension SetmioSchemaV1 {
    // MARK: - DailyMetricsEntity ↔ DailyMetrics

    @Model
    public final class DailyMetricsEntity {
        /// `DayKey.sortKey` — one row per local calendar day.
        @Attribute(.unique) public var day: Int
        public var hrvSDNN: Double? = nil
        public var hrvRMSSD: Double? = nil
        public var restingHR: Double? = nil
        public var restingHRFrozenAt: Date? = nil
        public var overnightRespiratoryRate: Double? = nil
        public var wristTemperature: Double? = nil
        public var wristTemperatureDeviation: Double? = nil
        public var steps: Int? = nil
        public var activeEnergy: Double? = nil
        public var basalEnergy: Double? = nil
        public var workoutEffort: Int? = nil
        public var trainingLoad: Double? = nil
        /// `SleepWindow?` as JSON.
        public var sleepJSON: Data? = nil
        /// `SubjectiveCheckIn?` as JSON.
        public var subjectiveJSON: Data? = nil

        public init(day: Int) {
            self.day = day
        }
    }

    // MARK: - ReadinessScoreEntity ↔ ReadinessScore

    @Model
    public final class ReadinessScoreEntity {
        /// `DayKey.sortKey`.
        @Attribute(.unique) public var day: Int
        public var score: Int = 0
        /// `ReadinessBand.rawValue`.
        public var bandRaw: String = "yellow"
        public var confidence: Double = 0
        /// `[ReadinessComponent]` as JSON.
        public var componentsJSON: Data = Data()
        /// `[ReadinessFlag]` as JSON.
        public var flagsJSON: Data = Data()
        public var baselineDays: Int = 0
        public var computedAt: Date = Date(timeIntervalSince1970: 0)

        public init(day: Int) {
            self.day = day
        }
    }

    // MARK: - BodyMeasurementEntity ↔ BodyMeasurement

    @Model
    public final class BodyMeasurementEntity {
        #Index<BodyMeasurementEntity>([\.date])

        @Attribute(.unique) public var id: UUID
        /// Unique when present (HealthKit sample UUID); manual entries have none. // VERIFY: nullable unique attribute allows multiple nil rows
        @Attribute(.unique) public var hkUUID: UUID? = nil
        public var date: Date = Date(timeIntervalSince1970: 0)
        public var weight: Double? = nil
        /// Fraction 0–1.
        public var bodyFat: Double? = nil
        public var leanMass: Double? = nil
        /// Source bundle id, "manual" or "demo".
        public var source: String = ""

        public init(id: UUID) {
            self.id = id
        }
    }

    // MARK: - ImportedWorkoutEntity ↔ ImportedWorkout

    /// Reconciliation table between `HKWorkout`s (any source) and local `LoggedSessionEntity` rows.
    @Model
    public final class ImportedWorkoutEntity {
        #Index<ImportedWorkoutEntity>([\.start])

        @Attribute(.unique) public var hkUUID: UUID
        public var start: Date = Date(timeIntervalSince1970: 0)
        public var end: Date = Date(timeIntervalSince1970: 0)
        /// `HKWorkoutActivityType.rawValue`.
        public var activityTypeRawValue: Int = 0
        public var totalEnergy: Double? = nil
        public var effortScore: Int? = nil
        public var sourceBundleID: String? = nil
        /// `LoggedSessionEntity.id` this workout was matched to (or the placeholder created for it).
        public var linkedSessionID: UUID? = nil
        public var importedAt: Date = Date(timeIntervalSince1970: 0)

        public init(hkUUID: UUID) {
            self.hkUUID = hkUUID
        }
    }
}
#endif
