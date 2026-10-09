import Foundation
import Testing
import SetmioCore
import SetmioHealth
import SetmioHealthTesting

// MARK: - Fixtures

enum HealthFixture {
    static let calendar = Calendar.setmioDefault
    static let today = DayKey(year: 2026, month: 10, day: 9)
    static let now = today.date(atHour: 11, calendar: calendar)

    static func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "SetmioHealthTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "anchors.json", directoryHint: .notDirectory)
    }

    static func anchors() -> AnchorStore {
        AnchorStore(fileURL: tempFileURL())
    }

    static func samples(_ kind: HealthMetricKind, count: Int, startingAt base: Date = today.adding(days: -30, calendar: calendar).startOfDay(calendar: calendar)) -> [HealthSample] {
        (0..<count).map { index in
            let start = base.addingTimeInterval(Double(index) * 600)
            return HealthSample(kind: kind, value: Double(index), unit: kind.canonicalUnit, start: start, end: start, sourceBundleID: "test")
        }
    }

    static func sample(_ kind: HealthMetricKind, _ value: Double, hour: Int, minute: Int = 0, dayOffset: Int = 0, durationMinutes: Double = 0, stage: SleepStage? = nil) -> HealthSample {
        let start = today.adding(days: dayOffset, calendar: calendar).date(atHour: hour, minute: minute, calendar: calendar)
        return HealthSample(kind: kind, value: value, unit: kind.canonicalUnit, start: start, end: start.addingTimeInterval(durationMinutes * 60), sourceBundleID: "watch", categoryValue: stage?.rawValue)
    }
}

/// Thread-safe collector for `ImportProgress` callbacks.
final class ProgressLog: @unchecked Sendable { // lock-guarded array; the callback is @Sendable and may run on any executor
    private let lock = NSLock()
    private var storage: [ImportProgress] = []
    func append(_ event: ImportProgress) { lock.lock(); storage.append(event); lock.unlock() }
    var events: [ImportProgress] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Records every ingested batch; optionally fails on chosen calls.
actor RecordingSink: HealthSampleSink {
    struct Failure: Error, Equatable { let call: Int }

    private(set) var batches: [(kind: HealthMetricKind, batch: AnchoredBatch)] = []
    private var failingCalls: Set<Int>
    private(set) var calls = 0

    init(failingCalls: Set<Int> = []) {
        self.failingCalls = failingCalls
    }

    func ingest(_ batch: AnchoredBatch, kind: HealthMetricKind) async throws {
        calls += 1
        if failingCalls.contains(calls) { throw Failure(call: calls) }
        batches.append((kind, batch))
    }

    func setFailingCalls(_ calls: Set<Int>) { failingCalls = calls }

    var sampleCount: Int { batches.reduce(0) { $0 + $1.batch.samples.count } }
    var deletedUUIDs: [UUID] { batches.flatMap { $0.batch.deletedUUIDs } }
    var sampleUUIDs: [UUID] { batches.flatMap { $0.batch.samples.map(\.hkUUID) } }
}

actor Collector<Value: Sendable> {
    private(set) var values: [Value] = []
    func append(_ value: Value) { values.append(value) }
}

// MARK: - Importer

@Suite("HealthSampleImporter")
struct HealthSampleImporterTests {
    @Test("pages until a page is shorter than the page size")
    func pagesUntilExhaustion() async throws {
        let source = FakeHealthSampleSource(samples: [.heartRate: HealthFixture.samples(.heartRate, count: 1200)])
        let sink = RecordingSink()
        let anchors = HealthFixture.anchors()
        let importer = HealthSampleImporter(source: source, anchors: anchors, sink: sink, pageSize: 500)

        let imported = try await importer.importNew(.heartRate)

        #expect(imported == 1200)
        #expect(await sink.calls == 3)
        #expect(await sink.batches.map { $0.batch.samples.count } == [500, 500, 200])
        #expect(source.anchoredRequests.map(\.limit) == [500, 500, 500])
        #expect(source.anchoredRequests.map { FakeHealthSampleSource.offset(from: $0.anchor) } == [0, 500, 1000])
        #expect(FakeHealthSampleSource.offset(from: await anchors.get(.heartRate)) == 1200)

        // A second import finds nothing new and leaves the anchor where it was.
        let again = try await importer.importNew(.heartRate)
        #expect(again == 0)
        #expect(FakeHealthSampleSource.offset(from: await anchors.get(.heartRate)) == 1200)
    }

