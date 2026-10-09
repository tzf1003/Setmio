import Foundation
import SetmioCore
import SetmioData

/// Turns the active mesocycle into today's `PlannedSession`: picks the program day, asks `ProgressionEngine`
/// for every prescription, stores the plan once per (mesocycle, day) and returns a readiness-modulated copy for
/// display and for the watch. The stored plan is never modulated (方案.md §7.3: 只影响当天副本).
struct TrainingPlanner: Sendable {
    let store: SetmioStore
    let engine: ProgressionEngine
    let modulator: ReadinessModulator

    /// Sets history passed to the engine per exercise (≈ 10 sessions of 4–5 sets).
    static let historySetLimit = 60
    /// Recent sessions whose feedback the engine sees.
    static let feedbackSessionLimit = 5

    init(store: SetmioStore, engine: ProgressionEngine = ProgressionEngine(), modulator: ReadinessModulator = ReadinessModulator()) {
        self.store = store
        self.engine = engine
        self.modulator = modulator
    }

    /// Starts a new mesocycle from `program` (deactivating any other) and returns it.
    @discardableResult
    func startMesocycle(program: ProgramTemplate, startDay: DayKey) async throws -> Mesocycle {
        let working = max(1, program.mesocycleWeeks - 1)
        let mesocycle = Mesocycle(templateID: program.id, startDay: startDay, weeks: MesocycleWeek.defaultBlock(workingWeeks: working))
        try await store.upsertMesocycle(mesocycle)
        return mesocycle
    }

    /// The plan for `day` (nil without an active mesocycle), modulated by that day's readiness score.
    func plan(for day: DayKey, now: Date, calendar: Calendar) async throws -> PlannedSession? {
        guard var mesocycle = try await store.activeMesocycle(),
              let program = try await store.program(id: mesocycle.templateID),
              !program.days.isEmpty else {
            return nil
        }

        // Advance the week by calendar time; the deload week is the last one.
        let weekIndex = min(max(0, day.daysSince(mesocycle.startDay, calendar: calendar) / 7), mesocycle.weeks.count - 1)
        if weekIndex != mesocycle.currentWeekIndex {
            mesocycle.currentWeekIndex = weekIndex
            try await store.upsertMesocycle(mesocycle)
        }

        let base: PlannedSession
        if let stored = try await store.plannedSession(for: day, mesocycleID: mesocycle.id) {
            base = stored
        } else {
            base = try await buildPlan(day: day, mesocycle: mesocycle, program: program, calendar: calendar)
            try await store.upsertPlannedSession(base)
        }

        let readiness = try await store.readiness(for: day)
        var categories: [SetmioCore.ID<Exercise>: ExerciseCategory] = [:]
        var increments: [SetmioCore.ID<Exercise>: Kilograms] = [:]
        for planned in base.exercises {
            if let exercise = try await store.exercise(id: planned.exerciseID) {
                categories[exercise.id] = exercise.category
                increments[exercise.id] = exercise.loadIncrement
            }
        }
        return modulator.modulate(base, readiness: readiness, categories: categories, increments: increments)
    }

    /// Exercise names for a plan, for views that render it.
    func exerciseNames(for plan: PlannedSession) async throws -> [SetmioCore.ID<Exercise>: String] {
        var names: [SetmioCore.ID<Exercise>: String] = [:]
        for planned in plan.exercises {
            names[planned.exerciseID] = try await store.exercise(id: planned.exerciseID)?.nameZH ?? "未知动作"
        }
        return names
    }

    // MARK: Private

    private func buildPlan(day: DayKey, mesocycle: Mesocycle, program: ProgramTemplate, calendar: Calendar) async throws -> PlannedSession {
        // Program-day rotation: the number of sessions completed since the mesocycle started.
        let range = mesocycle.startDay.startOfDay(calendar: calendar)...day.startOfDay(calendar: calendar)
        let completed = try await store.loggedSessions(in: range).filter { $0.end != nil }
        let programDay = program.days[completed.count % program.days.count]

        let feedback = try await store.loggedSessions(limit: Self.feedbackSessionLimit).compactMap(\.feedback)
        let recentScores = try await store
            .readiness(from: day.adding(days: -5, calendar: calendar), to: day.adding(days: -1, calendar: calendar))
            .reversed()
            .map(\.score)
        let meso = MesocycleState(mesocycle: mesocycle)

        var exercises: [PlannedExercise] = []
        for prescription in programDay.prescriptions {
            guard let exercise = try await store.exercise(id: prescription.exerciseID) else { continue }
            let sets = try await store.recentSets(exerciseID: prescription.exerciseID, limit: Self.historySetLimit)
            let history = ExerciseHistory(sets: sets, feedback: feedback, recentReadinessScores: Array(recentScores))
            exercises.append(engine.plan(prescription: prescription, exercise: exercise, history: history, meso: meso))
        }
        return PlannedSession(mesocycleID: mesocycle.id, day: day, dayNameZH: programDay.nameZH, exercises: exercises)
    }
}
