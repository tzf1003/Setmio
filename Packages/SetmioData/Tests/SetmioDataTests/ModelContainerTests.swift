// Runs on macOS / iOS only (SwiftData). On Linux this file compiles to nothing; see README.md.
#if canImport(SwiftData)
import Foundation
import SwiftData
import Testing
import SetmioCore
@testable import SetmioData

@Suite("SetmioStore · 内存容器", .serialized)
struct ModelContainerTests {
    static let calendar = Calendar.setmioDefault
    static let day = DayKey(year: 2026, month: 10, day: 9)

    private func makeStore() throws -> SetmioStore {
        let container = try ModelContainerFactory.make(inMemory: true)
        return SetmioStore(modelContainer: container)
    }

    private static func exercise(_ suffix: String, nameZH: String) -> Exercise {
        Exercise(
            id: ID(uuidString: "00000000-0000-4000-8000-0000000000\(suffix)")!,
            nameZH: nameZH,
            primary: [.chest],
            category: .compound,
            equipment: .barbell,
            loadIncrement: 2.5
        )
    }

    @Test("记录一次 3 组的训练并原样读回")
    func loggedSessionRoundTrip() async throws {
        let store = try makeStore()
        let sessionID = ID<LoggedSession>()
        let exerciseID = ID<Exercise>()
        let start = Self.day.date(atHour: 18, calendar: Self.calendar)
        let sets = (0..<3).map { index in
            LoggedSet(
                sessionID: sessionID,
                exerciseID: exerciseID,
                index: index,
                load: 60,
                reps: 10 - index,
                rir: 2,
                tempo: index == 0 ? Tempo(eccentric: 3, pauseBottom: 1, concentric: 1, pauseTop: 0) : nil,
                startedAt: start.addingTimeInterval(Double(index) * 240),
                completedAt: start.addingTimeInterval(Double(index) * 240 + 40),
                estimatedReps: index == 2 ? 8 : nil
            )
        }
        let session = LoggedSession(
            id: sessionID,
            start: start,
            end: start.addingTimeInterval(3600),
            sets: sets,
            feedback: SessionFeedback(soreness: 2, pump: 3, joint: 1, note: "状态不错"),
            effortScore: 7,
            origin: .watch
        )

        let applied = try await store.upsertLoggedSession(session)
        #expect(applied)

        let fetched = try await store.loggedSession(id: sessionID)
        #expect(fetched == session)

        // Re-sending the same session is idempotent: still 3 sets.
        try await store.upsertLoggedSession(session)
        #expect(try await store.loggedSession(id: sessionID)?.sets.count == 3)

        let recent = try await store.recentSets(exerciseID: exerciseID, limit: 2)
        #expect(recent.map(\.index) == [2, 1])
    }

    @Test("组按 id 幂等追加；旧 revision 不覆盖新 revision")
    func setsMergeAndRevisionGuard() async throws {
        let store = try makeStore()
        let sessionID = ID<LoggedSession>()
        let exerciseID = ID<Exercise>()
        let start = Self.day.date(atHour: 7, calendar: Self.calendar)
        let first = LoggedSet(sessionID: sessionID, exerciseID: exerciseID, index: 0, load: 100, reps: 5, rir: 2, completedAt: start.addingTimeInterval(60))

        // Sets may arrive before the session itself (mirroring): a skeleton session is created.
        try await store.upsertLoggedSets([first], into: sessionID)
        try await store.upsertLoggedSets([first], into: sessionID)
        let skeleton = try await store.loggedSession(id: sessionID)
        #expect(skeleton?.origin == .watch)
        #expect(skeleton?.sets == [first])

        // The phone edits the session (revision 1) and makes its set list authoritative.
        let edited = LoggedSession(id: sessionID, start: start, end: start.addingTimeInterval(1800), sets: [], origin: .watch, revision: 1)
        try await store.upsertLoggedSession(edited, replacingSets: true)
        #expect(try await store.loggedSession(id: sessionID)?.sets.isEmpty == true)

        // A stale watch re-send (revision 0) must not win.
        let stale = LoggedSession(id: sessionID, start: start, end: nil, sets: [first], origin: .watch, revision: 0)
        let applied = try await store.upsertLoggedSession(stale)
        #expect(!applied)
        let after = try await store.loggedSession(id: sessionID)
        #expect(after?.revision == 1)
        #expect(after?.end == start.addingTimeInterval(1800))
        #expect(after?.sets.isEmpty == true)
    }