    @Test("an exact multiple of the page size needs one extra empty page and then stops")
    func exactMultiple() async throws {
        let source = FakeHealthSampleSource(samples: [.steps: HealthFixture.samples(.steps, count: 1000)])
        let sink = RecordingSink()
        let importer = HealthSampleImporter(source: source, anchors: HealthFixture.anchors(), sink: sink, pageSize: 500)
        #expect(try await importer.importNew(.steps) == 1000)
        #expect(source.anchoredRequests.count == 3)
        #expect(await sink.batches.last?.batch.isEmpty == true)
    }

    @Test("the anchor is persisted only after the sink succeeded")
    func anchorOnlyAfterSinkSuccess() async throws {
        let source = FakeHealthSampleSource(samples: [.hrvSDNN: HealthFixture.samples(.hrvSDNN, count: 1200)])
        let sink = RecordingSink(failingCalls: [1])
        let anchors = HealthFixture.anchors()
        let importer = HealthSampleImporter(source: source, anchors: anchors, sink: sink, pageSize: 500)

        await #expect(throws: RecordingSink.Failure(call: 1)) {
            try await importer.importNew(.hrvSDNN)
        }
        #expect(await anchors.get(.hrvSDNN) == nil, "a failing sink must leave the anchor unchanged")

        // Fail on the second page this time: the first page's anchor is kept, the second is not.
        await sink.setFailingCalls([3])
        await #expect(throws: RecordingSink.Failure(call: 3)) {
            try await importer.importNew(.hrvSDNN)
        }
        #expect(FakeHealthSampleSource.offset(from: await anchors.get(.hrvSDNN)) == 500)

