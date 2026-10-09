import Foundation
import Observation
import SetmioCore
import SetmioHealth
import SetmioData
import HealthKit

// MARK: - Sink (background actor)

/// Writes imported pages into `SetmioStore`. Body composition becomes `BodyMeasurement` rows (deduplicated by
/// `hkUUID`, so re-delivery after a crash is harmless), strength workouts are reconciled with local sessions,
/// and every other kind only updates a small per-kind cache (the samples themselves are re-read from the
/// source by `DailyMetricsSource` when the day is aggregated — HealthKit stays the source of truth).
actor HealthStoreSink: HealthSampleSink {
    /// `HKWorkoutActivityType` raw values the app treats as strength sessions.
    static let strengthActivityTypes: Set<Int> = [
        Int(HKWorkoutActivityType.functionalStrengthTraining.rawValue),
        Int(HKWorkoutActivityType.traditionalStrengthTraining.rawValue),
    ]

    struct Snapshot: Sendable, Equatable {
        var ingestedCounts: [HealthMetricKind: Int] = [:]
        var latestSampleStart: [HealthMetricKind: Date] = [:]
    }

    private let store: SetmioStore
    private var snapshot = Snapshot()

    init(store: SetmioStore) {
        self.store = store
    }

    func ingest(_ batch: AnchoredBatch, kind: HealthMetricKind) async throws {
        switch kind {
        case .bodyMass, .bodyFatPercentage, .leanBodyMass:
            let measurements = batch.samples.map { sample in
                BodyMeasurement(
                    hkUUID: sample.hkUUID,
                    date: sample.start,
                    weight: kind == .bodyMass ? sample.value : nil,
                    bodyFat: kind == .bodyFatPercentage ? sample.value : nil,
                    leanMass: kind == .leanBodyMass ? sample.value : nil,
                    source: sample.sourceBundleID ?? "healthkit"
                )
            }
            if !measurements.isEmpty {
                try await store.upsertBodyMeasurements(measurements)
            }
            if !batch.deletedUUIDs.isEmpty {
                try await store.deleteBodyMeasurements(hkUUIDs: batch.deletedUUIDs)
            }

        case .workout:
            for sample in batch.samples where Self.strengthActivityTypes.contains(sample.categoryValue ?? -1) {
                let workout = ImportedWorkout(
                    hkUUID: sample.hkUUID,
                    start: sample.start,
                    end: sample.end,
                    activityTypeRawValue: sample.categoryValue ?? 0,
                    sourceBundleID: sample.sourceBundleID
                )
                _ = try await store.markWorkoutImported(workout)
            }

        default:
            break
        }

        snapshot.ingestedCounts[kind, default: 0] += batch.samples.count
        if let latest = batch.samples.map(\.start).max() {
            snapshot.latestSampleStart[kind] = max(snapshot.latestSampleStart[kind] ?? .distantPast, latest)
        }
    }

    func currentSnapshot() -> Snapshot { snapshot }
}

// MARK: - Service (main actor, observable)

/// The one place Health → Core engines → Data are wired together (ARCHITECTURE.md §1).
///
/// `ingest` is `nonisolated` and forwards straight to the background sink so a 500-sample page never touches
/// the main actor; only the small UI-facing state (`lastReport`, `readiness`, errors) lives here.
@MainActor
@Observable
final class HealthSyncService: HealthSampleSink {
    /// Days of history kept aggregated (the readiness baseline window).
    nonisolated static let historyDays = 60
    /// Days (counting back from today) that are always re-aggregated: today is unfinished and last night's
    /// sleep/HRV can land late.
    nonisolated static let alwaysRecomputeDays = 2

    nonisolated let store: SetmioStore
    nonisolated let source: any HealthSampleSource
    nonisolated let sink: HealthStoreSink
    nonisolated let importer: HealthSampleImporter
    nonisolated let metricsSource: DailyMetricsSource
    nonisolated let calculator: ReadinessCalculator

    private(set) var lastReport: ImportReport?
    private(set) var lastError: String?
    private(set) var isSyncing = false
    /// Live progress of the import phase of `syncToday` (nil outside a sync); drives the progress bar.
    private(set) var importProgress: ImportProgress?
    private(set) var lastSyncedAt: Date?
    private(set) var readiness: ReadinessResult?
    private(set) var todayMetrics: DailyMetrics?
    private(set) var ingestSnapshot = HealthStoreSink.Snapshot()

    init(store: SetmioStore, source: any HealthSampleSource, anchors: AnchorStore, calculator: ReadinessCalculator = ReadinessCalculator()) {
        self.store = store
        self.source = source
        self.calculator = calculator
        let sink = HealthStoreSink(store: store)
        self.sink = sink
        self.importer = HealthSampleImporter(source: source, anchors: anchors, sink: sink)
        self.metricsSource = DailyMetricsSource(source: source)
    }

    nonisolated func ingest(_ batch: AnchoredBatch, kind: HealthMetricKind) async throws {
        try await sink.ingest(batch, kind: kind)
    }

    // MARK: Sync