    @Test("同一天两次 upsert DailyMetrics 只保留一行")
    func dailyMetricsUpsertKeepsOneRow() async throws {
        let store = try makeStore()
        let night = Self.day.adding(days: -1, calendar: Self.calendar).date(atHour: 23, minute: 30, calendar: Self.calendar)
        let morning = Self.day.date(atHour: 7, calendar: Self.calendar)
        let v1 = DailyMetrics(day: Self.day, hrvSDNN: 48, restingHR: 56, sleep: SleepWindow(start: night, end: morning, asleepMinutes: 440))
        var v2 = v1
        v2.hrvSDNN = 52
        v2.subjective = SubjectiveCheckIn(energy: 4, soreness: 2, mood: 4, stress: 2)

        try await store.upsertDailyMetrics(v1)
        try await store.upsertDailyMetrics(v2)

        let rows = try await store.dailyMetrics(from: Self.day, to: Self.day)
        #expect(rows.count == 1)
        #expect(rows.first == v2)
        #expect(try await store.dailyMetrics(for: Self.day) == v2)
    }

    @Test("Readiness 与 EnergyEstimate 按天唯一")
    func dayKeyedRowsAreUnique() async throws {
        let store = try makeStore()
        let computedAt = Self.day.date(atHour: 8, calendar: Self.calendar)
        let score = ReadinessScore(
            day: Self.day,
            score: 72,
            band: .green,
            confidence: 0.5,
            components: [ReadinessComponent(kind: .hrv, z: 0.4, subScore: 0.4, weight: 0.35)],
            flags: [.lowConfidence],
            baselineDays: 30,
            computedAt: computedAt
        )
        try await store.upsertReadiness(score)
        var updated = score
        updated.score = 70
        try await store.upsertReadiness(updated)
        #expect(try await store.readiness(for: Self.day) == updated)
        #expect(try await store.readiness(from: Self.day, to: Self.day).count == 1)

        let estimate = EnergyEstimate(day: Self.day, tdee: 2400, variance: 90_000, trendWeight: 80.2, trendSlopePerWeek: -0.3, loggingCompleteness: 0.9)
        try await store.upsertEnergyEstimate(estimate)
        try await store.upsertEnergyEstimate(estimate)
        #expect(try await store.latestEnergyEstimate() == estimate)
        #expect(try await store.energyEstimates(from: Self.day, to: Self.day).count == 1)
    }

    @Test("动作库重复 seed 不产生重复行")
    func seedingExercisesTwiceDoesNotDuplicate() async throws {
        let store = try makeStore()
        let seed = [
            Self.exercise("01", nameZH: "杠铃深蹲"),
            Self.exercise("02", nameZH: "杠铃硬拉"),
            Self.exercise("03", nameZH: "杠铃卧推"),
        ]
        let before = try await store.exercises().count

        let firstRun = try await store.seedExercisesIfNeeded(from: seed)
        #expect(firstRun == 3)
        let afterFirst = try await store.exercises()
        #expect(afterFirst.count == before + 3)

        let secondRun = try await store.seedExercisesIfNeeded(from: seed)
        #expect(secondRun == 0)
        let afterSecond = try await store.exercises()
        #expect(afterSecond.count == afterFirst.count)
        #expect(Set(afterSecond.map(\.id)).isSuperset(of: seed.map(\.id)))
        #expect(try await store.exercise(id: seed[2].id) == seed[2])
    }