        // With a healthy sink the import resumes from the persisted anchor and nothing is lost.
        await sink.setFailingCalls([])
        let remaining = try await importer.importNew(.hrvSDNN)
        #expect(remaining == 700)
        #expect(await sink.sampleCount == 1200)
        #expect(Set(await sink.sampleUUIDs).count == 1200)
        #expect(FakeHealthSampleSource.offset(from: await anchors.get(.hrvSDNN)) == 1200)
    }

    @Test("resetAnchors makes the next import start from the beginning")
    func resetReimports() async throws {
        let source = FakeHealthSampleSource(samples: [.bodyMass: HealthFixture.samples(.bodyMass, count: 30)])
        let sink = RecordingSink()
        let anchors = HealthFixture.anchors()
        let importer = HealthSampleImporter(source: source, anchors: anchors, sink: sink, pageSize: 500)

        #expect(try await importer.importNew(.bodyMass) == 30)
        #expect(try await importer.importNew(.bodyMass) == 0)
        await importer.resetAnchors()
        #expect(await anchors.get(.bodyMass) == nil)
        #expect(try await importer.importNew(.bodyMass) == 30)
        #expect(await sink.sampleCount == 60)
    }

    @Test("deleted UUIDs propagate to the sink")
    func deletedUUIDsPropagate() async throws {
        let samples = HealthFixture.samples(.sleep, count: 10)
        let source = FakeHealthSampleSource(samples: [.sleep: samples])
        let sink = RecordingSink()
        let importer = HealthSampleImporter(source: source, anchors: HealthFixture.anchors(), sink: sink, pageSize: 500)

        #expect(try await importer.importNew(.sleep) == 10)
        let removed = [samples[2].hkUUID, samples[7].hkUUID]
        source.markDeleted(removed, kind: .sleep)

        #expect(try await importer.importNew(.sleep) == 0)
        #expect(await sink.deletedUUIDs == removed)
        #expect(source.liveSamples(of: .sleep).count == 8)
    }

    @Test("importAll collects per-kind counts and errors without throwing")
    func importAllReport() async throws {
        let source = FakeHealthSampleSource(samples: [
            .steps: HealthFixture.samples(.steps, count: 12),
            .heartRate: HealthFixture.samples(.heartRate, count: 7),
        ])
        let sink = RecordingSink(failingCalls: [2])
        let importer = HealthSampleImporter(source: source, anchors: HealthFixture.anchors(), sink: sink, pageSize: 500)

        let report = await importer.importAll(kinds: [.steps, .heartRate, .sleep])
        #expect(report.counts[.steps] == 12)
        #expect(report.counts[.heartRate] == nil)
        #expect(report.counts[.sleep] == 0)
        #expect(report.failedKinds == [.heartRate])
        #expect(report.totalImported == 12)
        #expect(!report.succeeded)
    }

    @Test("importAll reports progress per kind and per page, ending at the full count")
    func importAllProgress() async throws {
        let source = FakeHealthSampleSource(samples: [
            .steps: HealthFixture.samples(.steps, count: 1_000),
            .heartRate: HealthFixture.samples(.heartRate, count: 5),
        ])
        let importer = HealthSampleImporter(source: source, anchors: HealthFixture.anchors(), sink: RecordingSink(), pageSize: 400)
        let log = ProgressLog()

        _ = await importer.importAll(kinds: [.steps, .heartRate]) { log.append($0) }

        let events = log.events
        #expect(events.first == ImportProgress(kind: .steps, kindIndex: 0, kindCount: 2, importedSoFar: 0))
        // 1 000 samples at 400 per page → pages of 400, 400, 200.
        #expect(events.filter { $0.kind == .steps }.map(\.importedSoFar) == [0, 400, 800, 1_000])
        #expect(events.last == ImportProgress(kind: .heartRate, kindIndex: 1, kindCount: 2, importedSoFar: 1_005))
        #expect(events.map(\.importedSoFar) == events.map(\.importedSoFar).sorted(), "progress never goes backwards")
        #expect(events.last?.fractionOfKindsCompleted == 0.5)
    }

    @Test("concurrent imports of the same kind share one run")
    func concurrentSameKind() async throws {
        let source = FakeHealthSampleSource(samples: [.activeEnergy: HealthFixture.samples(.activeEnergy, count: 900)])
        let sink = RecordingSink()
        let importer = HealthSampleImporter(source: source, anchors: HealthFixture.anchors(), sink: sink, pageSize: 300)

        async let first = importer.importNew(.activeEnergy)
        async let second = importer.importNew(.activeEnergy)
        let results = try await [first, second]
        #expect(results == [900, 900])
        #expect(await sink.sampleCount == 900, "the second caller must not re-ingest the same pages")
    }
}

// MARK: - AnchorStore

@Suite("AnchorStore")
struct AnchorStoreTests {
    @Test("anchors survive a new store instance on the same file and use versioned keys")
    func persistence() async throws {
        let url = HealthFixture.tempFileURL()
        let store = AnchorStore(fileURL: url)
        try await store.set(Data([1, 2, 3]), for: .steps)
        #expect(await store.allKeys() == ["steps#v\(AnchorStore.anchorSchemaVersion)"])

        let reopened = AnchorStore(fileURL: url)
        #expect(await reopened.get(.steps) == Data([1, 2, 3]))
        #expect(await reopened.get(.sleep) == nil)

        try await reopened.reset(.steps)
        #expect(await AnchorStore(fileURL: url).get(.steps) == nil)
    }

    @Test("a schema bump orphans old anchors")
    func schemaVersion() async throws {
        let url = HealthFixture.tempFileURL()
        try await AnchorStore(fileURL: url, schemaVersion: 1).set(Data([9]), for: .sleep)
        #expect(await AnchorStore(fileURL: url, schemaVersion: 2).get(.sleep) == nil)
        #expect(await AnchorStore(fileURL: url, schemaVersion: 1).get(.sleep) == Data([9]))
    }
}

// MARK: - Background delivery

