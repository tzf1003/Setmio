#if canImport(SwiftData)
import Foundation
import SwiftData

// Nutrition, medication and profile entities.

extension SetmioSchemaV1 {
    // MARK: - FoodEntryEntity ↔ FoodEntry

    @Model
    public final class FoodEntryEntity {
        #Index<FoodEntryEntity>([\.day])

        @Attribute(.unique) public var id: UUID
        /// `DayKey.sortKey`.
        public var day: Int = 0
        public var time: Date = Date(timeIntervalSince1970: 0)
        /// `MealType.rawValue`.
        public var mealRaw: String = "snack"
        public var photoLocalPath: String? = nil
        public var confirmed: Bool = true

        @Relationship(deleteRule: .cascade, inverse: \FoodItemEntity.entry)
        public var items: [FoodItemEntity] = []

        public init(id: UUID) {
            self.id = id
        }
    }

    // MARK: - FoodItemEntity ↔ FoodItem

    @Model
    public final class FoodItemEntity {
        @Attribute(.unique) public var id: UUID
        public var nameZH: String = ""
        public var nameEN: String? = nil
        public var portionGrams: Double = 0
        public var portionLabel: String? = nil
        // NutritionFacts scalars.
        public var kcal: Double = 0
        public var protein: Double = 0
        public var carbs: Double = 0
        public var fat: Double = 0
        public var fiber: Double = 0
        public var kcalLow: Double? = nil
        public var kcalHigh: Double? = nil
        public var confidence: Double? = nil
        /// `FoodItemSource.rawValue`.
        public var sourceRaw: String = "manual"
        public var originalKcalEstimate: Double? = nil
        /// Position inside the entry (relationships are unordered).
        public var sortOrder: Int = 0

        public var entry: FoodEntryEntity? = nil

        public init(id: UUID) {
            self.id = id
        }
    }

    // MARK: - EnergyEstimateEntity ↔ EnergyEstimate

    @Model
    public final class EnergyEstimateEntity {
        /// `DayKey.sortKey`.
        @Attribute(.unique) public var day: Int
        public var tdee: Double = 0
        public var variance: Double = 0
        public var trendWeight: Double = 0
        public var trendSlopePerWeek: Double = 0
        public var loggingCompleteness: Double = 0
        public var windowDays: Int = 14

        public init(day: Int) {
            self.day = day
        }
    }

    // MARK: - MedicationEntity ↔ Medication

    @Model
    public final class MedicationEntity {
        @Attribute(.unique) public var id: UUID
        /// `DrugID.rawValue`.
        public var drugRaw: String = ""
        /// `DosageForm` as JSON (has a payload case).
        public var formJSON: Data = Data()
        /// `DayKey.sortKey`.
        public var startedOn: Int = 0
        public var isActive: Bool = true
        public var isUnverifiedSource: Bool = false
        public var hkMedicationConceptID: String? = nil

        public init(id: UUID) {
            self.id = id
        }
    }

    // MARK: - DoseLogEntity ↔ DoseLog

    @Model
    public final class DoseLogEntity {
        #Index<DoseLogEntity>([\.medicationID, \.takenAt])

        @Attribute(.unique) public var id: UUID
        public var medicationID: UUID = UUID()
        public var takenAt: Date = Date(timeIntervalSince1970: 0)
        public var doseMg: Double = 0
        /// `InjectionSite.rawValue`.
        public var siteRaw: String? = nil
        public var penID: UUID? = nil
        public var wasMissedMakeup: Bool = false
        /// Unique when present (iOS 26 HealthKit dose event). // VERIFY: nullable unique attribute allows multiple nil rows
        @Attribute(.unique) public var hkDoseEventUUID: UUID? = nil
        public var note: String? = nil

        public init(id: UUID) {
            self.id = id
        }
    }

    // MARK: - PenInventoryEntity ↔ PenInventory

    @Model
    public final class PenInventoryEntity {
        @Attribute(.unique) public var id: UUID
        public var medicationID: UUID = UUID()
        public var strengthMg: Double = 0
        public var dosesRemaining: Int? = nil
        public var firstUsedAt: Date? = nil
        public var inUseExpiry: Date? = nil
        public var lotExpiry: Date? = nil
        public var coldChainBreach: Bool = false

        public init(id: UUID) {
            self.id = id
        }
    }

    // MARK: - SideEffectLogEntity ↔ SideEffectLog

    @Model
    public final class SideEffectLogEntity {
        #Index<SideEffectLogEntity>([\.medicationID, \.day])

        @Attribute(.unique) public var id: UUID
        public var medicationID: UUID = UUID()
        /// `DayKey.sortKey`.
        public var day: Int = 0
        /// `SideEffectLog.Kind.rawValue`.
        public var kindRaw: String = "other"
        /// 0 none … 3 severe.
        public var severity: Int = 0
        public var note: String? = nil

        public init(id: UUID) {
            self.id = id
        }
    }

    // MARK: - GLP1PlanEntity ↔ GLP1Plan

    @Model
    public final class GLP1PlanEntity {
        @Attribute(.unique) public var id: UUID
        public var medicationID: UUID = UUID()
        /// `DrugID.rawValue`.
        public var drugRaw: String = ""
        public var labelVersion: Int = 1
        /// `[GLP1PlanStep]` as JSON.
        public var stepsJSON: Data = Data()
        public var currentStepIndex: Int = 0
        public var injectionWeekday: Int = 1
        public var reminderHour: Int = 9
        public var clinicianConfirmedOffLabel: Bool = false

        public init(id: UUID) {
            self.id = id
        }
    }

    // MARK: - UserProfileEntity ↔ UserProfile (singleton row, key "profile")

    @Model
    public final class UserProfileEntity {
        @Attribute(.unique) public var key: String
        /// `UserProfile` as JSON (includes `ProteinStandard`, which has payload cases).
        public var payloadJSON: Data = Data()

        public init(key: String) {
            self.key = key
        }
    }

    // MARK: - SettingsEntity ↔ Settings (singleton row, key "settings")

    @Model
    public final class SettingsEntity {
        @Attribute(.unique) public var key: String
        /// `Settings` as JSON.
        public var payloadJSON: Data = Data()

        public init(key: String) {
            self.key = key
        }
    }
}

// Singleton keys live in extensions so the @Model macro never sees a static member.
extension SetmioSchemaV1.UserProfileEntity {
    public static let singletonKey = "profile"
}

extension SetmioSchemaV1.SettingsEntity {
    public static let singletonKey = "settings"
}
#endif