    @Test("计划模板与中周期：JSON 树往返，活动中周期唯一")
    func programsAndMesocycles() async throws {
        let store = try makeStore()
        let bench = Self.exercise("03", nameZH: "杠铃卧推")
        let template = ProgramTemplate(
            nameZH: "推拉腿",
            daysPerWeek: 3,
            days: [ProgramDay(nameZH: "推", prescriptions: [ExercisePrescription(exerciseID: bench.id, sets: 4, repRange: 6...10, progression: .rtsPercent(targetPercentOfE1RM: 0.8))])]
        )
        #expect(try await store.seedProgramsIfNeeded(from: [template]) == 1)
        #expect(try await store.seedProgramsIfNeeded(from: [template]) == 0)
        #expect(try await store.program(id: template.id) == template)

        let older = Mesocycle(templateID: template.id, startDay: Self.day.adding(days: -35, calendar: Self.calendar))
        let newer = Mesocycle(templateID: template.id, startDay: Self.day)
        try await store.upsertMesocycle(older)
        try await store.upsertMesocycle(newer)
        #expect(try await store.activeMesocycle() == newer)
        let all = try await store.mesocycles()
        #expect(all.filter(\.isActive).count == 1)

        let planned = PlannedSession(
            mesocycleID: newer.id,
            day: Self.day,
            dayNameZH: "推",
            exercises: [PlannedExercise(exerciseID: bench.id, sets: [PlannedSet(index: 0, targetLoad: 60, targetReps: 6...10, targetRIR: 2)], decision: .increaseLoad(by: 2.5))],
            readinessAdjustment: ReadinessAdjustment(readinessScore: 40, loadMultiplier: 0.9, setsDelta: -1, rirDelta: 1, noteZH: "恢复度偏低")
        )
        try await store.upsertPlannedSession(planned)
        #expect(try await store.plannedSession(for: Self.day) == planned)

        // A new plan for the same mesocycle and day replaces the old one.
        var replacement = planned
        replacement.id = ID()
        replacement.exercises = []
        try await store.upsertPlannedSession(replacement)
        #expect(try await store.plannedSession(for: Self.day, mesocycleID: newer.id) == replacement)
        #expect(try await store.plannedSessions(from: Self.day, to: Self.day).count == 1)
    }

    @Test("体重按 hkUUID 去重")
    func bodyMeasurementsDedupeByHKUUID() async throws {
        let store = try makeStore()
        let hk = UUID()
        let when = Self.day.date(atHour: 7, calendar: Self.calendar)
        let first = BodyMeasurement(hkUUID: hk, date: when, weight: 80.4, source: "com.apple.Health")
        let again = BodyMeasurement(hkUUID: hk, date: when, weight: 80.4, bodyFat: 0.21, source: "com.apple.Health")
        #expect(try await store.upsertBodyMeasurements([first]) == 1)
        #expect(try await store.upsertBodyMeasurements([again]) == 0)
        let rows = try await store.bodyMeasurements(from: when.addingTimeInterval(-60), to: when.addingTimeInterval(60))
        #expect(rows.count == 1)
        #expect(rows.first?.bodyFat == 0.21)
        #expect(rows.first?.id == first.id)

        try await store.deleteBodyMeasurements(hkUUIDs: [hk])
        #expect(try await store.bodyMeasurements(from: when.addingTimeInterval(-60), to: when.addingTimeInterval(60)).isEmpty)
    }

    @Test("导入 HealthKit 训练：按时间对账，再次导入已知，无匹配则占位")
    func markWorkoutImportedReconciles() async throws {
        let store = try makeStore()
        let start = Self.day.date(atHour: 19, calendar: Self.calendar)
        let local = LoggedSession(start: start, end: start.addingTimeInterval(3000), origin: .phone)
        try await store.upsertLoggedSession(local)

        let matching = ImportedWorkout(hkUUID: UUID(), start: start.addingTimeInterval(45), end: start.addingTimeInterval(3100), activityTypeRawValue: 50, effortScore: 6)
        let outcome = try await store.markWorkoutImported(matching, now: start.addingTimeInterval(4000))
        #expect(outcome == .linkedToSession(local.id))
        let linked = try await store.loggedSession(id: local.id)
        #expect(linked?.hkWorkoutUUID == matching.hkUUID)
        #expect(linked?.effortScore == 6)

        #expect(try await store.markWorkoutImported(matching, now: start.addingTimeInterval(5000)) == .alreadyKnown)
        #expect(try await store.importedWorkout(hkUUID: matching.hkUUID)?.setmioSessionID == local.id)

        let stranger = ImportedWorkout(hkUUID: UUID(), start: start.addingTimeInterval(-86_400), end: start.addingTimeInterval(-82_800), activityTypeRawValue: 50)
        let placeholder = try await store.markWorkoutImported(stranger, now: start)
        guard case .createdPlaceholder(let placeholderID) = placeholder else {
            Issue.record("expected createdPlaceholder, got \(placeholder)")
            return
        }
        let created = try await store.loggedSession(id: placeholderID)
        #expect(created?.origin == .importedFromHealth)
        #expect(created?.hkWorkoutUUID == stranger.hkUUID)
    }

