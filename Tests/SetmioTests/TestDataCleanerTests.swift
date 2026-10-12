import Foundation
import Testing
import SetmioCore
import SetmioData
@testable import Setmio

/// Records what it was asked to delete. UUIDs in `refused` stay in Health and are reported as failed.
actor FakeWorkoutDeleter: HealthWorkoutDeleting {
    private(set) var requests: [[UUID]] = []
    private let refused: Set<UUID>

    init(refusing refused: Set<UUID> = []) {
        self.refused = refused
    }

    func deleteWorkouts(uuids: [UUID]) async -> (deleted: Int, failed: Int) {
        requests.append(uuids)
        let deleted = uuids.filter { !refused.contains($0) }.count
        return (deleted, uuids.count - deleted)
    }
}

@Suite("TestDataCleaner · 只删除标记的训练", .serialized)
struct TestDataCleanerTests {
    private let calendar = Calendar.setmioDefault
    private let day = DayKey(year: 2026, month: 10, day: 5)

    private struct Fixture {
        let store: SetmioStore
        let registry: TestDataRegistry
        let deleter: FakeWorkoutDeleter
        let cleaner: TestDataCleaner
    }

    private func makeFixture(refusing refused: Set<UUID> = []) async throws -> Fixture {
        let container = try ModelContainerFactory.make(inMemory: true)
        let store = SetmioStore(modelContainer: container)
        let registry = TestDataRegistry(
            fileURL: FileManager.default.temporaryDirectory
                .appending(path: "cleaner-test-\(UUID().uuidString)", directoryHint: .isDirectory)
                .appending(path: "test-data.json", directoryHint: .notDirectory)
        )
        let deleter = FakeWorkoutDeleter(refusing: refused)
        return Fixture(
            store: store,
            registry: registry,
            deleter: deleter,
            cleaner: TestDataCleaner(store: store, registry: registry, health: deleter)
        )
    }

    /// A session at `hour` on `day` with `setCount` working sets. Written to the store and returned.
    @discardableResult
    private func addSession(
        _ f: Fixture,
        hour: Int,
        setCount: Int,
        origin: SessionOrigin = .phone,
        hkWorkoutUUID: UUID? = nil,
        finished: Bool = true,
        tagged: Bool = false
    ) async throws -> LoggedSession {
        let start = day.date(atHour: hour, calendar: calendar)
        var session = LoggedSession(
            start: start,
            end: finished ? start.addingTimeInterval(3600) : nil,
            hkWorkoutUUID: hkWorkoutUUID,
            origin: origin
        )
        session.sets = (0..<setCount).map { index in
            LoggedSet(sessionID: session.id, exerciseID: ID<Exercise>(), index: index, load: 40, reps: 8, rir: 2,
                      completedAt: start.addingTimeInterval(Double(index) * 200))
        }
        try await f.store.upsertLoggedSession(session)
        if tagged {
            try await f.registry.mark(session.id)
        }
        return session
    }

    @Test("只删除标记的训练及其组；未标记的训练和它们的组保留")
    func onlyTaggedSessionsAreDeleted() async throws {
        let f = try await makeFixture()
        let taggedA = try await addSession(f, hour: 8, setCount: 2, tagged: true)
        let taggedB = try await addSession(f, hour: 10, setCount: 1, tagged: true)
        let untagged = try await addSession(f, hour: 18, setCount: 3)

        let report = try await f.cleaner.deleteAll(watchMirroring: false)

        #expect(report.sessionsDeleted == 2)
        #expect(report.setsDeleted == 3)
        #expect(try await f.store.loggedSession(id: taggedA.id) == nil)
        #expect(try await f.store.loggedSession(id: taggedB.id) == nil)
        let kept = try #require(try await f.store.loggedSession(id: untagged.id))
        #expect(kept.sets.count == 3)
    }

    @Test("「健康」只收到被删除的标记训练中、由 Setmio 写入的 HKWorkout")
    func healthDeleterGetsOnlyTaggedSetmioWorkouts() async throws {
        let f = try await makeFixture()
        let phoneWritten = UUID()
        let watchWritten = UUID()
        let importedFromOtherApp = UUID()
        let untaggedWritten = UUID()
        try await addSession(f, hour: 8, setCount: 1, hkWorkoutUUID: phoneWritten, tagged: true)
        try await addSession(f, hour: 10, setCount: 1, origin: .watch, hkWorkoutUUID: watchWritten, tagged: true)
        try await addSession(f, hour: 12, setCount: 1, origin: .importedFromHealth, hkWorkoutUUID: importedFromOtherApp, tagged: true)
        try await addSession(f, hour: 18, setCount: 1, hkWorkoutUUID: untaggedWritten)

        let report = try await f.cleaner.deleteAll(watchMirroring: false)

        let requests = await f.deleter.requests
        #expect(requests.count == 1)
        #expect(Set(requests.flatMap { $0 }) == [phoneWritten, watchWritten])
        #expect(report.healthDeleted == 2)
        #expect(report.healthFailed == 0)
    }

