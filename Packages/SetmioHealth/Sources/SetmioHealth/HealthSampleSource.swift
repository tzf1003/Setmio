import Foundation
import Synchronization
import SetmioCore

// MARK: - The seam between HealthKit and everything else
//
// Every type in this file is Foundation-only so the importer, the aggregation adapter and the fake used by
// tests and demo mode compile on Linux. The HealthKit-backed implementation lives in HKHealthSampleSource.swift
// behind `#if canImport(HealthKit)`.

/// One page of an anchored (incremental) query: new samples, UUIDs deleted since the previous anchor, and the
/// opaque anchor to resume from. `newAnchor` is an archived `HKQueryAnchor` in production and a page offset in
/// the fake; nothing outside the source interprets it.
public struct AnchoredBatch: Sendable, Equatable {
    public var samples: [HealthSample]
    public var deletedUUIDs: [UUID]
    public var newAnchor: Data?

    public init(samples: [HealthSample], deletedUUIDs: [UUID] = [], newAnchor: Data?) {
        self.samples = samples
        self.deletedUUIDs = deletedUUIDs
        self.newAnchor = newAnchor
    }

    public static let empty = AnchoredBatch(samples: [], deletedUUIDs: [], newAnchor: nil)

    public var isEmpty: Bool { samples.isEmpty && deletedUUIDs.isEmpty }
}

/// Mirrors `HKUpdateFrequency` without importing HealthKit.
public enum BackgroundFrequency: String, Sendable, Codable, Hashable, CaseIterable {
    case immediate, hourly, daily
}

/// Handle returned by `HealthSampleSource.observe`. Cancelling stops the underlying observer query. Cancel is
/// idempotent; the token does **not** cancel on deinit, so an observer stays alive until someone explicitly
/// stops it (HealthKit observers must outlive the UI that created them).
public final class ObservationToken: Sendable {
    private let state: Mutex<(@Sendable () -> Void)?>

    public init(cancel: @escaping @Sendable () -> Void) {
        state = Mutex(cancel)
    }

    /// A token that does nothing when cancelled (returned for unsupported kinds).
    public static func noop() -> ObservationToken { ObservationToken {} }

    public var isCancelled: Bool {
        state.withLock { $0 == nil }
    }

    public func cancel() {
        let closure = state.withLock { stored -> (@Sendable () -> Void)? in
            let closure = stored
            stored = nil
            return closure
        }
        closure?()
    }
}

/// Everything the app needs from HealthKit, expressed in Core value types only.
///
/// Implementations must be safe to call from any task concurrently. Kinds an implementation cannot serve
/// (for example `.hrvRMSSD` on iOS 26, where there is no system type yet) return empty results rather than
/// throwing, so callers can request the full MVP set without feature-checking each kind.
public protocol HealthSampleSource: Sendable {
    func isAvailable() -> Bool

    func requestAuthorization(read: Set<HealthMetricKind>, share: Set<HealthMetricKind>) async throws

    /// Incremental page of samples since `anchor` (nil = from the beginning). At most `limit` samples.
    func anchoredSamples(of kind: HealthMetricKind, since anchor: Data?, limit: Int) async throws -> AnchoredBatch

    /// Samples overlapping `range`, sorted by start date ascending.
    func samples(of kind: HealthMetricKind, in range: ClosedRange<Date>) async throws -> [HealthSample]

    /// Beat-to-beat series whose start lies in `range` (used to compute RMSSD locally).
    func heartbeatSeries(in range: ClosedRange<Date>) async throws -> [HeartbeatSeries]

    /// Cumulative sum of a quantity over one local day (steps, energy). Nil when nothing was recorded.
    func dailyTotal(of kind: HealthMetricKind, on day: DayKey, calendar: Calendar) async throws -> Double?

    /// Workouts from any source whose start lies in `range`.
    func workouts(in range: ClosedRange<Date>) async throws -> [ImportedWorkout]

    func enableBackgroundDelivery(for kind: HealthMetricKind, frequency: BackgroundFrequency) async throws

    /// Registers an observer. `handler` receives a `completion` closure that **must** be called exactly once
    /// when the app has finished reacting, otherwise HealthKit stops delivering background updates.
    func observe(
        _ kind: HealthMetricKind,
        handler: @escaping @Sendable (_ completion: @escaping @Sendable () -> Void) -> Void
    ) -> ObservationToken
}

// MARK: - Small shared helpers

/// Canonical unit label written into `HealthSample.unit` by every source (real or fake), so downstream code
/// can assert on units without importing HealthKit.
public extension HealthMetricKind {
    var canonicalUnit: String {
        switch self {
        case .bodyMass, .leanBodyMass: "kg"
        case .bodyFatPercentage: "fraction"   // HKUnit.percent() yields 0–1
        case .heartRate, .restingHeartRate, .respiratoryRate: "count/min"
        case .hrvSDNN, .hrvRMSSD: "ms"
        case .wristTemperature: "degC"
        case .steps: "count"
        case .activeEnergy, .basalEnergy: "kcal"
        case .sleep: ""
        case .workout: "min"
        case .workoutEffort: "appleEffortScore"
        }
    }

    /// Kinds whose daily cumulative sum is meaningful (`HKStatisticsOptions.cumulativeSum`).
    var isCumulative: Bool {
        switch self {
        case .steps, .activeEnergy, .basalEnergy: true
        default: false
        }
    }
}

/// Metadata keys written on every workout Setmio saves, so imported HealthKit workouts can be reconciled with
/// local sessions. Foundation-only so the iOS reconciliation code does not need HealthKit to read them.
public enum SetmioWorkoutMetadata {
    public static let sessionID = "com.setmio.sessionID"
    public static let setCount = "com.setmio.setCount"
    public static let volumeKg = "com.setmio.volumeKg"
}

/// Wraps a non-Sendable value whose thread safety is guaranteed by its owner (HealthKit objects documented as
/// thread-safe, completion handlers HealthKit calls once). Used only at the HealthKit boundary.
public struct UncheckedSendable<Value>: @unchecked Sendable {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}

public enum HealthSourceError: Error, Sendable, Equatable {
    case healthDataUnavailable
    case unsupportedKind(HealthMetricKind)
    case anchorCorrupted
    case noActiveSession

    public var messageZH: String {
        switch self {
        case .healthDataUnavailable: "此设备不支持健康数据"
        case .unsupportedKind(let kind): "不支持的健康数据类型：\(kind.rawValue)"
        case .anchorCorrupted: "增量同步锚点损坏，将重新全量导入"
        case .noActiveSession: "没有进行中的训练会话"
        }
    }
}