    @Test("饮食记录：条目级联、顺序保持、删除生效")
    func foodEntriesRoundTrip() async throws {
        let store = try makeStore()
        let time = Self.day.date(atHour: 12, minute: 10, calendar: Self.calendar)
        var entry = FoodEntry(
            day: Self.day,
            time: time,
            meal: .lunch,
            items: [
                FoodItem(nameZH: "米饭", portionGrams: 150, portionLabel: "1碗", facts: NutritionFacts(kcal: 174, carbs: 39), source: .photoLLM, originalKcalEstimate: 190),
                FoodItem(nameZH: "鸡胸肉", portionGrams: 120, facts: NutritionFacts(kcal: 198, protein: 37), kcalLow: 170, kcalHigh: 230, confidence: 0.8, source: .photoLLM),
            ],
            photoLocalPath: "photos/lunch.jpg",
            confirmed: false
        )
        try await store.upsertFoodEntry(entry)
        #expect(try await store.foodEntries(for: Self.day) == [entry])

        entry.items.removeFirst()
        entry.confirmed = true
        try await store.upsertFoodEntry(entry)
        let fetched = try await store.foodEntries(for: Self.day)
        #expect(fetched == [entry])
        #expect(fetched.first?.items.count == 1)

        try await store.deleteFoodEntry(id: entry.id)
        #expect(try await store.foodEntries(for: Self.day).isEmpty)
    }

    @Test("用药：药物、剂量、副作用、笔与计划往返，删除药物级联")
    func medicationRoundTrip() async throws {
        let store = try makeStore()
        let medication = Medication(drug: .tirzepatide, form: .penMultiDose(inUseDays: 30), startedOn: Self.day.adding(days: -40, calendar: Self.calendar))
        try await store.upsertMedication(medication)
        #expect(try await store.medications(activeOnly: true) == [medication])

        let pen = PenInventory(medicationID: medication.id, strengthMg: 5, dosesRemaining: 3, inUseExpiry: Self.day.date(atHour: 9, calendar: Self.calendar))
        try await store.upsertPen(pen)
        let dose = DoseLog(medicationID: medication.id, takenAt: Self.day.adding(days: -7, calendar: Self.calendar).date(atHour: 9, calendar: Self.calendar), doseMg: 5, site: .abdomenLeft, penID: pen.id, hkDoseEventUUID: UUID())
        try await store.upsertDoseLog(dose)
        try await store.upsertDoseLog(dose)
        #expect(try await store.doseLogs(medicationID: medication.id) == [dose])

        let sideEffect = SideEffectLog(medicationID: medication.id, day: Self.day.adding(days: -6, calendar: Self.calendar), kind: .nausea, severity: 1)
        try await store.upsertSideEffect(sideEffect)
        #expect(try await store.sideEffects(medicationID: medication.id, from: Self.day.adding(days: -14, calendar: Self.calendar), to: Self.day) == [sideEffect])

        let plan = GLP1Plan(medicationID: medication.id, drug: .tirzepatide, labelVersion: 1, steps: [GLP1PlanStep(doseMg: 2.5, minDays: 28, startedOn: medication.startedOn), GLP1PlanStep(doseMg: 5, minDays: 28)], currentStepIndex: 1, injectionWeekday: 2, reminderHour: 9)
        try await store.upsertGLP1Plan(plan)
        #expect(try await store.glp1Plan(medicationID: medication.id) == plan)
        #expect(try await store.pens(medicationID: medication.id) == [pen])

        try await store.deleteMedication(id: medication.id)
        #expect(try await store.medications().isEmpty)
        #expect(try await store.doseLogs(medicationID: medication.id).isEmpty)
        #expect(try await store.pens(medicationID: medication.id).isEmpty)
        #expect(try await store.glp1Plan(medicationID: medication.id) == nil)
    }

    @Test("档案与设置为单例行")
    func profileAndSettingsSingletons() async throws {
        let store = try makeStore()
        #expect(try await store.profile() == nil)
        #expect(try await store.settings() == .default)

        let profile = UserProfile(sex: .male, heightCm: 178, birthDate: DayKey(year: 1990, month: 5, day: 1), goalWeight: 72, proteinStandard: .perKgLeanMass(gPerKg: 2.2), activityFactor: 1.5, glp1Mode: true)
        try await store.saveProfile(profile)
        var updatedProfile = profile
        updatedProfile.goalWeight = 70
        try await store.saveProfile(updatedProfile)
        #expect(try await store.profile() == updatedProfile)

        var settings = Settings.default
        settings.rhrFreezeHour = 11
        settings.defaultRestSeconds = [.compound: 150, .isolation: 75]
        try await store.saveSettings(settings)
        try await store.saveSettings(settings)
        #expect(try await store.settings() == settings)
    }
}
#endif