    @Test("有进行中的训练（手机未结束 / 手表镜像中）时拒绝删除，且什么都不删")
    func refusesWhileWorkoutIsActive() async throws {
        let f = try await makeFixture()
        let tagged = try await addSession(f, hour: 8, setCount: 2, hkWorkoutUUID: UUID(), tagged: true)
        try await addSession(f, hour: 19, setCount: 1, finished: false)

        await #expect(throws: TestDataError.workoutInProgress) {
            try await f.cleaner.deleteAll(watchMirroring: false)
        }
        #expect(try await f.store.loggedSession(id: tagged.id) != nil)
        #expect(await f.deleter.requests.isEmpty)

        let idle = try await makeFixture()
        try await addSession(idle, hour: 8, setCount: 1, tagged: true)
        await #expect(throws: TestDataError.workoutInProgress) {
            try await idle.cleaner.deleteAll(watchMirroring: true)
        }
        #expect(try await idle.cleaner.hasActiveWorkout(watchMirroring: true))
        #expect(try await idle.cleaner.hasActiveWorkout(watchMirroring: false) == false)
    }

    @Test("报告的数字：删除的训练、组，以及「健康」中成功与失败的条数")
    func reportCountsAreCorrect() async throws {
        let refusedWorkout = UUID()
        let f = try await makeFixture(refusing: [refusedWorkout])
        try await addSession(f, hour: 8, setCount: 2, hkWorkoutUUID: UUID(), tagged: true)
        try await addSession(f, hour: 10, setCount: 1, origin: .watch, hkWorkoutUUID: refusedWorkout, tagged: true)

        let report = try await f.cleaner.deleteAll(watchMirroring: false)

        #expect(report == TestDataDeletionReport(sessionsDeleted: 2, setsDeleted: 3, healthDeleted: 1, healthFailed: 1))
    }

    @Test("第二次删除什么也不做，也不再调用「健康」")
    func secondRunDeletesNothing() async throws {
        let f = try await makeFixture()
        try await addSession(f, hour: 8, setCount: 2, hkWorkoutUUID: UUID(), tagged: true)
        _ = try await f.cleaner.deleteAll(watchMirroring: false)

        let second = try await f.cleaner.deleteAll(watchMirroring: false)

        #expect(second == TestDataDeletionReport(sessionsDeleted: 0, setsDeleted: 0, healthDeleted: 0, healthFailed: 0))
        #expect(await f.deleter.requests.count == 1)
    }

    @Test("没有任何标记时删除什么也不做，未标记的训练保持不变")
    func nothingTaggedNothingDeleted() async throws {
        let f = try await makeFixture()
        let untagged = try await addSession(f, hour: 8, setCount: 2, hkWorkoutUUID: UUID())

        let report = try await f.cleaner.deleteAll(watchMirroring: false)

        #expect(report == TestDataDeletionReport(sessionsDeleted: 0, setsDeleted: 0, healthDeleted: 0, healthFailed: 0))
        #expect(try await f.store.loggedSession(id: untagged.id) != nil)
        #expect(await f.deleter.requests.isEmpty)
    }

    @Test("预览只统计标记的训练：数量、组数、可删除的「健康」训练、日期范围")
    func previewCountsOnlyTagged() async throws {
        let f = try await makeFixture()
        try await addSession(f, hour: 8, setCount: 2, hkWorkoutUUID: UUID(), tagged: true)
        try await addSession(f, hour: 10, setCount: 3, origin: .importedFromHealth, hkWorkoutUUID: UUID(), tagged: true)
        try await addSession(f, hour: 18, setCount: 9, hkWorkoutUUID: UUID())

        let preview = try await f.cleaner.preview()

        #expect(preview.sessionCount == 2)
        #expect(preview.setCount == 5)
        #expect(preview.healthWorkoutCount == 1, "imported-from-Health workouts were not written by Setmio")
        #expect(preview.oldest == day.date(atHour: 8, calendar: calendar))
        #expect(preview.newest == day.date(atHour: 10, calendar: calendar))
    }

    @Test("标记现有全部训练：返回数量与日期范围，之后可以整体删除")
    func markAllExistingThenDelete() async throws {
        let f = try await makeFixture()
        try await addSession(f, hour: 8, setCount: 2)
        let later = day.adding(days: 3, calendar: calendar)
        let laterStart = later.date(atHour: 18, calendar: calendar)
        try await f.store.upsertLoggedSession(LoggedSession(start: laterStart, end: laterStart.addingTimeInterval(3600), origin: .phone))

        let history = try await f.cleaner.history()
        #expect(history.sessionCount == 2)
        #expect(history.oldest == day.date(atHour: 8, calendar: calendar))
        #expect(history.newest == laterStart)

        #expect(try await f.cleaner.markAllExistingAsTest() == 2)
        #expect(try await f.cleaner.preview().sessionCount == 2)

        let report = try await f.cleaner.deleteAll(watchMirroring: false)
        #expect(report.sessionsDeleted == 2)
        #expect(try await f.store.loggedSessions(in: Date.distantPast...Date.distantFuture).isEmpty)
    }
}
