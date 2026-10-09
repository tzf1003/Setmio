import Foundation
import SetmioCore

// MARK: - Errors (Foundation-only; builds on Linux)

public enum SetmioDataError: Error, Sendable, Equatable, Hashable {
    case notFound(entity: String, id: String)
    case corruptRecord(entity: String, field: String, detail: String)
    case encodingFailed(type: String, detail: String)
    case decodingFailed(type: String, detail: String)

    public var messageZH: String {
        switch self {
        case .notFound(let entity, let id): "找不到记录：\(entity) \(id)"
        case .corruptRecord(let entity, let field, let detail): "记录损坏：\(entity).\(field)（\(detail)）"
        case .encodingFailed(let type, let detail): "序列化失败：\(type)（\(detail)）"
        case .decodingFailed(let type, let detail): "反序列化失败：\(type)（\(detail)）"
        }
    }
}

// MARK: - JSON blobs with a schemaVersion wrapper (Foundation-only; builds on Linux)

/// Small Core trees (program days, planned exercises, readiness components, dosage form, settings…) are stored
/// as JSON `Data` inside one column. Every blob is wrapped in `{ "schemaVersion": n, "payload": … }` so a blob's
/// shape can evolve (decode by version) without a SwiftData migration.
public enum JSONBlob {
    /// Version written by this build. Bump when a payload's shape changes and branch in `decode`.
    public static let currentSchemaVersion = 1

    public struct Envelope<Payload: Codable>: Codable {
        public var schemaVersion: Int
        public var payload: Payload

        public init(schemaVersion: Int, payload: Payload) {
            self.schemaVersion = schemaVersion
            self.payload = payload
        }
    }

    private struct VersionProbe: Decodable {
        var schemaVersion: Int
    }

    public static func encode<T: Codable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(Envelope(schemaVersion: currentSchemaVersion, payload: value))
        } catch {
            throw SetmioDataError.encodingFailed(type: String(describing: T.self), detail: String(describing: error))
        }
    }

    public static func encodeOptional<T: Codable>(_ value: T?) throws -> Data? {
        guard let value else { return nil }
        return try encode(value)
    }

    public static func decode<T: Codable>(_ type: T.Type = T.self, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(Envelope<T>.self, from: data).payload
        } catch {
            throw SetmioDataError.decodingFailed(type: String(describing: T.self), detail: String(describing: error))
        }
    }

    public static func decodeOptional<T: Codable>(_ type: T.Type = T.self, from data: Data?) throws -> T? {
        guard let data, !data.isEmpty else { return nil }
        return try decode(type, from: data)
    }

    /// The `schemaVersion` a stored blob was written with, or nil when the data is not an envelope.
    public static func schemaVersion(of data: Data) -> Int? {
        try? JSONDecoder().decode(VersionProbe.self, from: data).schemaVersion
    }
}

// MARK: - Raw-value enums

enum RawMap {
    /// `E(rawValue:)` that throws `corruptRecord` instead of silently picking a default — a wrong `DrugID` or
    /// `SessionOrigin` must never be invented.
    static func decode<E: RawRepresentable>(_ raw: E.RawValue, as type: E.Type = E.self, entity: String, field: String) throws -> E {
        guard let value = E(rawValue: raw) else {
            throw SetmioDataError.corruptRecord(entity: entity, field: field, detail: "未知枚举值 \(raw)")
        }
        return value
    }

    static func decodeOptional<E: RawRepresentable>(_ raw: E.RawValue?, as type: E.Type = E.self, entity: String, field: String) throws -> E? {
        guard let raw else { return nil }
        return try decode(raw, as: type, entity: entity, field: field)
    }
}

#if canImport(SwiftData)
import SwiftData

// Every entity gets three members:
//   convenience init(_ core:) throws   — build a fresh, not-yet-inserted entity from a Core value
//   apply(_ core:) throws              — overwrite the row's attributes (identity is never changed)
//   toDomain() throws                  — Core value for engines/UI; throws on corrupt blobs or unknown raw values
// Relationships (session.sets, entry.items) are reconciled by `SetmioStore`, which owns the ModelContext.

// MARK: - Training

