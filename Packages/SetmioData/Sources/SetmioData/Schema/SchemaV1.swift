#if canImport(SwiftData)
import Foundation
import SwiftData

/// Schema version 1 (the first shipped schema).
///
/// Every `@Model` entity is nested inside this enum (declared in `Entities/*Entities.swift` through
/// `extension SetmioSchemaV1 { … }`) and re-exported by the top-level typealiases below, so call sites never
/// spell a schema version. A later `SetmioSchemaV2` copies the entities it changes, and `SetmioMigrationPlan`
/// gains a stage. JSON blobs carry their own `schemaVersion` (see `JSONBlob`) so small shape changes inside a
/// blob never need a SwiftData migration.
public enum SetmioSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0) // VERIFY: Schema.Version is Sendable (required for a `static let` under Swift 6); otherwise make this a computed property

    public static var models: [any PersistentModel.Type] {
        [
            // Training
            ExerciseEntity.self,
            ProgramTemplateEntity.self,
            MesocycleEntity.self,
            PlannedSessionEntity.self,
            LoggedSessionEntity.self,
            LoggedSetEntity.self,
            // Health
            DailyMetricsEntity.self,
            ReadinessScoreEntity.self,
            BodyMeasurementEntity.self,
            ImportedWorkoutEntity.self,
            // Lifestyle
            FoodEntryEntity.self,
            FoodItemEntity.self,
            EnergyEstimateEntity.self,
            MedicationEntity.self,
            DoseLogEntity.self,
            PenInventoryEntity.self,
            SideEffectLogEntity.self,
            GLP1PlanEntity.self,
            UserProfileEntity.self,
            SettingsEntity.self,
        ]
    }
}

/// The schema the app currently runs on. `ModelContainerFactory` builds its `Schema` from this.
public typealias SetmioCurrentSchema = SetmioSchemaV1

// MARK: - Top-level names for the current schema's entities

public typealias ExerciseEntity = SetmioSchemaV1.ExerciseEntity
public typealias ProgramTemplateEntity = SetmioSchemaV1.ProgramTemplateEntity
public typealias MesocycleEntity = SetmioSchemaV1.MesocycleEntity
public typealias PlannedSessionEntity = SetmioSchemaV1.PlannedSessionEntity
public typealias LoggedSessionEntity = SetmioSchemaV1.LoggedSessionEntity
public typealias LoggedSetEntity = SetmioSchemaV1.LoggedSetEntity

public typealias DailyMetricsEntity = SetmioSchemaV1.DailyMetricsEntity
public typealias ReadinessScoreEntity = SetmioSchemaV1.ReadinessScoreEntity
public typealias BodyMeasurementEntity = SetmioSchemaV1.BodyMeasurementEntity
public typealias ImportedWorkoutEntity = SetmioSchemaV1.ImportedWorkoutEntity

public typealias FoodEntryEntity = SetmioSchemaV1.FoodEntryEntity
public typealias FoodItemEntity = SetmioSchemaV1.FoodItemEntity
public typealias EnergyEstimateEntity = SetmioSchemaV1.EnergyEstimateEntity
public typealias MedicationEntity = SetmioSchemaV1.MedicationEntity
public typealias DoseLogEntity = SetmioSchemaV1.DoseLogEntity
public typealias PenInventoryEntity = SetmioSchemaV1.PenInventoryEntity
public typealias SideEffectLogEntity = SetmioSchemaV1.SideEffectLogEntity
public typealias GLP1PlanEntity = SetmioSchemaV1.GLP1PlanEntity
public typealias UserProfileEntity = SetmioSchemaV1.UserProfileEntity
public typealias SettingsEntity = SetmioSchemaV1.SettingsEntity
#endif