    /// Imports every MVP kind, aggregates the days of the last 60 that are missing (or recent), then computes
    /// and stores today's readiness. Never throws; failures land in `lastError` / `lastReport.errors`.
    func syncToday(now: Date = Date()) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let settings = try await store.settings()
            // The importer works on its own actor; progress hops back here so only a tiny value touches the main actor.
            let report = await importer.importAll(kinds: HealthMetricKind.mvp) { [weak self] progress in
                Task { @MainActor in self?.importProgress = progress }
            }
            importProgress = nil
            lastReport = report
            let outcome = try await runOffMain { service in
                let today = try await service.rebuildDailyMetrics(settings: settings, now: now)
                return (today, try await service.computeReadiness(settings: settings, now: now))
            }
            todayMetrics = outcome.0
            readiness = outcome.1
            ingestSnapshot = await sink.currentSnapshot()
            lastSyncedAt = now
            if report.succeeded {
                lastError = nil
            } else {
                lastError = "部分数据导入失败：" + report.failedKinds.map(\.nameZH).joined(separator: "、")
            }
        } catch {
            lastError = "同步失败：\(String(describing: error))"
        }
        importProgress = nil
    }

    /// Called by `BackgroundDeliveryCoordinator` after an observer-triggered import: no new import, just
    /// re-aggregate the recent days and refresh the score.
    func recomputeAfterBackgroundImport(_ kind: HealthMetricKind, now: Date = Date()) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let settings = try await store.settings()
            let outcome = try await runOffMain { service in
                let today = try await service.rebuildDailyMetrics(settings: settings, now: now, onlyRecent: true)
                return (today, try await service.computeReadiness(settings: settings, now: now))
            }
            todayMetrics = outcome.0
            readiness = outcome.1
            ingestSnapshot = await sink.currentSnapshot()
            lastSyncedAt = now
        } catch {
            lastError = "后台更新失败（\(kind.nameZH)）：\(String(describing: error))"
        }
    }

    /// "重新导入": forgets the anchors so the next sync walks the whole HealthKit store again.
    func resetAndReimport(now: Date = Date()) async {
        await importer.resetAnchors()
        await syncToday(now: now)
    }

    // MARK: Aggregation

    /// Runs `work` in a detached task. `SetmioStore` is a `@ModelActor` whose jobs execute on the main thread when
    /// started from the main actor (StoreExecutorTests), so the 60-day aggregation must not start here.
    private func runOffMain<T: Sendable>(_ work: @escaping @Sendable (HealthSyncService) async throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { [self] in try await work(self) }.value
    }

    /// Re-aggregates the missing/recent days and returns today's metrics. Touches no main-actor state.
    nonisolated private func rebuildDailyMetrics(settings: Settings, now: Date, onlyRecent: Bool = false) async throws -> DailyMetrics? {
        let calendar = settings.calendar
        let today = DayKey(now, calendar: calendar)
        let windowStart = today.adding(days: -(Self.historyDays - 1), calendar: calendar)
        let recentStart = today.adding(days: -(Self.alwaysRecomputeDays - 1), calendar: calendar)

        var byDay: [DayKey: DailyMetrics] = [:]
        for metrics in try await store.dailyMetrics(from: windowStart, to: today) {
            byDay[metrics.day] = metrics
        }

        let days = DayKey.range(from: onlyRecent ? recentStart : windowStart, to: today, calendar: calendar)
        for day in days {
            let existing = byDay[day]
            let isRecent = day >= recentStart
            guard existing == nil || isRecent else { continue }

            let load = try await metricsSource.trainingLoad(for: day, calendar: calendar)
            let baselineTemperature = Self.baselineWristTemperature(before: day, in: byDay, calendar: calendar)
            let metrics = try await metricsSource.metrics(
                for: day,
                settings: settings,
                existing: existing,
                trainingLoad: load,
                baselineWristTemperature: baselineTemperature,
                now: now
            )
            try await store.upsertDailyMetrics(metrics)
            byDay[day] = metrics
        }
        return byDay[today]
    }

    /// Mean wrist temperature of the previous 14 nights that have one (Apple uses a similar personal baseline).
    nonisolated private static func baselineWristTemperature(before day: DayKey, in byDay: [DayKey: DailyMetrics], calendar: Calendar) -> Double? {
        let start = day.adding(days: -14, calendar: calendar)
        let values = byDay.values
            .filter { $0.day >= start && $0.day < day }
            .compactMap(\.wristTemperature)
        return Stats.mean(values)
    }

    nonisolated private func computeReadiness(settings: Settings, now: Date) async throws -> ReadinessResult {
        let calendar = settings.calendar
        let today = DayKey(now, calendar: calendar)
        let history = try await store.dailyMetrics(
            from: today.adding(days: -Self.historyDays, calendar: calendar),
            to: today.adding(days: -1, calendar: calendar)
        )
        let todayMetrics = try await store.dailyMetrics(for: today) ?? DailyMetrics(day: today)
        let inputs = ReadinessInputs(
            day: today,
            history: history,
            today: todayMetrics,
            weights: settings.readinessWeights,
            preferRMSSD: settings.preferRMSSD
        )
        let result = calculator.compute(inputs, now: now, calendar: calendar)
        if case .score(let score) = result {
            try await store.upsertReadiness(score)
        }
        return result
    }
}