extension ExerciseEntity {
    public convenience init(_ value: Exercise) throws {
        self.init(id: value.id.rawValue)
        try apply(value)
    }

    public func apply(_ value: Exercise) throws {
        nameZH = value.nameZH
        nameEN = value.nameEN
        primaryRaw = value.primary.map(\.rawValue)
        secondaryRaw = value.secondary.map(\.rawValue)
        categoryRaw = value.category.rawValue
        equipmentRaw = value.equipment.rawValue
        loadIncrement = value.loadIncrement
        isUnilateral = value.isUnilateral
        repTemplateJSON = try JSONBlob.encodeOptional(value.repTemplate)
        isCustom = value.isCustom
    }

    public func toDomain() throws -> Exercise {
        let entity = "ExerciseEntity"
        return Exercise(
            id: ID(id),
            nameZH: nameZH,
            nameEN: nameEN,
            primary: try primaryRaw.map { try RawMap.decode($0, as: MuscleGroup.self, entity: entity, field: "primaryRaw") },
            secondary: try secondaryRaw.map { try RawMap.decode($0, as: MuscleGroup.self, entity: entity, field: "secondaryRaw") },
            category: try RawMap.decode(categoryRaw, as: ExerciseCategory.self, entity: entity, field: "categoryRaw"),
            equipment: try RawMap.decode(equipmentRaw, as: Equipment.self, entity: entity, field: "equipmentRaw"),
            loadIncrement: loadIncrement,
            isUnilateral: isUnilateral,
            repTemplate: try JSONBlob.decodeOptional(RepTemplate.self, from: repTemplateJSON),
            isCustom: isCustom
        )
    }
}

extension ProgramTemplateEntity {
    public convenience init(_ value: ProgramTemplate) throws {
        self.init(id: value.id.rawValue)
        try apply(value)
    }

    public func apply(_ value: ProgramTemplate) throws {
        nameZH = value.nameZH
        daysPerWeek = value.daysPerWeek
        mesocycleWeeks = value.mesocycleWeeks
        daysJSON = try JSONBlob.encode(value.days)
    }

    public func toDomain() throws -> ProgramTemplate {
        ProgramTemplate(
            id: ID(id),
            nameZH: nameZH,
            daysPerWeek: daysPerWeek,
            days: try JSONBlob.decode([ProgramDay].self, from: daysJSON),
            mesocycleWeeks: mesocycleWeeks
        )
    }
}

extension MesocycleEntity {
    public convenience init(_ value: Mesocycle) throws {
        self.init(id: value.id.rawValue)
        try apply(value)
    }

    public func apply(_ value: Mesocycle) throws {
        templateID = value.templateID.rawValue
        startDay = value.startDay.sortKey
        weeksJSON = try JSONBlob.encode(value.weeks)
        currentWeekIndex = value.currentWeekIndex
        isActive = value.isActive
    }

    public func toDomain() throws -> Mesocycle {
        Mesocycle(
            id: ID(id),
            templateID: ID(templateID),
            startDay: DayKey(sortKey: startDay),
            weeks: try JSONBlob.decode([MesocycleWeek].self, from: weeksJSON),
            currentWeekIndex: currentWeekIndex,
            isActive: isActive
        )
    }
}

extension PlannedSessionEntity {
    public convenience init(_ value: PlannedSession) throws {
        self.init(id: value.id.rawValue)
        try apply(value)
    }

    public func apply(_ value: PlannedSession) throws {
        mesocycleID = value.mesocycleID?.rawValue
        day = value.day.sortKey
        dayNameZH = value.dayNameZH
        exercisesJSON = try JSONBlob.encode(value.exercises)
        readinessAdjustmentJSON = try JSONBlob.encodeOptional(value.readinessAdjustment)
    }

    public func toDomain() throws -> PlannedSession {
        PlannedSession(
            id: ID(id),
            mesocycleID: mesocycleID.map { ID($0) },
            day: DayKey(sortKey: day),
            dayNameZH: dayNameZH,
            exercises: try JSONBlob.decode([PlannedExercise].self, from: exercisesJSON),
            readinessAdjustment: try JSONBlob.decodeOptional(ReadinessAdjustment.self, from: readinessAdjustmentJSON)
        )
    }
}

