import Foundation

// MARK: - Raw samples (value-type mirror of HealthKit samples; produced by SetmioHealth)

public enum HealthMetricKind: String, Codable, Sendable, CaseIterable, Hashable {
    case bodyMass, bodyFatPercentage, leanBodyMass
    case heartRate, restingHeartRate
    case hrvSDNN, hrvRMSSD
    case respiratoryRate, wristTemperature
    case steps, activeEnergy, basalEnergy
    case sleep
    case workout, workoutEffort

    /// Types imported in the MVP phase.
    public static let mvp: [HealthMetricKind] = [
        .bodyMass, .bodyFatPercentage, .leanBodyMass,
        .heartRate, .restingHeartRate, .hrvSDNN,
        .respiratoryRate, .wristTemperature,
        .steps, .activeEnergy, .basalEnergy,
        .sleep, .workout, .workoutEffort,
    ]
}

/// Sleep stage, mirroring `HKCategoryValueSleepAnalysis` raw values.
public enum SleepStage: Int, Codable, Sendable, Hashable {
    case inBed = 0
    case asleepUnspecified = 1
    case awake = 2
    case asleepCore = 3
    case asleepDeep = 4
    case asleepREM = 5

    public var isAsleep: Bool {
        switch self {
        case .asleepUnspecified, .asleepCore, .asleepDeep, .asleepREM: true
        case .inBed, .awake: false
        }
    }
}

public struct HealthSample: Sendable, Codable, Hashable {
    public var hkUUID: UUID
    public var kind: HealthMetricKind
    public var value: Double
    public var unit: String
    public var start: Date
    public var end: Date
    public var sourceBundleID: String?
    /// For `.sleep`: the `SleepStage` raw value. For `.workout`: the HK activity type raw value.
    public var categoryValue: Int?

    public init(
        hkUUID: UUID = UUID(),
        kind: HealthMetricKind,
        value: Double,
        unit: String,
        start: Date,
        end: Date,
        sourceBundleID: String? = nil,
        categoryValue: Int? = nil
    ) {
        self.hkUUID = hkUUID
        self.kind = kind
        self.value = value
        self.unit = unit
        self.start = start
        self.end = end
        self.sourceBundleID = sourceBundleID
        self.categoryValue = categoryValue
    }

    public var sleepStage: SleepStage? {
        guard kind == .sleep, let categoryValue else { return nil }
        return SleepStage(rawValue: categoryValue)
    }
}

/// Beat-to-beat intervals from one `HKHeartbeatSeriesSample`, used to compute RMSSD locally.
public struct HeartbeatSeries: Sendable, Codable, Hashable {
    public var hkUUID: UUID
    public var start: Date
    public var end: Date
    /// Seconds since `start` for each detected beat, in order.
    public var beatTimes: [Double]
    /// Indices of beats preceded by a gap (dropped beats); the interval before them is excluded.
    public var gapIndices: [Int]

    public init(hkUUID: UUID = UUID(), start: Date, end: Date, beatTimes: [Double], gapIndices: [Int] = []) {
        self.hkUUID = hkUUID
        self.start = start
        self.end = end
        self.beatTimes = beatTimes
        self.gapIndices = gapIndices
    }

    /// RMSSD in milliseconds, or nil with fewer than 2 usable intervals.
    public var rmssd: Milliseconds? {
        guard beatTimes.count >= 3 else { return nil }
        let gaps = Set(gapIndices)
        var intervals: [Double] = []
        for i in 1..<beatTimes.count where !gaps.contains(i) {
            intervals.append((beatTimes[i] - beatTimes[i - 1]) * 1000)
        }
        guard intervals.count >= 2 else { return nil }
        var sumSq = 0.0
        var n = 0
        for i in 1..<intervals.count {
            let d = intervals[i] - intervals[i - 1]
            sumSq += d * d
            n += 1
        }
        guard n > 0 else { return nil }
        return (sumSq / Double(n)).squareRoot()
    }
}

// MARK: - Daily aggregates

public struct SleepWindow: Sendable, Codable, Equatable, Hashable {
    public var start: Date
    public var end: Date
    public var asleepMinutes: Minutes
    public var deepMinutes: Minutes
    public var remMinutes: Minutes
    public var coreMinutes: Minutes
    public var awakeMinutes: Minutes

    public init(start: Date, end: Date, asleepMinutes: Minutes, deepMinutes: Minutes = 0, remMinutes: Minutes = 0, coreMinutes: Minutes = 0, awakeMinutes: Minutes = 0) {
        self.start = start
        self.end = end
        self.asleepMinutes = asleepMinutes
        self.deepMinutes = deepMinutes
        self.remMinutes = remMinutes
        self.coreMinutes = coreMinutes
        self.awakeMinutes = awakeMinutes
    }
}

public struct SubjectiveCheckIn: Sendable, Codable, Equatable, Hashable {
    /// Each 1 (worst) … 5 (best); soreness and stress are inverted inside the engine.
    public var energy: Int
    public var soreness: Int
    public var mood: Int
    public var stress: Int

    public init(energy: Int, soreness: Int, mood: Int, stress: Int) {
        self.energy = energy
        self.soreness = soreness
        self.mood = mood
        self.stress = stress
    }
}