@Suite("BackgroundDeliveryCoordinator")
struct BackgroundDeliveryCoordinatorTests {
    @Test("an observer fire imports, notifies and calls HealthKit's completion exactly once")
    func completionCalledOnce() async throws {
        let source = FakeHealthSampleSource(samples: [.hrvSDNN: HealthFixture.samples(.hrvSDNN, count: 3)])
        let sink = RecordingSink()
        let importer = HealthSampleImporter(source: source, anchors: HealthFixture.anchors(), sink: sink)
        let imported = Collector<HealthMetricKind>()
        let coordinator = BackgroundDeliveryCoordinator(source: source, importer: importer) { kind in
            await imported.append(kind)
        }

        let failures = await coordinator.start(kinds: [.hrvSDNN, .steps])
        #expect(failures.isEmpty)
        #expect(source.backgroundDeliveryRequests == [
            .init(kind: .hrvSDNN, frequency: .immediate),
            .init(kind: .steps, frequency: .hourly),
        ])
        #expect(source.observerCount(for: .hrvSDNN) == 1)
        #expect(coordinator.observedKinds == [.hrvSDNN, .steps])

        await source.fire(.hrvSDNN)
        try await Task.sleep(for: .milliseconds(50))   // give any stray second completion a chance to show up

        #expect(source.completionCount(for: .hrvSDNN) == 1)
        #expect(await sink.sampleCount == 3)
        #expect(await imported.values == [.hrvSDNN])

        // Completion is also called exactly once when the import throws.
        source.failAnchoredRequests(with: HealthSourceError.anchorCorrupted)
        await source.fire(.hrvSDNN)
        try await Task.sleep(for: .milliseconds(50))
        #expect(source.completionCount(for: .hrvSDNN) == 2)
        #expect(await imported.values == [.hrvSDNN, .hrvSDNN])

        // Starting again does not double-register; stopping removes the observers.
        await coordinator.start(kinds: [.hrvSDNN])
        #expect(source.observerCount(for: .hrvSDNN) == 1)
        coordinator.stop()
        #expect(source.observerCount(for: .hrvSDNN) == 0)
        #expect(coordinator.observedKinds.isEmpty)
    }

    @Test("frequency table matches the design: vitals immediate, activity hourly")
    func frequencies() {
        for kind in [HealthMetricKind.hrvSDNN, .hrvRMSSD, .restingHeartRate, .sleep, .respiratoryRate, .wristTemperature, .bodyMass] {
            #expect(BackgroundDeliveryCoordinator.frequency(for: kind) == .immediate, "\(kind)")
        }
        for kind in [HealthMetricKind.steps, .activeEnergy, .basalEnergy, .heartRate, .workout] {
            #expect(BackgroundDeliveryCoordinator.frequency(for: kind) == .hourly, "\(kind)")
        }
    }
}

// MARK: - Mirroring

@Suite("MirroringEnvelope")
struct MirroringEnvelopeTests {
    static let fixedDate = Date(timeIntervalSince1970: 1_791_000_000.25)
    static let sessionID = ID<LoggedSession>(uuidString: "00000000-0000-4000-8000-00000000AAAA")!
    static let exerciseID = ID<Exercise>(uuidString: "00000000-0000-4000-8000-000000000003")!

    static var loggedSet: LoggedSet {
        LoggedSet(sessionID: sessionID, exerciseID: exerciseID, index: 1, load: 62.5, reps: 10, rir: 2, tempo: Tempo(eccentric: 3, pauseBottom: 1, concentric: 1, pauseTop: 0), startedAt: fixedDate.addingTimeInterval(-40), completedAt: fixedDate)
    }

    static var session: LoggedSession {
        LoggedSession(id: sessionID, start: fixedDate.addingTimeInterval(-3600), end: fixedDate, sets: [loggedSet], feedback: SessionFeedback(soreness: 2, pump: 3, joint: 1, note: "状态不错"), effortScore: 7, origin: .watch)
    }