extension LoggedSessionEntity {
    /// Scalars only — `sets` are reconciled by `SetmioStore` (needs the context to delete removed rows).
    public convenience init(_ value: LoggedSession) throws {
        self.init(id: value.id.rawValue)
        try apply(value)
    }

    /// Scalars only; does not touch `sets`.
    public func apply(_ value: LoggedSession) throws {
        plannedSessionID = value.plannedSessionID?.rawValue
        start = value.start
        end = value.end
        feedbackSoreness = value.feedback?.soreness
        feedbackPump = value.feedback?.pump
        feedbackJoint = value.feedback?.joint
        feedbackNote = value.feedback?.note
        hkWorkoutUUID = value.hkWorkoutUUID
        effortScore = value.effortScore
        originRaw = value.origin.rawValue
        revision = value.revision
    }

    /// Sets come back in chronological order (`completedAt`, then `index`).
    public func toDomain() throws -> LoggedSession {
        let feedback: SessionFeedback? = if let s = feedbackSoreness, let p = feedbackPump, let j = feedbackJoint {
            SessionFeedback(soreness: s, pump: p, joint: j, note: feedbackNote)
        } else {
            nil
        }
        let orderedSets = sets.sorted { a, b in
            a.completedAt == b.completedAt ? a.setIndex < b.setIndex : a.completedAt < b.completedAt
        }
        return LoggedSession(
            id: ID(id),
            plannedSessionID: plannedSessionID.map { ID($0) },
            start: start,
            end: end,
            sets: try orderedSets.map { try $0.toDomain() },
            feedback: feedback,
            hkWorkoutUUID: hkWorkoutUUID,
            effortScore: effortScore,
            origin: try RawMap.decode(originRaw, as: SessionOrigin.self, entity: "LoggedSessionEntity", field: "originRaw"),
            revision: revision
        )
    }
}

extension LoggedSetEntity {
    public convenience init(_ value: LoggedSet) throws {
        self.init(id: value.id.rawValue)
        try apply(value)
    }

    public func apply(_ value: LoggedSet) throws {
        sessionID = value.sessionID.rawValue
        exerciseID = value.exerciseID.rawValue
        setIndex = value.index
        load = value.load
        reps = value.reps
        rir = value.rir
        tempoJSON = try JSONBlob.encodeOptional(value.tempo)
        startedAt = value.startedAt
        completedAt = value.completedAt
        isWarmup = value.isWarmup
        estimatedReps = value.estimatedReps
    }

    public func toDomain() throws -> LoggedSet {
        LoggedSet(
            id: ID(id),
            sessionID: ID(sessionID),
            exerciseID: ID(exerciseID),
            index: setIndex,
            load: load,
            reps: reps,
            rir: rir,
            tempo: try JSONBlob.decodeOptional(Tempo.self, from: tempoJSON),
            startedAt: startedAt,
            completedAt: completedAt,
            isWarmup: isWarmup,
            estimatedReps: estimatedReps
        )
    }
}

// MARK: - Health

extension DailyMetricsEntity {
    public convenience init(_ value: DailyMetrics) throws {
        self.init(day: value.day.sortKey)
        try apply(value)
    }

    public func apply(_ value: DailyMetrics) throws {
        hrvSDNN = value.hrvSDNN
        hrvRMSSD = value.hrvRMSSD
        restingHR = value.restingHR
        restingHRFrozenAt = value.restingHRFrozenAt
        overnightRespiratoryRate = value.overnightRespiratoryRate
        wristTemperature = value.wristTemperature
        wristTemperatureDeviation = value.wristTemperatureDeviation
        steps = value.steps
        activeEnergy = value.activeEnergy
        basalEnergy = value.basalEnergy
        workoutEffort = value.workoutEffort
        trainingLoad = value.trainingLoad
        sleepJSON = try JSONBlob.encodeOptional(value.sleep)
        subjectiveJSON = try JSONBlob.encodeOptional(value.subjective)
    }