public struct DailyMetrics: Sendable, Codable, Equatable, Hashable {
    public var day: DayKey
    public var hrvSDNN: Milliseconds?
    public var hrvRMSSD: Milliseconds?
    public var restingHR: BeatsPerMinute?
    public var restingHRFrozenAt: Date?
    public var overnightRespiratoryRate: Double?
    public var wristTemperature: Double?
    public var wristTemperatureDeviation: Double?
    public var sleep: SleepWindow?
    public var steps: Int?
    public var activeEnergy: Kilocalories?
    public var basalEnergy: Kilocalories?
    public var workoutEffort: Int?
    /// Sum over the day of effort (0–10) × minutes, Apple Training Load style.
    public var trainingLoad: Double?
    public var subjective: SubjectiveCheckIn?

    public init(
        day: DayKey,
        hrvSDNN: Milliseconds? = nil,
        hrvRMSSD: Milliseconds? = nil,
        restingHR: BeatsPerMinute? = nil,
        restingHRFrozenAt: Date? = nil,
        overnightRespiratoryRate: Double? = nil,
        wristTemperature: Double? = nil,
        wristTemperatureDeviation: Double? = nil,
        sleep: SleepWindow? = nil,
        steps: Int? = nil,
        activeEnergy: Kilocalories? = nil,
        basalEnergy: Kilocalories? = nil,
        workoutEffort: Int? = nil,
        trainingLoad: Double? = nil,
        subjective: SubjectiveCheckIn? = nil
    ) {
        self.day = day
        self.hrvSDNN = hrvSDNN
        self.hrvRMSSD = hrvRMSSD
        self.restingHR = restingHR
        self.restingHRFrozenAt = restingHRFrozenAt
        self.overnightRespiratoryRate = overnightRespiratoryRate
        self.wristTemperature = wristTemperature
        self.wristTemperatureDeviation = wristTemperatureDeviation
        self.sleep = sleep
        self.steps = steps
        self.activeEnergy = activeEnergy
        self.basalEnergy = basalEnergy
        self.workoutEffort = workoutEffort
        self.trainingLoad = trainingLoad
        self.subjective = subjective
    }
}

// MARK: - Readiness

public enum ReadinessBand: String, Sendable, Codable, Hashable {
    case green, yellow, red
}

public enum ReadinessFlag: String, Sendable, Codable, Hashable {
    /// ≥ 2 overnight vitals outside the personal range → forced recovery day (Apple Vitals style).
    case recoveryDayOverride
    /// Acute:chronic load ratio < 0.5 — the user has been training much less than usual.
    case detraining
    /// Baseline shorter than the full window; the score is provisional.
    case lowConfidence
}

public struct ReadinessComponent: Sendable, Codable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case hrv, hrvAcute, rhr, sleep, load, subjective
    }

    public var kind: Kind
    public var z: Double?
    /// Contribution in "S units" (z-like, clamped).
    public var subScore: Double
    public var weight: Double

    public init(kind: Kind, z: Double?, subScore: Double, weight: Double) {
        self.kind = kind
        self.z = z
        self.subScore = subScore
        self.weight = weight
    }
}

public struct ReadinessScore: Sendable, Codable, Equatable, Hashable {
    public var day: DayKey
    /// 0–100.
    public var score: Int
    public var band: ReadinessBand
    /// 0–1: how much of the baseline window and the component set were available.
    public var confidence: Double
    public var components: [ReadinessComponent]
    public var flags: [ReadinessFlag]
    public var baselineDays: Int
    public var computedAt: Date

    public init(day: DayKey, score: Int, band: ReadinessBand, confidence: Double, components: [ReadinessComponent], flags: [ReadinessFlag], baselineDays: Int, computedAt: Date) {
        self.day = day
        self.score = score
        self.band = band
        self.confidence = confidence
        self.components = components
        self.flags = flags
        self.baselineDays = baselineDays
        self.computedAt = computedAt
    }
}

// MARK: - Body composition

public struct BodyMeasurement: Identifiable, Sendable, Codable, Equatable, Hashable {
    public var id: SetmioCore.ID<BodyMeasurement>
    public var hkUUID: UUID?
    public var date: Date
    public var weight: Kilograms?
    /// Fraction 0–1.
    public var bodyFat: Double?
    public var leanMass: Kilograms?
    public var source: String

    public init(id: SetmioCore.ID<BodyMeasurement> = SetmioCore.ID(), hkUUID: UUID? = nil, date: Date, weight: Kilograms?, bodyFat: Double? = nil, leanMass: Kilograms? = nil, source: String) {
        self.id = id
        self.hkUUID = hkUUID
        self.date = date
        self.weight = weight
        self.bodyFat = bodyFat
        self.leanMass = leanMass
        self.source = source
    }
}

/// A workout imported from HealthKit (any source), used to reconcile with locally logged sessions.
public struct ImportedWorkout: Sendable, Codable, Equatable, Hashable {
    public var hkUUID: UUID
    public var start: Date
    public var end: Date
    public var activityTypeRawValue: Int
    public var totalEnergy: Kilocalories?
    public var effortScore: Int?
    public var sourceBundleID: String?
    public var setmioSessionID: SetmioCore.ID<LoggedSession>?

    public init(hkUUID: UUID, start: Date, end: Date, activityTypeRawValue: Int, totalEnergy: Kilocalories? = nil, effortScore: Int? = nil, sourceBundleID: String? = nil, setmioSessionID: SetmioCore.ID<LoggedSession>? = nil) {
        self.hkUUID = hkUUID
        self.start = start
        self.end = end
        self.activityTypeRawValue = activityTypeRawValue
        self.totalEnergy = totalEnergy
        self.effortScore = effortScore
        self.sourceBundleID = sourceBundleID
        self.setmioSessionID = setmioSessionID
    }

    public var durationMinutes: Minutes { end.timeIntervalSince(start) / 60 }
}
