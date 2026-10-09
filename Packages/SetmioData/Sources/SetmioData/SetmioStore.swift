import Foundation
import SetmioCore

// MARK: - Outcomes (Foundation-only; builds on Linux)

/// Result of reconciling one imported `HKWorkout` with local sessions.
public enum ReconcileOutcome: Sendable, Equatable, Hashable {
    /// Matched an existing local session (by `setmioSessionID` metadata, by `hkWorkoutUUID`, or by start time).
    case linkedToSession(ID<LoggedSession>)
    /// No local session matched; a `LoggedSession` with `origin == .importedFromHealth` was created.
    case createdPlaceholder(ID<LoggedSession>)
    /// This `hkUUID` was reconciled before; nothing changed.
    case alreadyKnown
}

#if canImport(SwiftData)
import SwiftData

/// Repository façade over the SwiftData store. Runs on its own background `ModelContext` (`@ModelActor`), so
/// `HealthSyncService`, the mirroring host and the UI can call it from anywhere.
///
/// Rules:
/// - Every parameter and return value is a Core value type (`Sendable`); `@Model` instances never leave the actor.
/// - Every write is an idempotent upsert keyed by the Core id (or `hkUUID` / day) and saves immediately, so other
///   contexts (`@Query` on the main context) see it right away.
/// - `toDomain()` throws on corrupt rows instead of inventing defaults.
@ModelActor
public actor SetmioStore { // VERIFY: @ModelActor on a public actor generates a public init(modelContainer:) and public modelExecutor/modelContainer
    /// A HealthKit workout whose start is within this many seconds of a local session's start is treated as the same session.
    public static let workoutMatchToleranceSeconds: TimeInterval = 15 * 60

    // MARK: - Daily metrics

    public func upsertDailyMetrics(_ metrics: DailyMetrics) throws {
        let key = metrics.day.sortKey
        if let existing = try fetchFirst(DailyMetricsEntity.self, where: #Predicate<DailyMetricsEntity> { $0.day == key }) {
            try existing.apply(metrics)
        } else {
            let entity = try DailyMetricsEntity(metrics)
            modelContext.insert(entity)
        }
        try commit()
    }

    public func dailyMetrics(for day: DayKey) throws -> DailyMetrics? {
        let key = day.sortKey
        return try fetchFirst(DailyMetricsEntity.self, where: #Predicate<DailyMetricsEntity> { $0.day == key })?.toDomain()
    }

    /// Ascending by day, inclusive bounds.
    public func dailyMetrics(from start: DayKey, to end: DayKey) throws -> [DailyMetrics] {
        let lo = start.sortKey
        let hi = end.sortKey
        let rows = try fetchAll(
            DailyMetricsEntity.self,
            where: #Predicate<DailyMetricsEntity> { $0.day >= lo && $0.day <= hi },
            sortBy: [SortDescriptor(\.day)]
        )
        return try rows.map { try $0.toDomain() }
    }

    // MARK: - Readiness

    public func upsertReadiness(_ score: ReadinessScore) throws {
        let key = score.day.sortKey
        if let existing = try fetchFirst(ReadinessScoreEntity.self, where: #Predicate<ReadinessScoreEntity> { $0.day == key }) {
            try existing.apply(score)
        } else {
            let entity = try ReadinessScoreEntity(score)
            modelContext.insert(entity)
        }
        try commit()
    }

    public func readiness(for day: DayKey) throws -> ReadinessScore? {
        let key = day.sortKey
        return try fetchFirst(ReadinessScoreEntity.self, where: #Predicate<ReadinessScoreEntity> { $0.day == key })?.toDomain()
    }

    /// Ascending by day, inclusive bounds.
    public func readiness(from start: DayKey, to end: DayKey) throws -> [ReadinessScore] {
        let lo = start.sortKey
        let hi = end.sortKey
        let rows = try fetchAll(
            ReadinessScoreEntity.self,
            where: #Predicate<ReadinessScoreEntity> { $0.day >= lo && $0.day <= hi },
            sortBy: [SortDescriptor(\.day)]
        )
        return try rows.map { try $0.toDomain() }
    }

    // MARK: - Logged sessions and sets

    /// Idempotent by `session.id`. An incoming `revision` lower than the stored one is ignored (the watch never
    /// sends `revision > 0`, so a stale re-send can never overwrite a phone-side edit).
    /// - Parameter replacingSets: `false` (default) upserts the sets in `session.sets` and keeps any others already
    ///   stored (safe for mirroring re-sends with partial lists); `true` makes `session.sets` authoritative and
    ///   deletes stored sets that are missing from it (phone-side edits).
    /// - Returns: `false` when the write was skipped because of the revision guard.
    @discardableResult
    public func upsertLoggedSession(_ session: LoggedSession, replacingSets: Bool = false) throws -> Bool {
        let uuid = session.id.rawValue
        let entity: LoggedSessionEntity
        if let existing = try fetchFirst(LoggedSessionEntity.self, where: #Predicate<LoggedSessionEntity> { $0.id == uuid }) {
            guard session.revision >= existing.revision else { return false }
            try existing.apply(session)
            entity = existing
        } else {
            entity = try LoggedSessionEntity(session)
            modelContext.insert(entity)
        }
        try mergeSets(session.sets, into: entity, replacing: replacingSets)
        try commit()
        return true
    }

    /// Idempotent by `LoggedSet.id`; never deletes. If the session row does not exist yet (a `setLogged` message
    /// arriving before `hello`), a skeleton session with `origin == .watch` is created so no set is ever lost.
    public func upsertLoggedSets(_ sets: [LoggedSet], into sessionID: ID<LoggedSession>) throws {
        let uuid = sessionID.rawValue
        let entity: LoggedSessionEntity
        if let existing = try fetchFirst(LoggedSessionEntity.self, where: #Predicate<LoggedSessionEntity> { $0.id == uuid }) {
            entity = existing
        } else {
            guard let earliest = sets.map({ $0.startedAt ?? $0.completedAt }).min() else { return }
            let skeleton = LoggedSession(id: sessionID, start: earliest, origin: .watch)
            entity = try LoggedSessionEntity(skeleton)
            modelContext.insert(entity)
        }
        try mergeSets(sets, into: entity, replacing: false)
        try commit()
    }

    public func deleteLoggedSets(ids: [ID<LoggedSet>]) throws {
        for id in ids {
            let uuid = id.rawValue
            if let row = try fetchFirst(LoggedSetEntity.self, where: #Predicate<LoggedSetEntity> { $0.id == uuid }) {
                modelContext.delete(row)
            }
        }
        try commit()
    }

    public func loggedSession(id: ID<LoggedSession>) throws -> LoggedSession? {
        let uuid = id.rawValue
        return try fetchFirst(LoggedSessionEntity.self, where: #Predicate<LoggedSessionEntity> { $0.id == uuid })?.toDomain()
    }

    /// Most recent first.
    public func loggedSessions(limit: Int) throws -> [LoggedSession] {
        let rows = try fetchAll(LoggedSessionEntity.self, sortBy: [SortDescriptor(\.start, order: .reverse)], limit: limit)
        return try rows.map { try $0.toDomain() }
    }

    /// Sessions whose `start` falls inside `range`, ascending.
    public func loggedSessions(in range: ClosedRange<Date>) throws -> [LoggedSession] {
        let lo = range.lowerBound
        let hi = range.upperBound
        let rows = try fetchAll(
            LoggedSessionEntity.self,
            where: #Predicate<LoggedSessionEntity> { $0.start >= lo && $0.start <= hi },
            sortBy: [SortDescriptor(\.start)]
        )
        return try rows.map { try $0.toDomain() }
    }

    /// Deletes the session and (cascade) its sets.
    public func deleteLoggedSession(id: ID<LoggedSession>) throws {
        let uuid = id.rawValue
        if let row = try fetchFirst(LoggedSessionEntity.self, where: #Predicate<LoggedSessionEntity> { $0.id == uuid }) {
            modelContext.delete(row)
            try commit()
        }
    }

    /// Working and warm-up sets of one exercise, most recent first (the order `ExerciseHistory` expects).
    public func recentSets(exerciseID: ID<Exercise>, limit: Int) throws -> [LoggedSet] {
        let uuid = exerciseID.rawValue
        let rows = try fetchAll(
            LoggedSetEntity.self,
            where: #Predicate<LoggedSetEntity> { $0.exerciseID == uuid },
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)],
            limit: limit
        )
        return try rows.map { try $0.toDomain() }
    }

    // MARK: - Mesocycles and planned sessions

    public func activeMesocycle() throws -> Mesocycle? {
        try fetchFirst(
            MesocycleEntity.self,
            where: #Predicate<MesocycleEntity> { $0.isActive == true },
            sortBy: [SortDescriptor(\.startDay, order: .reverse)]
        )?.toDomain()
    }

    /// Newest first.
    public func mesocycles() throws -> [Mesocycle] {
        let rows = try fetchAll(MesocycleEntity.self, sortBy: [SortDescriptor(\.startDay, order: .reverse)])
        return try rows.map { try $0.toDomain() }
    }

    /// Idempotent by id. Saving an active mesocycle deactivates every other one (at most one is active).
    public func upsertMesocycle(_ mesocycle: Mesocycle) throws {
        let uuid = mesocycle.id.rawValue
        if mesocycle.isActive {
            let others = try fetchAll(MesocycleEntity.self, where: #Predicate<MesocycleEntity> { $0.isActive == true && $0.id != uuid })
            for other in others { other.isActive = false }
        }
        if let existing = try fetchFirst(MesocycleEntity.self, where: #Predicate<MesocycleEntity> { $0.id == uuid }) {
            try existing.apply(mesocycle)
        } else {
            let entity = try MesocycleEntity(mesocycle)
            modelContext.insert(entity)
        }
        try commit()
    }

    public func deleteMesocycle(id: ID<Mesocycle>) throws {
        let uuid = id.rawValue
        if let row = try fetchFirst(MesocycleEntity.self, where: #Predicate<MesocycleEntity> { $0.id == uuid }) {
            modelContext.delete(row)
            try commit()
        }
    }

    /// The plan for `day`. With `mesocycleID` nil, any plan for that day is returned (a mesocycle's plan first,
    /// then a free session).
    public func plannedSession(for day: DayKey, mesocycleID: ID<Mesocycle>? = nil) throws -> PlannedSession? {
        let key = day.sortKey
        if let mesocycleID {
            let meso: UUID? = mesocycleID.rawValue
            return try fetchFirst(PlannedSessionEntity.self, where: #Predicate<PlannedSessionEntity> { $0.day == key && $0.mesocycleID == meso })?.toDomain()
        }
        let rows = try fetchAll(PlannedSessionEntity.self, where: #Predicate<PlannedSessionEntity> { $0.day == key })
        let preferred = rows.first { $0.mesocycleID != nil } ?? rows.first
        return try preferred?.toDomain()
    }

    /// Ascending by day, inclusive bounds.
    public func plannedSessions(from start: DayKey, to end: DayKey) throws -> [PlannedSession] {
        let lo = start.sortKey
        let hi = end.sortKey
        let rows = try fetchAll(
            PlannedSessionEntity.self,
            where: #Predicate<PlannedSessionEntity> { $0.day >= lo && $0.day <= hi },
            sortBy: [SortDescriptor(\.day)]
        )
        return try rows.map { try $0.toDomain() }
    }

    /// Idempotent by id; also honours the (mesocycleID, day) uniqueness: a different plan already stored for the
    /// same mesocycle and day is replaced by this one.
    public func upsertPlannedSession(_ session: PlannedSession) throws {
        let uuid = session.id.rawValue
        let key = session.day.sortKey
        let meso: UUID? = session.mesocycleID?.rawValue
        if let byID = try fetchFirst(PlannedSessionEntity.self, where: #Predicate<PlannedSessionEntity> { $0.id == uuid }) {
            let clashes = try fetchAll(PlannedSessionEntity.self, where: #Predicate<PlannedSessionEntity> { $0.day == key && $0.mesocycleID == meso && $0.id != uuid })
            for clash in clashes { modelContext.delete(clash) }
            try byID.apply(session)
        } else if let byDay = try fetchFirst(PlannedSessionEntity.self, where: #Predicate<PlannedSessionEntity> { $0.day == key && $0.mesocycleID == meso }) {
            byDay.id = uuid
            try byDay.apply(session)
        } else {
            let entity = try PlannedSessionEntity(session)
            modelContext.insert(entity)
        }
        try commit()
    }

    public func deletePlannedSession(id: ID<PlannedSession>) throws {
        let uuid = id.rawValue
        if let row = try fetchFirst(PlannedSessionEntity.self, where: #Predicate<PlannedSessionEntity> { $0.id == uuid }) {
            modelContext.delete(row)
            try commit()
        }
    }

    // MARK: - Exercise library and program templates

    /// Sorted by Chinese name.
    public func exercises() throws -> [Exercise] {
        let rows = try fetchAll(ExerciseEntity.self, sortBy: [SortDescriptor(\.nameZH)])
        return try rows.map { try $0.toDomain() }
    }

    public func exercise(id: ID<Exercise>) throws -> Exercise? {
        let uuid = id.rawValue
        return try fetchFirst(ExerciseEntity.self, where: #Predicate<ExerciseEntity> { $0.id == uuid })?.toDomain()
    }

    public func upsertExercise(_ exercise: Exercise) throws {
        let uuid = exercise.id.rawValue
        if let existing = try fetchFirst(ExerciseEntity.self, where: #Predicate<ExerciseEntity> { $0.id == uuid }) {
            try existing.apply(exercise)
        } else {
            let entity = try ExerciseEntity(exercise)
            modelContext.insert(entity)
        }
        try commit()
    }

    public func deleteExercise(id: ID<Exercise>) throws {
        let uuid = id.rawValue
        if let row = try fetchFirst(ExerciseEntity.self, where: #Predicate<ExerciseEntity> { $0.id == uuid }) {
            modelContext.delete(row)
            try commit()
        }
    }

    /// Inserts the seed exercises whose ids are not stored yet. Running it again inserts nothing.
    /// - Returns: number of rows inserted.
    @discardableResult
    public func seedExercisesIfNeeded(from seed: [Exercise]) throws -> Int {
        var descriptor = FetchDescriptor<ExerciseEntity>()
        descriptor.propertiesToFetch = [\.id]
        var known = Set(try modelContext.fetch(descriptor).map(\.id))
        var inserted = 0
        for exercise in seed where !known.contains(exercise.id.rawValue) {
            let entity = try ExerciseEntity(exercise)
            modelContext.insert(entity)
            known.insert(exercise.id.rawValue)
            inserted += 1
        }
        try commit()
        return inserted
    }

    /// Inserts the seed program templates whose ids are not stored yet. Running it again inserts nothing.
    /// - Returns: number of rows inserted.
    @discardableResult
    public func seedProgramsIfNeeded(from seed: [ProgramTemplate]) throws -> Int {
        var descriptor = FetchDescriptor<ProgramTemplateEntity>()
        descriptor.propertiesToFetch = [\.id]
        var known = Set(try modelContext.fetch(descriptor).map(\.id))
        var inserted = 0
        for program in seed where !known.contains(program.id.rawValue) {
            let entity = try ProgramTemplateEntity(program)
            modelContext.insert(entity)
            known.insert(program.id.rawValue)
            inserted += 1
        }
        try commit()
        return inserted
    }

    /// Sorted by Chinese name.
    public func programs() throws -> [ProgramTemplate] {
        let rows = try fetchAll(ProgramTemplateEntity.self, sortBy: [SortDescriptor(\.nameZH)])
        return try rows.map { try $0.toDomain() }
    }

    public func program(id: ID<ProgramTemplate>) throws -> ProgramTemplate? {
        let uuid = id.rawValue
        return try fetchFirst(ProgramTemplateEntity.self, where: #Predicate<ProgramTemplateEntity> { $0.id == uuid })?.toDomain()
    }

    public func upsertProgram(_ program: ProgramTemplate) throws {
        let uuid = program.id.rawValue
        if let existing = try fetchFirst(ProgramTemplateEntity.self, where: #Predicate<ProgramTemplateEntity> { $0.id == uuid }) {
            try existing.apply(program)
        } else {
            let entity = try ProgramTemplateEntity(program)
            modelContext.insert(entity)
        }
        try commit()
    }

    // MARK: - Body measurements

    /// Deduplicates by `hkUUID` when present, else by `id`. A re-import after losing the HealthKit anchors therefore
    /// updates rows in place.
    /// - Returns: number of rows inserted (updates are not counted).
    @discardableResult
    public func upsertBodyMeasurements(_ measurements: [BodyMeasurement]) throws -> Int {
        var inserted = 0
        for measurement in measurements {
            var existing: BodyMeasurementEntity? = nil
            if let hk = measurement.hkUUID {
                let target: UUID? = hk
                existing = try fetchFirst(BodyMeasurementEntity.self, where: #Predicate<BodyMeasurementEntity> { $0.hkUUID == target })
            }
            if existing == nil {
                let uuid = measurement.id.rawValue
                existing = try fetchFirst(BodyMeasurementEntity.self, where: #Predicate<BodyMeasurementEntity> { $0.id == uuid })
            }
            if let existing {
                try existing.apply(measurement)
            } else {
                let entity = try BodyMeasurementEntity(measurement)
                modelContext.insert(entity)
                inserted += 1
            }
        }
        try commit()
        return inserted
    }

    /// Ascending by date, inclusive bounds.
    public func bodyMeasurements(from start: Date, to end: Date) throws -> [BodyMeasurement] {
        let rows = try fetchAll(
            BodyMeasurementEntity.self,
            where: #Predicate<BodyMeasurementEntity> { $0.date >= start && $0.date <= end },
            sortBy: [SortDescriptor(\.date)]
        )
        return try rows.map { try $0.toDomain() }
    }

    public func latestBodyMeasurement() throws -> BodyMeasurement? {
        try fetchAll(BodyMeasurementEntity.self, sortBy: [SortDescriptor(\.date, order: .reverse)], limit: 1).first?.toDomain()
    }

    /// Removes rows whose HealthKit sample was deleted (anchored-query `deletedUUIDs`).
    public func deleteBodyMeasurements(hkUUIDs: [UUID]) throws {
        for hk in hkUUIDs {
            let target: UUID? = hk
            if let row = try fetchFirst(BodyMeasurementEntity.self, where: #Predicate<BodyMeasurementEntity> { $0.hkUUID == target }) {
                modelContext.delete(row)
            }
        }
        try commit()
    }

    /// Removes every measurement from one source (e.g. "demo" when demo data is switched off).
    public func deleteBodyMeasurements(source: String) throws {
        try modelContext.delete(model: BodyMeasurementEntity.self, where: #Predicate<BodyMeasurementEntity> { $0.source == source })
        try commit()
    }

    // MARK: - Imported workouts

    /// Records one HealthKit workout and links it to a local session:
    /// 1. already recorded → `.alreadyKnown`;
    /// 2. `setmioSessionID` metadata, then a session that already carries this `hkWorkoutUUID`, then an unlinked
    ///    session starting within `workoutMatchToleranceSeconds` → `.linkedToSession` (fills in `hkWorkoutUUID`,
    ///    `end` and `effortScore` when the session lacks them);
    /// 3. otherwise a placeholder session (`origin == .importedFromHealth`) → `.createdPlaceholder`.
    /// The caller decides which activity types to pass (e.g. only strength training).
    public func markWorkoutImported(_ workout: ImportedWorkout, now: Date = Date()) throws -> ReconcileOutcome {
        let hk = workout.hkUUID
        if try fetchFirst(ImportedWorkoutEntity.self, where: #Predicate<ImportedWorkoutEntity> { $0.hkUUID == hk }) != nil {
            return .alreadyKnown
        }

        var session: LoggedSessionEntity? = nil
        if let sid = workout.setmioSessionID?.rawValue {
            session = try fetchFirst(LoggedSessionEntity.self, where: #Predicate<LoggedSessionEntity> { $0.id == sid })
        }
        if session == nil {
            let target: UUID? = hk
            session = try fetchFirst(LoggedSessionEntity.self, where: #Predicate<LoggedSessionEntity> { $0.hkWorkoutUUID == target })
        }
        if session == nil {
            let lower = workout.start.addingTimeInterval(-Self.workoutMatchToleranceSeconds)
            let upper = workout.start.addingTimeInterval(Self.workoutMatchToleranceSeconds)
            let candidates = try fetchAll(
                LoggedSessionEntity.self,
                where: #Predicate<LoggedSessionEntity> { $0.start >= lower && $0.start <= upper },
                sortBy: [SortDescriptor(\.start)]
            )
            session = candidates.first { $0.hkWorkoutUUID == nil }
        }

        let record = try ImportedWorkoutEntity(workout, importedAt: now)
        if let session {
            if session.hkWorkoutUUID == nil { session.hkWorkoutUUID = hk }
            if session.end == nil { session.end = workout.end }
            if session.effortScore == nil { session.effortScore = workout.effortScore }
            record.linkedSessionID = session.id
            modelContext.insert(record)
            try commit()
            return .linkedToSession(ID(session.id))
        }

        let placeholder = LoggedSession(
            start: workout.start,
            end: workout.end,
            hkWorkoutUUID: hk,
            effortScore: workout.effortScore,
            origin: .importedFromHealth
        )
        let placeholderEntity = try LoggedSessionEntity(placeholder)
        modelContext.insert(placeholderEntity)
        record.linkedSessionID = placeholder.id.rawValue
        modelContext.insert(record)
        try commit()
        return .createdPlaceholder(placeholder.id)
    }

    public func importedWorkout(hkUUID: UUID) throws -> ImportedWorkout? {
        try fetchFirst(ImportedWorkoutEntity.self, where: #Predicate<ImportedWorkoutEntity> { $0.hkUUID == hkUUID })?.toDomain()
    }

    /// Workouts whose `start` falls inside `range`, ascending.
    public func importedWorkouts(in range: ClosedRange<Date>) throws -> [ImportedWorkout] {
        let lo = range.lowerBound
        let hi = range.upperBound
        let rows = try fetchAll(
            ImportedWorkoutEntity.self,
            where: #Predicate<ImportedWorkoutEntity> { $0.start >= lo && $0.start <= hi },
            sortBy: [SortDescriptor(\.start)]
        )
        return try rows.map { try $0.toDomain() }
    }

    // MARK: - Food entries

    /// Entries of one day, ascending by time; items in their logged order.
    public func foodEntries(for day: DayKey) throws -> [FoodEntry] {
        let key = day.sortKey
        let rows = try fetchAll(FoodEntryEntity.self, where: #Predicate<FoodEntryEntity> { $0.day == key }, sortBy: [SortDescriptor(\.time)])
        return try rows.map { try $0.toDomain() }
    }

    /// Ascending by time, inclusive day bounds.
    public func foodEntries(from start: DayKey, to end: DayKey) throws -> [FoodEntry] {
        let lo = start.sortKey
        let hi = end.sortKey
        let rows = try fetchAll(
            FoodEntryEntity.self,
            where: #Predicate<FoodEntryEntity> { $0.day >= lo && $0.day <= hi },
            sortBy: [SortDescriptor(\.time)]
        )
        return try rows.map { try $0.toDomain() }
    }

    /// Idempotent by id. `entry.items` is authoritative: items missing from it are deleted.
    public func upsertFoodEntry(_ entry: FoodEntry) throws {
        let uuid = entry.id.rawValue
        let entity: FoodEntryEntity
        if let existing = try fetchFirst(FoodEntryEntity.self, where: #Predicate<FoodEntryEntity> { $0.id == uuid }) {
            try existing.apply(entry)
            entity = existing
        } else {
            entity = try FoodEntryEntity(entry)
            modelContext.insert(entity)
        }

        var existingByID: [UUID: FoodItemEntity] = [:]
        for item in entity.items { existingByID[item.id] = item }
        var seen = Set<UUID>()
        for (order, item) in entry.items.enumerated() {
            seen.insert(item.id.rawValue)
            if let row = existingByID[item.id.rawValue] {
                try row.apply(item)
                row.sortOrder = order
            } else {
                let row = try FoodItemEntity(item, sortOrder: order)
                modelContext.insert(row)
                row.entry = entity
            }
        }
        for (id, row) in existingByID where !seen.contains(id) {
            modelContext.delete(row)
        }
        try commit()
    }

    /// Deletes the entry and (cascade) its items.
    public func deleteFoodEntry(id: ID<FoodEntry>) throws {
        let uuid = id.rawValue
        if let row = try fetchFirst(FoodEntryEntity.self, where: #Predicate<FoodEntryEntity> { $0.id == uuid }) {
            modelContext.delete(row)
            try commit()
        }
    }

    // MARK: - Energy estimates

    public func upsertEnergyEstimate(_ estimate: EnergyEstimate) throws {
        let key = estimate.day.sortKey
        if let existing = try fetchFirst(EnergyEstimateEntity.self, where: #Predicate<EnergyEstimateEntity> { $0.day == key }) {
            try existing.apply(estimate)
        } else {
            let entity = try EnergyEstimateEntity(estimate)
            modelContext.insert(entity)
        }
        try commit()
    }

    public func energyEstimate(for day: DayKey) throws -> EnergyEstimate? {
        let key = day.sortKey
        return try fetchFirst(EnergyEstimateEntity.self, where: #Predicate<EnergyEstimateEntity> { $0.day == key })?.toDomain()
    }

    /// The estimate with the latest day.
    public func latestEnergyEstimate() throws -> EnergyEstimate? {
        try fetchAll(EnergyEstimateEntity.self, sortBy: [SortDescriptor(\.day, order: .reverse)], limit: 1).first?.toDomain()
    }

    /// Ascending by day, inclusive bounds.
    public func energyEstimates(from start: DayKey, to end: DayKey) throws -> [EnergyEstimate] {
        let lo = start.sortKey
        let hi = end.sortKey
        let rows = try fetchAll(
            EnergyEstimateEntity.self,
            where: #Predicate<EnergyEstimateEntity> { $0.day >= lo && $0.day <= hi },
            sortBy: [SortDescriptor(\.day)]
        )
        return try rows.map { try $0.toDomain() }
    }

    // MARK: - Medications

    /// Newest `startedOn` first.
    public func medications(activeOnly: Bool = false) throws -> [Medication] {
        let sort = [SortDescriptor(\MedicationEntity.startedOn, order: .reverse)]
        let rows: [MedicationEntity]
        if activeOnly {
            rows = try fetchAll(MedicationEntity.self, where: #Predicate<MedicationEntity> { $0.isActive == true }, sortBy: sort)
        } else {
            rows = try fetchAll(MedicationEntity.self, sortBy: sort)
        }
        return try rows.map { try $0.toDomain() }
    }

    public func medication(id: ID<Medication>) throws -> Medication? {
        let uuid = id.rawValue
        return try fetchFirst(MedicationEntity.self, where: #Predicate<MedicationEntity> { $0.id == uuid })?.toDomain()
    }

    public func upsertMedication(_ medication: Medication) throws {
        let uuid = medication.id.rawValue
        if let existing = try fetchFirst(MedicationEntity.self, where: #Predicate<MedicationEntity> { $0.id == uuid }) {
            try existing.apply(medication)
        } else {
            let entity = try MedicationEntity(medication)
            modelContext.insert(entity)
        }
        try commit()
    }

    /// Deletes the medication together with its doses, pens, side-effect logs and plans (they reference it by id,
    /// not by relationship, so the cascade is explicit here).
    public func deleteMedication(id: ID<Medication>) throws {
        let uuid = id.rawValue
        try modelContext.delete(model: DoseLogEntity.self, where: #Predicate<DoseLogEntity> { $0.medicationID == uuid })
        try modelContext.delete(model: PenInventoryEntity.self, where: #Predicate<PenInventoryEntity> { $0.medicationID == uuid })
        try modelContext.delete(model: SideEffectLogEntity.self, where: #Predicate<SideEffectLogEntity> { $0.medicationID == uuid })
        try modelContext.delete(model: GLP1PlanEntity.self, where: #Predicate<GLP1PlanEntity> { $0.medicationID == uuid })
        try modelContext.delete(model: MedicationEntity.self, where: #Predicate<MedicationEntity> { $0.id == uuid })
        try commit()
    }

    // MARK: - Dose logs

    /// Most recent first. `range` bounds `takenAt` (inclusive); `limit` caps the count.
    public func doseLogs(medicationID: ID<Medication>, in range: ClosedRange<Date>? = nil, limit: Int? = nil) throws -> [DoseLog] {
        let uuid = medicationID.rawValue
        let sort = [SortDescriptor(\DoseLogEntity.takenAt, order: .reverse)]
        let rows: [DoseLogEntity]
        if let range {
            let lo = range.lowerBound
            let hi = range.upperBound
            rows = try fetchAll(
                DoseLogEntity.self,
                where: #Predicate<DoseLogEntity> { $0.medicationID == uuid && $0.takenAt >= lo && $0.takenAt <= hi },
                sortBy: sort,
                limit: limit
            )
        } else {
            rows = try fetchAll(DoseLogEntity.self, where: #Predicate<DoseLogEntity> { $0.medicationID == uuid }, sortBy: sort, limit: limit)
        }
        return try rows.map { try $0.toDomain() }
    }

    /// Idempotent by id, then by `hkDoseEventUUID` (a HealthKit dose event imported twice updates one row).
    public func upsertDoseLog(_ dose: DoseLog) throws {
        let uuid = dose.id.rawValue
        var existing = try fetchFirst(DoseLogEntity.self, where: #Predicate<DoseLogEntity> { $0.id == uuid })
        if existing == nil, let hk = dose.hkDoseEventUUID {
            let target: UUID? = hk
            existing = try fetchFirst(DoseLogEntity.self, where: #Predicate<DoseLogEntity> { $0.hkDoseEventUUID == target })
        }
        if let existing {
            try existing.apply(dose)
        } else {
            let entity = try DoseLogEntity(dose)
            modelContext.insert(entity)
        }
        try commit()
    }

    public func deleteDoseLog(id: ID<DoseLog>) throws {
        let uuid = id.rawValue
        if let row = try fetchFirst(DoseLogEntity.self, where: #Predicate<DoseLogEntity> { $0.id == uuid }) {
            modelContext.delete(row)
            try commit()
        }
    }

    // MARK: - Side effects

    /// Ascending by day, inclusive bounds.
    public func sideEffects(medicationID: ID<Medication>, from start: DayKey, to end: DayKey) throws -> [SideEffectLog] {
        let uuid = medicationID.rawValue
        let lo = start.sortKey
        let hi = end.sortKey
        let rows = try fetchAll(
            SideEffectLogEntity.self,
            where: #Predicate<SideEffectLogEntity> { $0.medicationID == uuid && $0.day >= lo && $0.day <= hi },
            sortBy: [SortDescriptor(\.day)]
        )
        return try rows.map { try $0.toDomain() }
    }

    public func upsertSideEffect(_ log: SideEffectLog) throws {
        let uuid = log.id.rawValue
        if let existing = try fetchFirst(SideEffectLogEntity.self, where: #Predicate<SideEffectLogEntity> { $0.id == uuid }) {
            try existing.apply(log)
        } else {
            let entity = try SideEffectLogEntity(log)
            modelContext.insert(entity)
        }
        try commit()
    }

    public func deleteSideEffect(id: ID<SideEffectLog>) throws {
        let uuid = id.rawValue
        if let row = try fetchFirst(SideEffectLogEntity.self, where: #Predicate<SideEffectLogEntity> { $0.id == uuid }) {
            modelContext.delete(row)
            try commit()
        }
    }

    // MARK: - Pen inventory

    /// Pens of one medication, strongest first.
    public func pens(medicationID: ID<Medication>) throws -> [PenInventory] {
        let uuid = medicationID.rawValue
        let rows = try fetchAll(
            PenInventoryEntity.self,
            where: #Predicate<PenInventoryEntity> { $0.medicationID == uuid },
            sortBy: [SortDescriptor(\.strengthMg, order: .reverse)]
        )
        return try rows.map { try $0.toDomain() }
    }

    public func pen(id: ID<PenInventory>) throws -> PenInventory? {
        let uuid = id.rawValue
        return try fetchFirst(PenInventoryEntity.self, where: #Predicate<PenInventoryEntity> { $0.id == uuid })?.toDomain()
    }

    public func upsertPen(_ pen: PenInventory) throws {
        let uuid = pen.id.rawValue
        if let existing = try fetchFirst(PenInventoryEntity.self, where: #Predicate<PenInventoryEntity> { $0.id == uuid }) {
            try existing.apply(pen)
        } else {
            let entity = try PenInventoryEntity(pen)
            modelContext.insert(entity)
        }
        try commit()
    }

    public func deletePen(id: ID<PenInventory>) throws {
        let uuid = id.rawValue
        if let row = try fetchFirst(PenInventoryEntity.self, where: #Predicate<PenInventoryEntity> { $0.id == uuid }) {
            modelContext.delete(row)
            try commit()
        }
    }

    // MARK: - GLP-1 plans

    /// The plan of one medication (at most one is kept per medication).
    public func glp1Plan(medicationID: ID<Medication>) throws -> GLP1Plan? {
        let uuid = medicationID.rawValue
        return try fetchFirst(GLP1PlanEntity.self, where: #Predicate<GLP1PlanEntity> { $0.medicationID == uuid })?.toDomain()
    }

    /// Idempotent by id. Any other plan stored for the same medication is removed (one plan per medication).
    public func upsertGLP1Plan(_ plan: GLP1Plan) throws {
        let uuid = plan.id.rawValue
        let medication = plan.medicationID.rawValue
        let others = try fetchAll(GLP1PlanEntity.self, where: #Predicate<GLP1PlanEntity> { $0.medicationID == medication && $0.id != uuid })
        for other in others { modelContext.delete(other) }
        if let existing = try fetchFirst(GLP1PlanEntity.self, where: #Predicate<GLP1PlanEntity> { $0.id == uuid }) {
            try existing.apply(plan)
        } else {
            let entity = try GLP1PlanEntity(plan)
            modelContext.insert(entity)
        }
        try commit()
    }

    public func deleteGLP1Plan(id: ID<GLP1Plan>) throws {
        let uuid = id.rawValue
        if let row = try fetchFirst(GLP1PlanEntity.self, where: #Predicate<GLP1PlanEntity> { $0.id == uuid }) {
            modelContext.delete(row)
            try commit()
        }
    }

    // MARK: - Profile and settings (singleton rows)

    public func profile() throws -> UserProfile? {
        let key = UserProfileEntity.singletonKey
        return try fetchFirst(UserProfileEntity.self, where: #Predicate<UserProfileEntity> { $0.key == key })?.toDomain()
    }

    public func saveProfile(_ profile: UserProfile) throws {
        let key = UserProfileEntity.singletonKey
        if let existing = try fetchFirst(UserProfileEntity.self, where: #Predicate<UserProfileEntity> { $0.key == key }) {
            try existing.apply(profile)
        } else {
            let entity = try UserProfileEntity(profile)
            modelContext.insert(entity)
        }
        try commit()
    }

    /// `Settings.default` until something has been saved.
    public func settings() throws -> Settings {
        let key = SettingsEntity.singletonKey
        return try fetchFirst(SettingsEntity.self, where: #Predicate<SettingsEntity> { $0.key == key })?.toDomain() ?? .default
    }

    public func saveSettings(_ settings: Settings) throws {
        let key = SettingsEntity.singletonKey
        if let existing = try fetchFirst(SettingsEntity.self, where: #Predicate<SettingsEntity> { $0.key == key }) {
            try existing.apply(settings)
        } else {
            let entity = try SettingsEntity(settings)
            modelContext.insert(entity)
        }
        try commit()
    }

    // MARK: - Maintenance

    /// Deletes every row of every entity (settings "重置所有数据"). The exercise library and programs must be
    /// re-seeded afterwards.
    public func eraseAllData() throws {
        try modelContext.delete(model: LoggedSetEntity.self)
        try modelContext.delete(model: LoggedSessionEntity.self)
        try modelContext.delete(model: PlannedSessionEntity.self)
        try modelContext.delete(model: MesocycleEntity.self)
        try modelContext.delete(model: ProgramTemplateEntity.self)
        try modelContext.delete(model: ExerciseEntity.self)
        try modelContext.delete(model: DailyMetricsEntity.self)
        try modelContext.delete(model: ReadinessScoreEntity.self)
        try modelContext.delete(model: BodyMeasurementEntity.self)
        try modelContext.delete(model: ImportedWorkoutEntity.self)
        try modelContext.delete(model: FoodItemEntity.self)
        try modelContext.delete(model: FoodEntryEntity.self)
        try modelContext.delete(model: EnergyEstimateEntity.self)
        try modelContext.delete(model: DoseLogEntity.self)
        try modelContext.delete(model: PenInventoryEntity.self)
        try modelContext.delete(model: SideEffectLogEntity.self)
        try modelContext.delete(model: GLP1PlanEntity.self)
        try modelContext.delete(model: MedicationEntity.self)
        try modelContext.delete(model: UserProfileEntity.self)
        try modelContext.delete(model: SettingsEntity.self)
        try commit()
    }

    // MARK: - Private helpers

    /// Upserts `sets` under `sessionEntity` (idempotent by set id; a set id already stored under another session is
    /// moved). With `replacing`, stored sets not present in `sets` are deleted.
    private func mergeSets(_ sets: [LoggedSet], into sessionEntity: LoggedSessionEntity, replacing: Bool) throws {
        let sessionUUID = sessionEntity.id
        var existingByID: [UUID: LoggedSetEntity] = [:]
        for row in sessionEntity.sets { existingByID[row.id] = row }
        var seen = Set<UUID>()

        for incoming in sets {
            var set = incoming
            set.sessionID = ID(sessionUUID)
            let setUUID = set.id.rawValue
            seen.insert(setUUID)
            if let row = existingByID[setUUID] {
                try row.apply(set)
            } else if let stray = try fetchFirst(LoggedSetEntity.self, where: #Predicate<LoggedSetEntity> { $0.id == setUUID }) {
                try stray.apply(set)
                stray.session = sessionEntity
            } else {
                let row = try LoggedSetEntity(set)
                modelContext.insert(row)
                row.session = sessionEntity
            }
        }

        if replacing {
            for (id, row) in existingByID where !seen.contains(id) {
                modelContext.delete(row)
            }
        }
    }

    private func fetchFirst<T: PersistentModel>(_ type: T.Type, where predicate: Predicate<T>, sortBy: [SortDescriptor<T>] = []) throws -> T? {
        var descriptor = FetchDescriptor<T>(predicate: predicate, sortBy: sortBy)
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchAll<T: PersistentModel>(_ type: T.Type, where predicate: Predicate<T>? = nil, sortBy: [SortDescriptor<T>] = [], limit: Int? = nil) throws -> [T] {
        var descriptor = FetchDescriptor<T>(predicate: predicate, sortBy: sortBy)
        if let limit { descriptor.fetchLimit = limit }
        return try modelContext.fetch(descriptor)
    }

    private func commit() throws {
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }
}
#endif
