import Foundation
import Testing
import SwiftData
import SetmioCore
import SetmioData
@testable import Setmio

/// Mesocycle start → today's plan → a logged session → the next day's plan moves by double progression.
@Suite("TrainingPlanner 训练闭环", .serialized)
struct TrainingPlannerTests {
    private let calendar = Calendar.setmioDefault
    private let day1 = DayKey(year: 2026, month: 10, day: 5)

    private func makeStore() async throws -> (SetmioStore, TrainingPlanner, ProgramTemplate) {
        let container = try ModelContainerFactory.make(inMemory: true)
        let store = SetmioStore(modelContainer: container)
        try await store.seedExercisesIfNeeded(from: SeedData.exercises())
        try await store.seedProgramsIfNeeded(from: SeedData.programs())
        let program = try #require(try await store.programs().first)
        return (store, TrainingPlanner(store: store), program)
    }

    @Test("没有进行中的周期时没有计划")
    func noMesocycleNoPlan() async throws {
        let (_, planner, _) = try await makeStore()
        let plan = try await planner.plan(for: day1, now: day1.date(atHour: 8, calendar: calendar), calendar: calendar)
        #expect(plan == nil)
    }

    @Test("首日计划：所有动作无目标重量（首次训练），并且只存一份")
    func firstDayPlan() async throws {
        let (store, planner, program) = try await makeStore()
        try await planner.startMesocycle(program: program, startDay: day1)
        let plan = try #require(try await planner.plan(for: day1, now: day1.date(atHour: 8, calendar: calendar), calendar: calendar))
        #expect(!plan.exercises.isEmpty)
        #expect(plan.exercises.allSatisfy { $0.sets.first?.targetLoad == nil })

        _ = try await planner.plan(for: day1, now: day1.date(atHour: 9, calendar: calendar), calendar: calendar)
        let stored = try await store.plannedSessions(from: day1, to: day1)
        #expect(stored.count == 1)
    }

    @Test("记完一次训练后，下次同动作的计划按双重渐进变化")
    func nextSessionProgresses() async throws {
        let (store, planner, program) = try await makeStore()
        try await planner.startMesocycle(program: program, startDay: day1)
        let plan1 = try #require(try await planner.plan(for: day1, now: day1.date(atHour: 8, calendar: calendar), calendar: calendar))
        let first = try #require(plan1.exercises.first)
        let prescription = try #require(program.days.first?.prescriptions.first { $0.exerciseID == first.exerciseID })

        // Log every planned set at the top of the rep range, 60 kg, with the target reserve.
        let start = day1.date(atHour: 18, calendar: calendar)
        var session = LoggedSession(plannedSessionID: plan1.id, start: start, origin: .phone)
        session.end = start.addingTimeInterval(3600)
        let sets = (0..<prescription.sets).map { index in
            LoggedSet(sessionID: session.id, exerciseID: first.exerciseID, index: index, load: 60, reps: prescription.repRange.upperBound,
                      rir: first.sets[0].targetRIR, completedAt: start.addingTimeInterval(Double(index) * 240))
        }
        session.sets = sets
        try await store.upsertLoggedSession(session)
        try await store.upsertLoggedSets(sets, into: session.id)

        // The planner rotates through the program days by finished sessions, so complete one full rotation
        // (the other days are empty finished sessions) before the same program day comes around again.
        for offset in 1..<program.days.count {
            let day = day1.adding(days: offset, calendar: calendar)
            let filler = day.date(atHour: 18, calendar: calendar)
            try await store.upsertLoggedSession(LoggedSession(start: filler, end: filler.addingTimeInterval(3600), origin: .phone))
        }

        let day2 = day1.adding(days: program.days.count, calendar: calendar)
        let plan2 = try #require(try await planner.plan(for: day2, now: day2.date(atHour: 8, calendar: calendar), calendar: calendar))
        #expect(plan2.dayNameZH == plan1.dayNameZH)
        let progressed = try #require(plan2.exercises.first { $0.exerciseID == first.exerciseID })
        let load = try #require(progressed.sets.first?.targetLoad)
        #expect(load > 60, "load should increase after topping the rep range, got \(load)")
        #expect(progressed.sets.first?.targetReps == prescription.repRange)
    }
}