    static var plan: PlannedSession {
        PlannedSession(mesocycleID: ID(), day: HealthFixture.today, dayNameZH: "推", exercises: [
            PlannedExercise(exerciseID: exerciseID, sets: [PlannedSet(index: 0, targetLoad: 60, targetReps: 8...12, targetRIR: 2)], decision: .increaseLoad(by: 2.5)),
        ], readinessAdjustment: ReadinessAdjustment(readinessScore: 72, loadMultiplier: 1, setsDelta: 0, rirDelta: 0, noteZH: "正常"))
    }

    static var everyMessage: [MirroringMessage] {
        [
            .hello(watchAppVersion: "1.0.0", planVersion: 3),
            .hello(watchAppVersion: "1.0.0", planVersion: nil),
            .setLogged(loggedSet, restSeconds: 180),
            .setDeleted(loggedSet.id),
            .sessionEnded(session),
            .ack(ids: [loggedSet.id.rawValue, sessionID.rawValue]),
            .planUpdated(plan),
            .restTimerCommand(.add30),
            .restTimerChanged(RestTimerState(endDate: Date(timeIntervalSince1970: 1_790_000_100), totalSeconds: 120, pausedRemaining: 45)),
            .restTimerChanged(nil),
        ]
    }

    @Test("every message case round-trips through the envelope codec")
    func roundTrip() throws {
        for (index, message) in Self.everyMessage.enumerated() {
            let envelope = MirroringEnvelope(seq: index + 1, message: message)
            let data = try MirroringEnvelope.encode(envelope)
            let decoded = try MirroringEnvelope.decode(data)
            #expect(decoded == envelope, "case \(index)")
            #expect(decoded.v == MirroringEnvelope.currentVersion)
        }
    }

    @Test("dates are ISO 8601 strings with fractional seconds")
    func isoDates() throws {
        let data = try MirroringEnvelope(seq: 1, message: .setLogged(Self.loggedSet, restSeconds: 90)).encoded()
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"completedAt\":\"2026-10-03T04:00:00.250Z\""), "\(json)")
        #expect(json.contains("\"startedAt\":\"2026-10-03T03:59:20.250Z\""), "\(json)")
    }

    @Test("a newer protocol version is rejected, garbage is reported as malformed")
    func versionAndMalformed() throws {
        var newer = MirroringEnvelope(seq: 1, message: .restTimerCommand(.pause))
        newer.v = MirroringEnvelope.currentVersion + 1
        let data = try MirroringEnvelope.encode(newer)
        #expect(throws: MirroringError.unsupportedVersion(MirroringEnvelope.currentVersion + 1)) {
            try MirroringEnvelope.decode(data)
        }
        #expect(throws: MirroringError.self) {
            try MirroringEnvelope.decode(Data("not json".utf8))
        }
    }

    @Test("the sequencer numbers envelopes from 1")
    func sequencer() {
        var sequencer = MirroringSequencer()
        #expect(sequencer.next(.restTimerCommand(.skip)).seq == 1)
        #expect(sequencer.next(.restTimerCommand(.resume)).seq == 2)
        #expect(sequencer.last == 2)
    }
}

// MARK: - Daily metrics