    public func toDomain() throws -> DailyMetrics {
        DailyMetrics(
            day: DayKey(sortKey: day),
            hrvSDNN: hrvSDNN,
            hrvRMSSD: hrvRMSSD,
            restingHR: restingHR,
            restingHRFrozenAt: restingHRFrozenAt,
            overnightRespiratoryRate: overnightRespiratoryRate,
            wristTemperature: wristTemperature,
            wristTemperatureDeviation: wristTemperatureDeviation,
            sleep: try JSONBlob.decodeOptional(SleepWindow.self, from: sleepJSON),
            steps: steps,
            activeEnergy: activeEnergy,
            basalEnergy: basalEnergy,
            workoutEffort: workoutEffort,
            trainingLoad: trainingLoad,
            subjective: try JSONBlob.decodeOptional(SubjectiveCheckIn.self, from: subjectiveJSON)
        )
    }
}

extension ReadinessScoreEntity {
    public convenience init(_ value: ReadinessScore) throws {
        self.init(day: value.day.sortKey)
        try apply(value)
    }

    public func apply(_ value: ReadinessScore) throws {
        score = value.score
        bandRaw = value.band.rawValue
        confidence = value.confidence
        componentsJSON = try JSONBlob.encode(value.components)
        flagsJSON = try JSONBlob.encode(value.flags)
        baselineDays = value.baselineDays
        computedAt = value.computedAt
    }

    public func toDomain() throws -> ReadinessScore {
        ReadinessScore(
            day: DayKey(sortKey: day),
            score: score,
            band: try RawMap.decode(bandRaw, as: ReadinessBand.self, entity: "ReadinessScoreEntity", field: "bandRaw"),
            confidence: confidence,
            components: try JSONBlob.decode([ReadinessComponent].self, from: componentsJSON),
            flags: try JSONBlob.decode([ReadinessFlag].self, from: flagsJSON),
            baselineDays: baselineDays,
            computedAt: computedAt
        )
    }
}

extension BodyMeasurementEntity {
    public convenience init(_ value: BodyMeasurement) throws {
        self.init(id: value.id.rawValue)
        try apply(value)
    }

    public func apply(_ value: BodyMeasurement) throws {
        hkUUID = value.hkUUID
        date = value.date
        weight = value.weight
        bodyFat = value.bodyFat
        leanMass = value.leanMass
        source = value.source
    }

    public func toDomain() throws -> BodyMeasurement {
        BodyMeasurement(id: ID(id), hkUUID: hkUUID, date: date, weight: weight, bodyFat: bodyFat, leanMass: leanMass, source: source)
    }
}

extension ImportedWorkoutEntity {
    public convenience init(_ value: ImportedWorkout, importedAt: Date) throws {
        self.init(hkUUID: value.hkUUID)
        try apply(value)
        self.importedAt = importedAt
    }

    /// Does not touch `linkedSessionID` (owned by the reconciliation in `SetmioStore.markWorkoutImported`).
    public func apply(_ value: ImportedWorkout) throws {
        start = value.start
        end = value.end
        activityTypeRawValue = value.activityTypeRawValue
        totalEnergy = value.totalEnergy
        effortScore = value.effortScore
        sourceBundleID = value.sourceBundleID
    }

    public func toDomain() throws -> ImportedWorkout {
        ImportedWorkout(
            hkUUID: hkUUID,
            start: start,
            end: end,
            activityTypeRawValue: activityTypeRawValue,
            totalEnergy: totalEnergy,
            effortScore: effortScore,
            sourceBundleID: sourceBundleID,
            setmioSessionID: linkedSessionID.map { ID($0) }
        )
    }
}

// MARK: - Lifestyle

extension FoodEntryEntity {
    /// Scalars only — `items` are reconciled by `SetmioStore`.
    public convenience init(_ value: FoodEntry) throws {
        self.init(id: value.id.rawValue)
        try apply(value)
    }

    /// Scalars only; does not touch `items`.
    public func apply(_ value: FoodEntry) throws {
        day = value.day.sortKey
        time = value.time
        mealRaw = value.meal.rawValue
        photoLocalPath = value.photoLocalPath
        confirmed = value.confirmed
    }

