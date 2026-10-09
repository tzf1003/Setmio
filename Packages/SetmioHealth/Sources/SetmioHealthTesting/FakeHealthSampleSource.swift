import Foundation
import SetmioCore
import SetmioHealth

// MARK: - Fake source

/// In-memory `HealthSampleSource` for unit tests and the app's demo mode.
///
/// Anchored paging is modelled as a per-kind change log (added samples and deletions in order); the anchor is
/// the number of log entries already consumed, encoded as 8 little-endian bytes. That reproduces HealthKit's
/// semantics closely enough for the importer: pages of at most `limit` changes, deletions delivered once to
/// anchors that predate them, and a fresh (nil) anchor replaying every live sample.
public final class FakeHealthSampleSource: HealthSampleSource, @unchecked Sendable {
    public struct AuthorizationRequest: Sendable, Equatable {
        public var read: Set<HealthMetricKind>
        public var share: Set<HealthMetricKind>

        public init(read: Set<HealthMetricKind>, share: Set<HealthMetricKind>) {
            self.read = read
            self.share = share
        }
    }

    public struct AnchoredRequest: Sendable, Equatable {
        public var kind: HealthMetricKind
        public var anchor: Data?
        public var limit: Int

        public init(kind: HealthMetricKind, anchor: Data?, limit: Int) {
            self.kind = kind
            self.anchor = anchor
            self.limit = limit
        }
    }

    public struct BackgroundDeliveryRequest: Sendable, Equatable {
        public var kind: HealthMetricKind
        public var frequency: BackgroundFrequency

        public init(kind: HealthMetricKind, frequency: BackgroundFrequency) {
            self.kind = kind
            self.frequency = frequency
        }
    }

    public typealias ObserverHandler = @Sendable (_ completion: @escaping @Sendable () -> Void) -> Void

    private enum Change {
        case added(HealthSample)
        case deleted(UUID)
    }

    private let lock = NSLock()
    private var changeLog: [HealthMetricKind: [Change]] = [:]
    private var live: [HealthMetricKind: [HealthSample]] = [:]
    private var series: [HeartbeatSeries] = []
    private var storedWorkouts: [ImportedWorkout] = []
    private var observers: [HealthMetricKind: [(id: UUID, handler: ObserverHandler)]] = [:]
    private var completionCounts: [HealthMetricKind: Int] = [:]
    private var available = true
    private var recordedAuthorizations: [AuthorizationRequest] = []
    private var recordedAnchoredRequests: [AnchoredRequest] = []
    private var recordedBackgroundDeliveries: [BackgroundDeliveryRequest] = []
    private var anchoredFailure: (any Error)?

    public init(samples: [HealthMetricKind: [HealthSample]] = [:], heartbeatSeries: [HeartbeatSeries] = [], workouts: [ImportedWorkout] = []) {
        for (kind, list) in samples {
            let sorted = list.sorted { $0.start < $1.start }
            live[kind] = sorted
            changeLog[kind] = sorted.map(Change.added)
        }
        series = heartbeatSeries
        storedWorkouts = workouts
    }