@Suite("DailyMetricsSource")
struct DailyMetricsSourceTests {
    @Test("overnight HRV is the median of samples inside the detected sleep window")
    func hrvMedianInsideSleep() async throws {
        let f = HealthFixture.self
        let sleep = [
            f.sample(.sleep, 0, hour: 23, minute: 30, dayOffset: -1, durationMinutes: 150, stage: .asleepCore),   // 23:30–02:00
            f.sample(.sleep, 0, hour: 2, minute: 0, durationMinutes: 60, stage: .asleepDeep),                     // 02:00–03:00
            f.sample(.sleep, 0, hour: 3, minute: 0, durationMinutes: 250, stage: .asleepREM),                     // 03:00–07:10
        ]
        let hrv = [
            f.sample(.hrvSDNN, 45, hour: 2),
            f.sample(.hrvSDNN, 55, hour: 3, minute: 30),
            f.sample(.hrvSDNN, 30, hour: 11),   // inside the fetch window but awake → excluded by Core
            f.sample(.hrvSDNN, 20, hour: 14),   // outside the fetch window entirely
        ]
        let steps = (8..<12).map { f.sample(.steps, 500, hour: $0, durationMinutes: 60) }
        let yesterdayRHR = f.sample(.restingHeartRate, 70, hour: 6, dayOffset: -1, durationMinutes: 17 * 60)   // spans into the window
        let todayRHR = f.sample(.restingHeartRate, 52, hour: 0, minute: 10, durationMinutes: 9 * 60)

        let source = FakeHealthSampleSource(samples: [
            .sleep: sleep,
            .hrvSDNN: hrv,
            .steps: steps,
            .restingHeartRate: [yesterdayRHR, todayRHR],
        ])
        let metrics = try await DailyMetricsSource(source: source).metrics(for: f.today, settings: .default, now: f.now)

        #expect(metrics.day == f.today)
        #expect(metrics.hrvSDNN == 50)
        #expect(metrics.sleep?.asleepMinutes == 460)
        #expect(metrics.steps == 2000)
        #expect(metrics.restingHR == 52, "yesterday's day-spanning RHR sample must not win")
        #expect(metrics.restingHRFrozenAt == f.now, "11:00 is past the 10:00 freeze hour")
        #expect(metrics.activeEnergy == nil)
    }

    @Test("training load sums effort × minutes over the day's workouts, defaulting effort to 5")
    func trainingLoad() async throws {
        let f = HealthFixture.self
        let morning = f.today.date(atHour: 7, calendar: f.calendar)
        let evening = f.today.date(atHour: 19, calendar: f.calendar)
        let yesterday = f.today.adding(days: -1, calendar: f.calendar).date(atHour: 19, calendar: f.calendar)
        let source = FakeHealthSampleSource(workouts: [
            ImportedWorkout(hkUUID: UUID(), start: morning, end: morning.addingTimeInterval(30 * 60), activityTypeRawValue: 50, effortScore: 8),
            ImportedWorkout(hkUUID: UUID(), start: evening, end: evening.addingTimeInterval(60 * 60), activityTypeRawValue: 50, effortScore: nil),
            ImportedWorkout(hkUUID: UUID(), start: yesterday, end: yesterday.addingTimeInterval(60 * 60), activityTypeRawValue: 50, effortScore: 9),
        ])
        let load = try await DailyMetricsSource(source: source).trainingLoad(for: f.today, calendar: f.calendar)
        #expect(load == 8 * 30 + 5 * 60)
    }

    @Test("demo data yields a full metrics row and enough baseline for a readiness score")
    func demoDataEndToEnd() async throws {
        let f = HealthFixture.self
        let source = FakeHealthSampleSource.demo(endingOn: f.today, calendar: f.calendar)
        let metricsSource = DailyMetricsSource(source: source)

        var history: [DailyMetrics] = []
        for offset in stride(from: 59, through: 1, by: -1) {
            let day = f.today.adding(days: -offset, calendar: f.calendar)
            let load = try await metricsSource.trainingLoad(for: day, calendar: f.calendar)
            history.append(try await metricsSource.metrics(for: day, settings: .default, trainingLoad: load, now: day.date(atHour: 12, calendar: f.calendar)))
        }
        let today = try await metricsSource.metrics(for: f.today, settings: .default, now: f.now)

        #expect(history.count == 59)
        #expect(history.allSatisfy { $0.hrvSDNN != nil && $0.restingHR != nil && $0.sleep != nil && $0.steps != nil })
        #expect(today.hrvRMSSD != nil, "RMSSD comes from the heartbeat series")
        #expect((300...600).contains(today.sleep?.asleepMinutes ?? 0))
        #expect(history.contains { ($0.trainingLoad ?? 0) > 0 })

        let result = ReadinessCalculator().compute(ReadinessInputs(day: f.today, history: history, today: today), now: f.now, calendar: f.calendar)
        let score = try #require(result.score)
        #expect((0...100).contains(score.score))
        #expect(score.baselineDays == 59)
    }
}