    public func toDomain() throws -> FoodEntry {
        FoodEntry(
            id: ID(id),
            day: DayKey(sortKey: day),
            time: time,
            meal: try RawMap.decode(mealRaw, as: MealType.self, entity: "FoodEntryEntity", field: "mealRaw"),
            items: try items.sorted { $0.sortOrder < $1.sortOrder }.map { try $0.toDomain() },
            photoLocalPath: photoLocalPath,
            confirmed: confirmed
        )
    }
}

extension FoodItemEntity {
    public convenience init(_ value: FoodItem, sortOrder: Int) throws {
        self.init(id: value.id.rawValue)
        try apply(value)
        self.sortOrder = sortOrder
    }

    public func apply(_ value: FoodItem) throws {
        nameZH = value.nameZH
        nameEN = value.nameEN
        portionGrams = value.portionGrams
        portionLabel = value.portionLabel
        kcal = value.facts.kcal
        protein = value.facts.protein
        carbs = value.facts.carbs
        fat = value.facts.fat
        fiber = value.facts.fiber
        kcalLow = value.kcalLow
        kcalHigh = value.kcalHigh
        confidence = value.confidence
        sourceRaw = value.source.rawValue
        originalKcalEstimate = value.originalKcalEstimate
    }

    public func toDomain() throws -> FoodItem {
        FoodItem(
            id: ID(id),
            nameZH: nameZH,
            nameEN: nameEN,
            portionGrams: portionGrams,
            portionLabel: portionLabel,
            facts: NutritionFacts(kcal: kcal, protein: protein, carbs: carbs, fat: fat, fiber: fiber),
            kcalLow: kcalLow,
            kcalHigh: kcalHigh,
            confidence: confidence,
            source: try RawMap.decode(sourceRaw, as: FoodItemSource.self, entity: "FoodItemEntity", field: "sourceRaw"),
            originalKcalEstimate: originalKcalEstimate
        )
    }
}

extension EnergyEstimateEntity {
    public convenience init(_ value: EnergyEstimate) throws {
        self.init(day: value.day.sortKey)
        try apply(value)
    }

    public func apply(_ value: EnergyEstimate) throws {
        tdee = value.tdee
        variance = value.variance
        trendWeight = value.trendWeight
        trendSlopePerWeek = value.trendSlopePerWeek
        loggingCompleteness = value.loggingCompleteness
        windowDays = value.windowDays
    }

    public func toDomain() throws -> EnergyEstimate {
        EnergyEstimate(
            day: DayKey(sortKey: day),
            tdee: tdee,
            variance: variance,
            trendWeight: trendWeight,
            trendSlopePerWeek: trendSlopePerWeek,
            loggingCompleteness: loggingCompleteness,
            windowDays: windowDays
        )
    }
}

extension MedicationEntity {
    public convenience init(_ value: Medication) throws {
        self.init(id: value.id.rawValue)
        try apply(value)
    }

    public func apply(_ value: Medication) throws {
        drugRaw = value.drug.rawValue
        formJSON = try JSONBlob.encode(value.form)
        startedOn = value.startedOn.sortKey
        isActive = value.isActive
        isUnverifiedSource = value.isUnverifiedSource
        hkMedicationConceptID = value.hkMedicationConceptID
    }

    public func toDomain() throws -> Medication {
        Medication(
            id: ID(id),
            drug: try RawMap.decode(drugRaw, as: DrugID.self, entity: "MedicationEntity", field: "drugRaw"),
            form: try JSONBlob.decode(DosageForm.self, from: formJSON),
            startedOn: DayKey(sortKey: startedOn),
            isActive: isActive,
            isUnverifiedSource: isUnverifiedSource,
            hkMedicationConceptID: hkMedicationConceptID
        )
    }
}

extension DoseLogEntity {
    public convenience init(_ value: DoseLog) throws {
        self.init(id: value.id.rawValue)
        try apply(value)
    }

    public func apply(_ value: DoseLog) throws {
        medicationID = value.medicationID.rawValue
        takenAt = value.takenAt
        doseMg = value.doseMg
        siteRaw = value.site?.rawValue
        penID = value.penID?.rawValue
        wasMissedMakeup = value.wasMissedMakeup
        hkDoseEventUUID = value.hkDoseEventUUID
        note = value.note
    }