    /// A fake pre-loaded with 60 days of plausible demo data.
    public static func demo(endingOn day: DayKey, calendar: Calendar = .setmioDefault) -> FakeHealthSampleSource {
        let dataset = DemoHealthData.sixtyDays(endingOn: day, calendar: calendar)
        return FakeHealthSampleSource(samples: dataset.samples, heartbeatSeries: dataset.heartbeatSeries, workouts: dataset.workouts)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: Test controls

    public var isHealthDataAvailable: Bool {
        get { locked { available } }
        set { locked { available = newValue } }
    }

    /// Appends samples as new changes (they show up in the next anchored page and in range queries).
    public func add(_ samples: [HealthSample]) {
        locked {
            for sample in samples {
                live[sample.kind, default: []].append(sample)
                live[sample.kind]?.sort { $0.start < $1.start }
                changeLog[sample.kind, default: []].append(.added(sample))
            }
        }
    }

    /// Records deletions: removed from range queries immediately, delivered as `deletedUUIDs` to anchors that
    /// predate the deletion.
    public func markDeleted(_ uuids: [UUID], kind: HealthMetricKind) {
        locked {
            let set = Set(uuids)
            live[kind]?.removeAll { set.contains($0.hkUUID) }
            for uuid in uuids { changeLog[kind, default: []].append(.deleted(uuid)) }
        }
    }

    public func setWorkouts(_ workouts: [ImportedWorkout]) {
        locked { storedWorkouts = workouts }
    }

    public func setHeartbeatSeries(_ series: [HeartbeatSeries]) {
        locked { self.series = series }
    }

    /// When set, every `anchoredSamples` call throws this error until cleared.
    public func failAnchoredRequests(with error: (any Error)?) {
        locked { anchoredFailure = error }
    }

    public var authorizationRequests: [AuthorizationRequest] { locked { recordedAuthorizations } }
    public var anchoredRequests: [AnchoredRequest] { locked { recordedAnchoredRequests } }
    public var backgroundDeliveryRequests: [BackgroundDeliveryRequest] { locked { recordedBackgroundDeliveries } }
    public func observerCount(for kind: HealthMetricKind) -> Int { locked { observers[kind]?.count ?? 0 } }
    public func completionCount(for kind: HealthMetricKind) -> Int { locked { completionCounts[kind] ?? 0 } }
    public func liveSamples(of kind: HealthMetricKind) -> [HealthSample] { locked { live[kind] ?? [] } }

    /// Invokes every observer registered for `kind` as HealthKit would, then waits until each handler has
    /// called its completion at least once. Returns the total completion calls recorded for `kind` so far.
    @discardableResult
    public func fire(_ kind: HealthMetricKind) async -> Int {
        let handlers = locked { (observers[kind] ?? []).map(\.handler) }
        for handler in handlers {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let once = OnceFlag()
                handler { [self] in
                    self.locked { self.completionCounts[kind, default: 0] += 1 }
                    if once.trySet() { continuation.resume() }
                }
            }
        }
        return completionCount(for: kind)
    }

    // MARK: Anchor codec

    public static func anchor(offset: Int) -> Data {
        withUnsafeBytes(of: UInt64(max(0, offset)).littleEndian) { Data($0) }
    }

    public static func offset(from anchor: Data?) -> Int {
        guard let anchor, anchor.count == 8 else { return 0 }
        let value = anchor.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        return Int(UInt64(littleEndian: value))
    }

    // MARK: HealthSampleSource

    public func isAvailable() -> Bool {
        locked { available }
    }

    public func requestAuthorization(read: Set<HealthMetricKind>, share: Set<HealthMetricKind>) async throws {
        locked { recordedAuthorizations.append(AuthorizationRequest(read: read, share: share)) }
    }

    public func anchoredSamples(of kind: HealthMetricKind, since anchor: Data?, limit: Int) async throws -> AnchoredBatch {
        try locked {
            recordedAnchoredRequests.append(AnchoredRequest(kind: kind, anchor: anchor, limit: limit))
            if let anchoredFailure { throw anchoredFailure }
            let log = changeLog[kind] ?? []
            let offset = min(Self.offset(from: anchor), log.count)
            let page = log[offset..<min(offset + max(limit, 1), log.count)]
            var samples: [HealthSample] = []
            var deleted: [UUID] = []
            for change in page {
                switch change {
                case .added(let sample): samples.append(sample)
                case .deleted(let uuid): deleted.append(uuid)
                }
            }
            return AnchoredBatch(samples: samples, deletedUUIDs: deleted, newAnchor: Self.anchor(offset: offset + page.count))
        }
    }

