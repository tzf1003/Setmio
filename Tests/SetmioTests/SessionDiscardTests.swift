import Foundation
import Testing
import SetmioCore
import SetmioData

/// 放弃训练 on the phone: a session the watch abandoned is deleted with its sets, so the progression plan never sees them.
@Suite("放弃的训练在 iPhone 上删除")
struct SessionDiscardTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("删除会话时一并删除它的组，其他会话的组保留")
    func deletingSessionDeletesItsSets() async throws {
        let store = SetmioStore(modelContainer: try ModelContainerFactory.make(inMemory: true))
        let exerciseID = SetmioCore.ID<Exercise>()

        var abandoned = LoggedSession(start: start, origin: .watch)
        abandoned.sets = (0..<3).map { index in
            LoggedSet(sessionID: abandoned.id, exerciseID: exerciseID, index: index, load: 60, reps: 8, rir: 2,
                      completedAt: start.addingTimeInterval(Double(index) * 180))
        }
        var kept = LoggedSession(start: start.addingTimeInterval(7200), origin: .watch)
        let keptSet = LoggedSet(sessionID: kept.id, exerciseID: exerciseID, index: 0, load: 70, reps: 5, rir: 1,
                                completedAt: start.addingTimeInterval(7200))
        kept.sets = [keptSet]
        try await store.upsertLoggedSession(abandoned)
        try await store.upsertLoggedSession(kept)
        #expect(try await store.recentSets(exerciseID: exerciseID, limit: 10).count == 4)

        try await store.deleteLoggedSession(id: abandoned.id)

        #expect(try await store.loggedSession(id: abandoned.id) == nil)
        #expect(try await store.recentSets(exerciseID: exerciseID, limit: 10).map(\.id) == [keptSet.id])
        #expect(try await store.loggedSessions(limit: 10).map(\.id) == [kept.id])
    }

    @Test("重发的放弃（会话已不存在）什么也不改")
    func repeatedDiscardIsHarmless() async throws {
        let store = SetmioStore(modelContainer: try ModelContainerFactory.make(inMemory: true))
        let session = LoggedSession(start: start, origin: .watch)
        try await store.upsertLoggedSession(session)

        try await store.deleteLoggedSession(id: session.id)
        try await store.deleteLoggedSession(id: session.id)
        try await store.deleteLoggedSession(id: SetmioCore.ID<LoggedSession>())

        #expect(try await store.loggedSessions(limit: 10).isEmpty)
    }
}