    public func toDomain() throws -> DoseLog {
        DoseLog(
            id: ID(id),
            medicationID: ID(medicationID),
            takenAt: takenAt,
            doseMg: doseMg,
            site: try RawMap.decodeOptional(siteRaw, as: InjectionSite.self, entity: "DoseLogEntity", field: "siteRaw"),
            penID: penID.map { ID($0) },
            wasMissedMakeup: wasMissedMakeup,
            hkDoseEventUUID: hkDoseEventUUID,
            note: note
        )
    }
}

extension PenInventoryEntity {
    public convenience init(_ value: PenInventory) throws {
        self.init(id: value.id.rawValue)
        try apply(value)
    }

    public func apply(_ value: PenInventory) throws {
        medicationID = value.medicationID.rawValue
        strengthMg = value.strengthMg
        dosesRemaining = value.dosesRemaining
        firstUsedAt = value.firstUsedAt
        inUseExpiry = value.inUseExpiry
        lotExpiry = value.lotExpiry
        coldChainBreach = value.coldChainBreach
    }

    public func toDomain() throws -> PenInventory {
        PenInventory(
            id: ID(id),
            medicationID: ID(medicationID),
            strengthMg: strengthMg,
            dosesRemaining: dosesRemaining,
            firstUsedAt: firstUsedAt,
            inUseExpiry: inUseExpiry,
            lotExpiry: lotExpiry,
            coldChainBreach: coldChainBreach
        )
    }
}

extension SideEffectLogEntity {
    public convenience init(_ value: SideEffectLog) throws {
        self.init(id: value.id.rawValue)
        try apply(value)
    }

    public func apply(_ value: SideEffectLog) throws {
        medicationID = value.medicationID.rawValue
        day = value.day.sortKey
        kindRaw = value.kind.rawValue
        severity = value.severity
        note = value.note
    }

    public func toDomain() throws -> SideEffectLog {
        SideEffectLog(
            id: ID(id),
            medicationID: ID(medicationID),
            day: DayKey(sortKey: day),
            kind: try RawMap.decode(kindRaw, as: SideEffectLog.Kind.self, entity: "SideEffectLogEntity", field: "kindRaw"),
            severity: severity,
            note: note
        )
    }
}

extension GLP1PlanEntity {
    public convenience init(_ value: GLP1Plan) throws {
        self.init(id: value.id.rawValue)
        try apply(value)
    }

    public func apply(_ value: GLP1Plan) throws {
        medicationID = value.medicationID.rawValue
        drugRaw = value.drug.rawValue
        labelVersion = value.labelVersion
        stepsJSON = try JSONBlob.encode(value.steps)
        currentStepIndex = value.currentStepIndex
        injectionWeekday = value.injectionWeekday
        reminderHour = value.reminderHour
        clinicianConfirmedOffLabel = value.clinicianConfirmedOffLabel
    }

    public func toDomain() throws -> GLP1Plan {
        GLP1Plan(
            id: ID(id),
            medicationID: ID(medicationID),
            drug: try RawMap.decode(drugRaw, as: DrugID.self, entity: "GLP1PlanEntity", field: "drugRaw"),
            labelVersion: labelVersion,
            steps: try JSONBlob.decode([GLP1PlanStep].self, from: stepsJSON),
            currentStepIndex: currentStepIndex,
            injectionWeekday: injectionWeekday,
            reminderHour: reminderHour,
            clinicianConfirmedOffLabel: clinicianConfirmedOffLabel
        )
    }
}

extension UserProfileEntity {
    public convenience init(_ value: UserProfile) throws {
        self.init(key: Self.singletonKey)
        try apply(value)
    }

    public func apply(_ value: UserProfile) throws {
        payloadJSON = try JSONBlob.encode(value)
    }

    public func toDomain() throws -> UserProfile {
        try JSONBlob.decode(UserProfile.self, from: payloadJSON)
    }
}

extension SettingsEntity {
    public convenience init(_ value: Settings) throws {
        self.init(key: Self.singletonKey)
        try apply(value)
    }

    public func apply(_ value: Settings) throws {
        payloadJSON = try JSONBlob.encode(value)
    }

    public func toDomain() throws -> Settings {
        try JSONBlob.decode(Settings.self, from: payloadJSON)
    }
}
#endif