    public func samples(of kind: HealthMetricKind, in range: ClosedRange<Date>) async throws -> [HealthSample] {
        locked {
            (live[kind] ?? []).filter { $0.start <= range.upperBound && $0.end >= range.lowerBound }
        }
    }

    public func heartbeatSeries(in range: ClosedRange<Date>) async throws -> [HeartbeatSeries] {
        locked { series.filter { range.contains($0.start) } }
    }

    public func dailyTotal(of kind: HealthMetricKind, on day: DayKey, calendar: Calendar) async throws -> Double? {
        let start = day.startOfDay(calendar: calendar)
        let end = day.adding(days: 1, calendar: calendar).startOfDay(calendar: calendar)
        let values = locked { (live[kind] ?? []).filter { $0.start >= start && $0.start < end }.map(\.value) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    public func workouts(in range: ClosedRange<Date>) async throws -> [ImportedWorkout] {
        locked { storedWorkouts.filter { range.contains($0.start) }.sorted { $0.start < $1.start } }
    }

    public func enableBackgroundDelivery(for kind: HealthMetricKind, frequency: BackgroundFrequency) async throws {
        locked { recordedBackgroundDeliveries.append(BackgroundDeliveryRequest(kind: kind, frequency: frequency)) }
    }

    public func observe(_ kind: HealthMetricKind, handler: @escaping ObserverHandler) -> ObservationToken {
        let id = UUID()
        locked { observers[kind, default: []].append((id: id, handler: handler)) }
        return ObservationToken { [weak self] in
            self?.locked { self?.observers[kind]?.removeAll { $0.id == id } }
        }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false

    func trySet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if set { return false }
        set = true
        return true
    }
}

// MARK: - Demo data

/// Deterministic, plausible health history for demo mode and previews (seeded PRNG, so screenshots and
/// readiness scores are stable between runs).
public enum DemoHealthData {
    public struct Dataset: Sendable {
        public var samples: [HealthMetricKind: [HealthSample]]
        public var heartbeatSeries: [HeartbeatSeries]
        public var workouts: [ImportedWorkout]

        public init(samples: [HealthMetricKind: [HealthSample]] = [:], heartbeatSeries: [HeartbeatSeries] = [], workouts: [ImportedWorkout] = []) {
            self.samples = samples
            self.heartbeatSeries = heartbeatSeries
            self.workouts = workouts
        }

        public var allSamples: [HealthSample] { samples.values.flatMap { $0 } }
    }

    public static let watchSource = "com.apple.health.demo-watch"
    public static let phoneSource = "com.apple.health.demo-phone"
    public static let scaleSource = "com.setmio.demo-scale"
    /// `HKWorkoutActivityType.traditionalStrengthTraining`.
    public static let strengthActivityType = 50

    /// 60 days ending on `day`: nightly sleep with stages, overnight HRV/HR/respiratory rate/wrist temperature,
    /// a daily resting heart rate, hourly steps and energy, daily weigh-ins, plus strength workouts (with
    /// effort scores) on the last 14 days.
    public static func sixtyDays(endingOn day: DayKey, calendar: Calendar = .setmioDefault, seed: UInt64 = 0x5E7_A10) -> Dataset {
        var rng = SplitMix64(seed: seed)
        var samples: [HealthMetricKind: [HealthSample]] = [:]
        var series: [HeartbeatSeries] = []
        var workouts: [ImportedWorkout] = []
        let totalDays = 60

        func append(_ sample: HealthSample) { samples[sample.kind, default: []].append(sample) }
        func quantity(_ kind: HealthMetricKind, _ value: Double, start: Date, end: Date? = nil, source: String = watchSource) -> HealthSample {
            HealthSample(kind: kind, value: value, unit: kind.canonicalUnit, start: start, end: end ?? start, sourceBundleID: source)
        }

        for index in 0..<totalDays {
            let current = day.adding(days: index - (totalDays - 1), calendar: calendar)
            let previous = current.adding(days: -1, calendar: calendar)
            let weekday = calendar.component(.weekday, from: current.startOfDay(calendar: calendar))
            let isWeekend = weekday == 1 || weekday == 7
            // A slightly worse week in the middle so the readiness score has something to react to.
            let fatigue: Double = (25...31).contains(index) ? 1 : 0

            // Sleep: 23:00–23:45 bedtime, 6.5–8 h, 90-minute cycles of core/deep/REM with one awake slice.
            let bedtime = previous.date(atHour: 23, minute: Int(rng.next(in: 0...45)), calendar: calendar)
            let sleepMinutes = 390 + rng.next(in: 0...90) + (isWeekend ? 30 : 0) - fatigue * 45
            var cursor = bedtime
            var remaining = sleepMinutes
            var cycle = 0
            while remaining > 0 {
                let stages: [(SleepStage, Double)] = cycle == 0
                    ? [(.asleepCore, 35), (.asleepDeep, 40), (.asleepCore, 15)]
                    : [(.asleepCore, 40), (.asleepDeep, cycle < 3 ? 20 : 5), (.asleepREM, 25 + Double(cycle) * 5)]
                for (stage, length) in stages {
                    let minutes = min(length, remaining)
                    guard minutes > 0 else { break }
                    let end = cursor.addingTimeInterval(minutes * 60)
                    append(HealthSample(kind: .sleep, value: Double(stage.rawValue), unit: "", start: cursor, end: end, sourceBundleID: watchSource, categoryValue: stage.rawValue))
                    cursor = end
                    remaining -= minutes
                }
                if cycle == 2 {
                    let awakeEnd = cursor.addingTimeInterval(4 * 60)
                    append(HealthSample(kind: .sleep, value: Double(SleepStage.awake.rawValue), unit: "", start: cursor, end: awakeEnd, sourceBundleID: watchSource, categoryValue: SleepStage.awake.rawValue))
                    cursor = awakeEnd
                }
                cycle += 1
            }
            let wakeTime = cursor

            // Overnight vitals.
            let hrvBase = 48 - fatigue * 10
            for offsetHours in [1.5, 3.0, 4.5, 6.0] {
                let at = bedtime.addingTimeInterval(offsetHours * 3600)
                guard at < wakeTime else { continue }
                append(quantity(.hrvSDNN, (hrvBase + rng.gaussian() * 6).rounded(), start: at))
                append(quantity(.respiratoryRate, (14.8 + fatigue * 0.6 + rng.gaussian() * 0.6).rounded(toPlaces: 1), start: at, end: at.addingTimeInterval(300)))
                // Beat-to-beat series: ~5 minutes at ~55 bpm with RMSSD around 35 ms.
                var beats: [Double] = [0]
                var t = 0.0
                while t < 300 {
                    t += 1.09 + rng.gaussian() * 0.025
                    beats.append(t)
                }
                series.append(HeartbeatSeries(start: at, end: at.addingTimeInterval(t), beatTimes: beats))
            }
            var hrTime = bedtime
            while hrTime < wakeTime {
                append(quantity(.heartRate, (54 + fatigue * 4 + rng.gaussian() * 3).rounded(), start: hrTime))
                hrTime = hrTime.addingTimeInterval(10 * 60)
            }
            append(quantity(.wristTemperature, (36.2 + fatigue * 0.3 + rng.gaussian() * 0.12).rounded(toPlaces: 2), start: bedtime.addingTimeInterval(3 * 3600)))
            append(quantity(.restingHeartRate, (55 + fatigue * 4 + rng.gaussian() * 1.5).rounded(), start: current.date(atHour: 0, minute: 5, calendar: calendar), end: current.date(atHour: 9, minute: 30, calendar: calendar)))

            // Daytime heart rate and activity, hourly 07:00–22:00.
            let stepsTotal = (isWeekend ? 6000.0 : 8500.0) + rng.gaussian() * 1500
            let activeTotal = (isWeekend ? 380.0 : 480.0) + rng.gaussian() * 80
            let basalTotal = 1620.0 + rng.gaussian() * 25
            for hour in 7..<22 {
                let start = current.date(atHour: hour, calendar: calendar)
                let end = start.addingTimeInterval(3600)
                let share = hourlyShare(hour: hour)
                append(quantity(.steps, max(0, (stepsTotal * share).rounded()), start: start, end: end, source: phoneSource))
                append(quantity(.activeEnergy, max(0, (activeTotal * share).rounded()), start: start, end: end))
                append(quantity(.heartRate, (74 + rng.gaussian() * 8).rounded(), start: start.addingTimeInterval(1800)))
            }
            for hour in 0..<24 {
                let start = current.date(atHour: hour, calendar: calendar)
                append(quantity(.basalEnergy, (basalTotal / 24).rounded(toPlaces: 1), start: start, end: start.addingTimeInterval(3600)))
            }

            // Body composition: slow downward trend 82 → 80.5 kg with daily noise, weekly body fat.
            let trend = 82.0 - 1.5 * Double(index) / Double(totalDays - 1)
            append(quantity(.bodyMass, (trend + rng.gaussian() * 0.35).rounded(toPlaces: 1), start: current.date(atHour: 7, minute: 30, calendar: calendar), source: scaleSource))
            if index % 7 == 0 {
                let fat = 0.24 - 0.01 * Double(index) / Double(totalDays - 1)
                append(quantity(.bodyFatPercentage, fat.rounded(toPlaces: 3), start: current.date(atHour: 7, minute: 31, calendar: calendar), source: scaleSource))
                append(quantity(.leanBodyMass, (trend * (1 - fat)).rounded(toPlaces: 1), start: current.date(atHour: 7, minute: 31, calendar: calendar), source: scaleSource))
            }

            // Strength workouts on the last two weeks: Mon/Wed/Fri evenings.
            if index >= totalDays - 14, [2, 4, 6].contains(weekday) {
                let start = current.date(atHour: 18, minute: 30, calendar: calendar)
                let minutes = 55 + rng.next(in: 0...15)
                let end = start.addingTimeInterval(minutes * 60)
                let effort = 6 + Int(rng.next(in: 0...2))
                let energy = (minutes * 5.5 + rng.gaussian() * 20).rounded()
                let uuid = UUID()
                workouts.append(ImportedWorkout(hkUUID: uuid, start: start, end: end, activityTypeRawValue: strengthActivityType, totalEnergy: energy, effortScore: effort, sourceBundleID: watchSource))
                append(HealthSample(hkUUID: uuid, kind: .workout, value: minutes, unit: HealthMetricKind.workout.canonicalUnit, start: start, end: end, sourceBundleID: watchSource, categoryValue: strengthActivityType))
                append(quantity(.workoutEffort, Double(effort), start: start, end: end))
            }
        }

        for kind in samples.keys { samples[kind]?.sort { $0.start < $1.start } }
        return Dataset(samples: samples, heartbeatSeries: series, workouts: workouts)
    }

    /// Rough distribution of a day's steps/energy across 07:00–21:00 (commute and evening peaks).
    private static func hourlyShare(hour: Int) -> Double {
        let weights: [Int: Double] = [7: 0.05, 8: 0.09, 9: 0.06, 10: 0.05, 11: 0.05, 12: 0.08, 13: 0.06, 14: 0.05, 15: 0.05, 16: 0.05, 17: 0.07, 18: 0.11, 19: 0.09, 20: 0.08, 21: 0.06]
        return weights[hour] ?? 0
    }
}

// MARK: - Deterministic PRNG

/// SplitMix64: tiny, seedable, good enough for demo noise.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform double in `range`.
    public mutating func next(in range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }

    /// Standard normal via Box–Muller.
    public mutating func gaussian() -> Double {
        let u1 = max(next(in: 0...1), 1e-12)
        let u2 = next(in: 0...1)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
