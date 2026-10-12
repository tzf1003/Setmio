import Foundation
import Testing
import SetmioCore
import SetmioData
@testable import Setmio

/// Sessions tagged as test data (device testing) must not change the plan: they are left out of load progression,
/// feedback and program-day rotation.
@Suite("TrainingPlanner 排除测试数据", .serialized)
struct TrainingPlannerTestDataTests {
    private let calendar = Calendar.setmioDefault
    private let day1 = DayKey(year: 2026, month: 10, day: 5)

    private struct Fixture {
        let store: SetmioStore
        let registry: TestDataRegistry
        let planner: TrainingPlanner
        let program: ProgramTemplate
    }

    private func makeFixture() async throws -> Fixture {
        let container = try ModelContainerFactory.make(inMemory: true)
        let store = SetmioStore(modelContainer: container)
        try await store.seedExercisesIfNeeded(from: SeedData.exercises())
        try await store.seedProgramsIfNeeded(from: SeedData.programs())
        let program = try #require(try await store.programs().first)
        let url = FileManager.default.temporaryDirectory
            .appending(path: "planner-test-data-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "test-data.json", directoryHint: .notDirectory)
        let registry = TestDataRegistry(fileURL: url)
        return Fixture(
            store: store,
            registry: registry,
            planner: TrainingPlanner(store: store, testData: registry),
            program: program
        )
    }

    /// Mesocycle from day 1, then one session that logs every planned set of the first exercise at the top of its
    /// rep range with 60 kg. The session is tagged when `tagged` is true.
    ///
    /// Both variants count `program.days.count` finished sessions before the next plan, so the next plan is for the
    /// same program day as the first one. A tagged session is not counted, so the tagged variant adds one untagged
    /// morning session in its place.
    private func logTopSetAndPlanNextRotation(_ f: Fixture, tagged: Bool) async throws -> (first: PlannedSession, next: PlannedSession, exerciseID: SetmioCore.ID<Exercise>, repRange: ClosedRange<Int>) {
        try await f.planner.startMesocycle(program: f.program, startDay: day1)
        let plan1 = try #require(try await f.planner.plan(for: day1, now: day1.date(atHour: 8, calendar: calendar), calendar: calendar))
        let first = try #require(plan1.exercises.first)
        let prescription = try #require(f.program.days.first?.prescriptions.first { $0.exerciseID == first.exerciseID })

        let start = day1.date(atHour: 18, calendar: calendar)
        var session = LoggedSession(plannedSessionID: plan1.id, start: start, origin: .phone)
        session.end = start.addingTimeInterval(3600)
        session.sets = (0..<prescription.sets).map { index in
            LoggedSet(sessionID: session.id, exerciseID: first.exerciseID, index: index, load: 60, reps: prescription.repRange.upperBound,
                      rir: first.sets[0].targetRIR, completedAt: start.addingTimeInterval(Double(index) * 240))
        }
        try await f.store.upsertLoggedSession(session)
        try await f.store.upsertLoggedSets(session.sets, into: session.id)
        if tagged {
            try await f.registry.mark(session.id)
        }

        // Finished sessions on the other days of the rotation (untagged).
        for offset in 1..<f.program.days.count {
            let filler = day1.adding(days: offset, calendar: calendar).date(atHour: 18, calendar: calendar)
            try await f.store.upsertLoggedSession(LoggedSession(start: filler, end: filler.addingTimeInterval(3600), origin: .phone))
        }
        if tagged {
            let morning = day1.date(atHour: 8, calendar: calendar)
            try await f.store.upsertLoggedSession(LoggedSession(start: morning, end: morning.addingTimeInterval(1800), origin: .phone))
        }

        let next = day1.adding(days: f.program.days.count, calendar: calendar)
        let plan2 = try #require(try await f.planner.plan(for: next, now: next.date(atHour: 8, calendar: calendar), calendar: calendar))
        return (plan1, plan2, first.exerciseID, prescription.repRange)
    }

    @Test("对照：未标记的顶组记录会抬高下次重量")
    func untaggedTopSetRaisesLoad() async throws {
        let f = try await makeFixture()
        let result = try await logTopSetAndPlanNextRotation(f, tagged: false)
        #expect(result.next.dayNameZH == result.first.dayNameZH)
        let progressed = try #require(result.next.exercises.first { $0.exerciseID == result.exerciseID })
        let load = try #require(progressed.sets.first?.targetLoad)
        #expect(load > 60, "load should increase after topping the rep range, got \(load)")
    }

    @Test("测试数据里顶组的记录不会抬高下次重量")
    func taggedTopSetDoesNotRaiseLoad() async throws {
        let f = try await makeFixture()
        let result = try await logTopSetAndPlanNextRotation(f, tagged: true)
        #expect(result.next.dayNameZH == result.first.dayNameZH)
        let progressed = try #require(result.next.exercises.first { $0.exerciseID == result.exerciseID })
        #expect(progressed.sets.first?.targetLoad == nil, "a tagged session must not feed progression")
        #expect(progressed.sets.first?.targetReps == result.repRange)
    }

    @Test("测试训练不计入训练日轮换；取消标记后计入")
    func taggedSessionDoesNotAdvanceRotation() async throws {
        let f = try await makeFixture()
        try await f.planner.startMesocycle(program: f.program, startDay: day1)
        _ = try #require(try await f.planner.plan(for: day1, now: day1.date(atHour: 8, calendar: calendar), calendar: calendar))
        try #require(f.program.days.count >= 2)

        let start = day1.date(atHour: 18, calendar: calendar)
        let finished = LoggedSession(start: start, end: start.addingTimeInterval(3600), origin: .phone)
        try await f.store.upsertLoggedSession(finished)
        try await f.registry.mark(finished.id)

        // Tagged: the only finished session is test data, so the rotation is still on the first program day.
        let next = day1.adding(days: 1, calendar: calendar)
        let taggedPlan = try #require(try await f.planner.plan(for: next, now: next.date(atHour: 8, calendar: calendar), calendar: calendar))
        #expect(taggedPlan.dayNameZH == f.program.days[0].nameZH, "a tagged session must not move the rotation")

        // Untagged: a day with no stored plan yet, so the session counts and the rotation moves on.
        try await f.registry.forget([finished.id])
        let later = day1.adding(days: 2, calendar: calendar)
        let untaggedPlan = try #require(try await f.planner.plan(for: later, now: later.date(atHour: 8, calendar: calendar), calendar: calendar))
        #expect(untaggedPlan.dayNameZH == f.program.days[1].nameZH, "an untagged finished session advances the rotation")
    }

    @Test("已存的计划保持不变，直到丢弃后按当前历史重建")
    func discardedPlanIsRebuiltFromCurrentHistory() async throws {
        let f = try await makeFixture()
        try await f.planner.startMesocycle(program: f.program, startDay: day1)
        let day2 = day1.adding(days: 1, calendar: calendar)
        let stored = try #require(try await f.planner.plan(for: day2, now: day2.date(atHour: 8, calendar: calendar), calendar: calendar))
        #expect(stored.dayNameZH == f.program.days[0].nameZH)

        // A finished session on day 1 appears after day 2's plan was stored.
        let start = day1.date(atHour: 18, calendar: calendar)
        try await f.store.upsertLoggedSession(LoggedSession(start: start, end: start.addingTimeInterval(3600), origin: .phone))
        let kept = try #require(try await f.planner.plan(for: day2, now: day2.date(atHour: 9, calendar: calendar), calendar: calendar))
        #expect(kept.dayNameZH == stored.dayNameZH, "the stored plan is not rebuilt by itself")

        #expect(try await f.planner.discardStoredPlan(for: day2))
        #expect(try await f.planner.discardStoredPlan(for: day2) == false, "nothing is left to discard the second time")
        let rebuilt = try #require(try await f.planner.plan(for: day2, now: day2.date(atHour: 10, calendar: calendar), calendar: calendar))
        #expect(rebuilt.dayNameZH == f.program.days[1].nameZH)
    }
}

@Suite("TrainingPlanner 取最近的非测试记录")
struct TrainingPlannerFirstUntaggedTests {
    @Test("跳过标记的记录；窗口不够时逐步加大")
    func skipsTaggedAndWidensWindow() async throws {
        let newestFirst = Array(0..<10)
        let kept = try await TrainingPlanner.firstUntagged(3, fetch: { limit in Array(newestFirst.prefix(limit)) }, isTagged: { $0 % 2 == 0 })
        #expect(kept == [1, 3, 5])
    }

    @Test("存储里的记录不够时返回剩下的全部未标记记录")
    func returnsWhateverExists() async throws {
        let newestFirst = Array(0..<10)
        let kept = try await TrainingPlanner.firstUntagged(5, fetch: { limit in Array(newestFirst.prefix(limit)) }, isTagged: { $0 < 9 })
        #expect(kept == [9])
    }

    @Test("没有标记时只取一次")
    func noTagsFetchesOnce() async throws {
        let newestFirst = Array(0..<10)
        var calls = 0
        let kept = try await TrainingPlanner.firstUntagged(4, fetch: { limit in
            calls += 1
            return Array(newestFirst.prefix(limit))
        }, isTagged: { _ in false })
        #expect(kept == [0, 1, 2, 3])
        #expect(calls == 1)
    }
}