// MARK: - Fake behaviour

@Suite("FakeHealthSampleSource")
struct FakeHealthSampleSourceTests {
    @Test("records authorization requests and observer cancellation")
    func bookkeeping() async throws {
        let source = FakeHealthSampleSource()
        try await source.requestAuthorization(read: [.sleep, .hrvSDNN], share: [.workout])
        #expect(source.authorizationRequests == [.init(read: [.sleep, .hrvSDNN], share: [.workout])])

        let token = source.observe(.sleep) { completion in completion() }
        #expect(source.observerCount(for: .sleep) == 1)
        #expect(await source.fire(.sleep) == 1)
        token.cancel()
        token.cancel()
        #expect(token.isCancelled)
        #expect(source.observerCount(for: .sleep) == 0)
    }

    @Test("anchors encode page offsets and samples added later appear on the next page")
    func anchorsAndLateSamples() async throws {
        let source = FakeHealthSampleSource(samples: [.steps: HealthFixture.samples(.steps, count: 2)])
        let first = try await source.anchoredSamples(of: .steps, since: nil, limit: 10)
        #expect(first.samples.count == 2)
        #expect(FakeHealthSampleSource.offset(from: first.newAnchor) == 2)

        source.add(HealthFixture.samples(.steps, count: 1, startingAt: HealthFixture.now))
        let second = try await source.anchoredSamples(of: .steps, since: first.newAnchor, limit: 10)
        #expect(second.samples.count == 1)
        #expect(FakeHealthSampleSource.offset(from: second.newAnchor) == 3)
    }
}


// MARK: - SessionRecovery

@Suite("SessionRecovery 训练中崩溃恢复")
struct SessionRecoveryTests {
    private func set(_ session: ID<LoggedSession>, _ index: Int, minute: Int) -> LoggedSet {
        LoggedSet(sessionID: session, exerciseID: ID(), index: index, load: 60, reps: 10, rir: 2,
                  completedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(minute) * 60))
    }

    @Test("没有日志 → 没有可恢复的训练")
    func empty() {
        #expect(SessionRecovery.unfinishedSession(from: []) == nil)
        #expect(SessionRecovery.unfinishedSession(from: [.hello(watchAppVersion: "1", planVersion: nil), .ack(ids: [UUID()])]) == nil)
    }

    @Test("未结束的训练：返回其全部组（含已确认的），重发合并，已删除的剔除")
    func unfinished() {
        let id = ID<LoggedSession>()
        let a = set(id, 0, minute: 0), b = set(id, 1, minute: 4), c = set(id, 2, minute: 8)
        let messages: [MirroringMessage] = [
            .hello(watchAppVersion: "1", planVersion: 3),
            .setLogged(a, restSeconds: 90), .ack(ids: [a.id.rawValue]),
            .setLogged(b, restSeconds: 90), .setLogged(b, restSeconds: 90),
            .setLogged(c, restSeconds: 90), .setDeleted(b.id),
        ]
        let recovered = SessionRecovery.unfinishedSession(from: messages)
        #expect(recovered?.sessionID == id)
        #expect(recovered?.sets.map(\.id) == [a.id, c.id])
    }

    @Test("已发送 sessionEnded 的训练不再恢复；多个未结束时取最近的")
    func endedAndNewest() {
        let old = ID<LoggedSession>(), finished = ID<LoggedSession>(), current = ID<LoggedSession>()
        let ended = LoggedSession(id: finished, start: Date(timeIntervalSince1970: 1_790_000_000), end: Date(timeIntervalSince1970: 1_790_003_600), origin: .watch)
        let messages: [MirroringMessage] = [
            .setLogged(set(old, 0, minute: 0), restSeconds: 90),
            .setLogged(set(finished, 0, minute: 10), restSeconds: 90), .sessionEnded(ended),
            .setLogged(set(current, 0, minute: 120), restSeconds: 90),
        ]
        #expect(SessionRecovery.unfinishedSession(from: messages)?.sessionID == current)
    }
}
