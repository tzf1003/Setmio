import Foundation
import Testing
import SwiftData
import SetmioCore
import SetmioData
import SetmioHealth
import SetmioHealthTesting
@testable import Setmio

/// End-to-end: 60 days of demo HealthKit data → importer → sink → store → daily aggregation → readiness.
@Suite("HealthSyncService 同步", .serialized)
struct HealthSyncServiceTests {
    private func makeAnchorStore() -> AnchorStore {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "anchors-\(UUID().uuidString).json", directoryHint: .notDirectory)
        return AnchorStore(fileURL: url)
    }

    @Test("syncToday 产生 ≥14 天每日指标和今日评分")
    @MainActor
    func syncTodayProducesMetricsAndReadiness() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let store = SetmioStore(modelContainer: container)
        let calendar = Calendar.setmioDefault
        let today = DayKey(year: 2026, month: 10, day: 9)
        let now = today.date(atHour: 11, calendar: calendar)
        let source = FakeHealthSampleSource.demo(endingOn: today, calendar: calendar)

        let service = HealthSyncService(store: store, source: source, anchors: makeAnchorStore())
        await service.syncToday(now: now)

        #expect(service.lastError == nil, "sync error: \(service.lastError ?? "")")
        let report = try #require(service.lastReport)
        #expect(report.succeeded)
        #expect(report.totalImported > 0)

        let rows = try await store.dailyMetrics(from: today.adding(days: -59, calendar: calendar), to: today)
        #expect(rows.count >= 14)
        #expect(rows.filter { $0.hrvSDNN != nil }.count >= 14)

        let readiness = try #require(try await store.readiness(for: today))
        #expect((0...100).contains(readiness.score))
        #expect(readiness.baselineDays >= 14)
        #expect(service.readiness?.score == readiness)
    }

    @Test("体重样本进入 BodyMeasurement，并按 hkUUID 去重")
    @MainActor
    func bodyMassIsUpsertedOnce() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let store = SetmioStore(modelContainer: container)
        let calendar = Calendar.setmioDefault
        let today = DayKey(year: 2026, month: 10, day: 9)
        let source = FakeHealthSampleSource.demo(endingOn: today, calendar: calendar)
        let service = HealthSyncService(store: store, source: source, anchors: makeAnchorStore())

        await service.syncToday(now: today.date(atHour: 11, calendar: calendar))
        let range = today.adding(days: -59, calendar: calendar).startOfDay(calendar: calendar)...today.adding(days: 1, calendar: calendar).startOfDay(calendar: calendar)
        let first = try await store.bodyMeasurements(from: range.lowerBound, to: range.upperBound)
        #expect(first.contains { $0.weight != nil })

        // A second sync (anchors already advanced) must not duplicate rows; a reset re-import must not either.
        await service.syncToday(now: today.date(atHour: 12, calendar: calendar))
        await service.resetAndReimport(now: today.date(atHour: 13, calendar: calendar))
        let again = try await store.bodyMeasurements(from: range.lowerBound, to: range.upperBound)
        #expect(again.count == first.count)
    }
}
