import Foundation
import Testing
@testable import Setmio

@Suite("SyncFreshness 数据是否过期")
struct SyncFreshnessTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let freshness = SyncFreshness()

    @Test("从未同步过 → 过期")
    func neverSynced() {
        #expect(freshness.isStale(lastSyncedAt: nil, now: now))
    }

    @Test("10 分钟内不算过期，超过才算（边界：恰好 10 分钟不算）")
    func boundary() {
        #expect(!freshness.isStale(lastSyncedAt: now.addingTimeInterval(-60), now: now))
        #expect(!freshness.isStale(lastSyncedAt: now.addingTimeInterval(-600), now: now))
        #expect(freshness.isStale(lastSyncedAt: now.addingTimeInterval(-601), now: now))
        #expect(freshness.isStale(lastSyncedAt: now.addingTimeInterval(-3 * 3600), now: now))
    }

    @Test("上次同步时间在未来（时钟被回拨）→ 过期")
    func clockWentBackwards() {
        #expect(freshness.isStale(lastSyncedAt: now.addingTimeInterval(120), now: now))
    }

    @Test("阈值可调")
    func customThreshold() {
        let strict = SyncFreshness(maxAge: 30)
        #expect(strict.isStale(lastSyncedAt: now.addingTimeInterval(-31), now: now))
        #expect(!strict.isStale(lastSyncedAt: now.addingTimeInterval(-29), now: now))
    }
}
