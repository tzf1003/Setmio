#if canImport(SwiftData)
import Foundation
import SwiftData

// Persistence conventions (see docs/方案.md §7.4):
// - `ID<Tag>` → `UUID`; `DayKey` → `Int` (`DayKey.sortKey`, yyyymmdd); String-backed enums → their rawValue;
//   enums with payloads and small trees → JSON `Data` wrapped by `JSONBlob` (carries `schemaVersion`).
// - Parent → child uses `@Relationship(deleteRule: .cascade)`; the child side holds the inverse.
// - Every stored property has a default so a designated `init(id:)` is enough; `apply(_:)` fills the rest.
// - Mapping to/from Core value types lives in Mapping/DomainMapping.swift.

extension SetmioSchemaV1 {
    // MARK: - ExerciseEntity ↔ Exercise

    @Model
    public final class ExerciseEntity {
        #Index<ExerciseEntity>([\.nameZH])

        @Attribute(.unique) public var id: UUID
        public var nameZH: String = ""
        public var nameEN: String? = nil
        /// `MuscleGroup.rawValue` list.
        public var primaryRaw: [String] = []
        public var secondaryRaw: [String] = []
        /// `ExerciseCategory.rawValue`.
        public var categoryRaw: String = "compound"
        /// `Equipment.rawValue`.
        public var equipmentRaw: String = "barbell"
        public var loadIncrement: Double = 2.5
        public var isUnilateral: Bool = false
        /// `RepTemplate` as JSON (V2 sensor template).
        public var repTemplateJSON: Data? = nil
        public var isCustom: Bool = false

        public init(id: UUID) {
            self.id = id
        }
    }

    // MARK: - ProgramTemplateEntity ↔ ProgramTemplate

    @Model
    public final class ProgramTemplateEntity {
        @Attribute(.unique) public var id: UUID
        public var nameZH: String = ""
        public var daysPerWeek: Int = 3
        public var mesocycleWeeks: Int = 5
        /// `[ProgramDay]` as JSON. Never queried, so the small tree is stored whole (saves four entities).
        public var daysJSON: Data = Data()

        public init(id: UUID) {
            self.id = id
        }
    }

    // MARK: - MesocycleEntity ↔ Mesocycle

    @Model
    public final class MesocycleEntity {
        #Index<MesocycleEntity>([\.isActive])

        @Attribute(.unique) public var id: UUID
        public var templateID: UUID = UUID()
        /// `DayKey.sortKey`.
        public var startDay: Int = 0
        /// `[MesocycleWeek]` as JSON.
        public var weeksJSON: Data = Data()
        public var currentWeekIndex: Int = 0
        public var isActive: Bool = true

        public init(id: UUID) {
            self.id = id
        }
    }

    // MARK: - PlannedSessionEntity ↔ PlannedSession

    @Model
    public final class PlannedSessionEntity {
        #Unique<PlannedSessionEntity>([\.mesocycleID, \.day])
        // nil mesocycleIDs are distinct to SQLite, so "one free plan per day" is enforced by `SetmioStore.upsertPlannedSession`
        // (ModelContainerTests.plannedSessionUniquenessWithNilMesocycle); the constraint still guards mesocycle plans.
        #Index<PlannedSessionEntity>([\.day])

        @Attribute(.unique) public var id: UUID
        public var mesocycleID: UUID? = nil
        /// `DayKey.sortKey`.
        public var day: Int = 0
        public var dayNameZH: String = ""
        /// `[PlannedExercise]` as JSON (includes `ProgressionDecision`).
        public var exercisesJSON: Data = Data()
        /// `ReadinessAdjustment?` as JSON — today-only modulation, never fed back into progression.
        public var readinessAdjustmentJSON: Data? = nil

        public init(id: UUID) {
            self.id = id
        }
    }

    // MARK: - LoggedSessionEntity ↔ LoggedSession

    @Model
    public final class LoggedSessionEntity {
        #Index<LoggedSessionEntity>([\.start])

        @Attribute(.unique) public var id: UUID
        public var plannedSessionID: UUID? = nil
        public var start: Date = Date(timeIntervalSince1970: 0)
        public var end: Date? = nil
        // SessionFeedback scalars (all three nil ⇒ no feedback).
        public var feedbackSoreness: Int? = nil
        public var feedbackPump: Int? = nil
        public var feedbackJoint: Int? = nil
        public var feedbackNote: String? = nil
        /// Unique when present; many sessions may have none. Multiple nil rows are allowed (ModelContainerTests.nilUniqueValuesDoNotCollide).
        @Attribute(.unique) public var hkWorkoutUUID: UUID? = nil
        /// Apple workout effort score 1–10.
        public var effortScore: Int? = nil
        /// `SessionOrigin.rawValue`.
        public var originRaw: String = "phone"
        /// Bumped on every phone-side edit; older revisions never overwrite newer ones.
        public var revision: Int = 0

        @Relationship(deleteRule: .cascade, inverse: \LoggedSetEntity.session)
        public var sets: [LoggedSetEntity] = []

        public init(id: UUID) {
            self.id = id
        }
    }

    // MARK: - LoggedSetEntity ↔ LoggedSet

    @Model
    public final class LoggedSetEntity {
        /// Serves "most recent N sets of exercise X" (`SetmioStore.recentSets`).
        #Index<LoggedSetEntity>([\.exerciseID, \.completedAt])

        @Attribute(.unique) public var id: UUID
        /// Denormalised copy of `session.id` so sets can be queried without touching the relationship.
        public var sessionID: UUID = UUID()
        public var exerciseID: UUID = UUID()
        /// Position inside the session (`LoggedSet.index`; named differently to avoid clashing with `#Index`).
        public var setIndex: Int = 0
        public var load: Double = 0
        public var reps: Int = 0
        public var rir: Int = 0
        /// `Tempo?` as JSON.
        public var tempoJSON: Data? = nil
        public var startedAt: Date? = nil
        public var completedAt: Date = Date(timeIntervalSince1970: 0)
        public var isWarmup: Bool = false
        public var estimatedReps: Int? = nil

        public var session: LoggedSessionEntity? = nil

        public init(id: UUID) {
            self.id = id
        }
    }
}
#endif
