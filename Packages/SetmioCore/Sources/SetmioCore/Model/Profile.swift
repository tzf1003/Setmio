import Foundation

public enum BiologicalSex: String, Codable, Sendable, Hashable, CaseIterable {
    case male, female, other
}

/// Which protein standard the user (and their clinician) chose.
public enum ProteinStandard: Sendable, Codable, Equatable, Hashable {
    /// g per kg of current body weight (US advisory 1.2–1.6; lifters 1.6–2.2).
    case perKgBodyweight(gPerKg: Double)
    /// g per kg of ideal body weight (China 2026 draft: 1.0–1.2; ideal = height cm − 105).
    case perKgIdealBodyweight(gPerKg: Double)
    /// g per kg of fat-free mass (e.g. 1.5 or 2.2).
    case perKgLeanMass(gPerKg: Double)
    /// Fixed daily grams (e.g. 80–120).
    case fixedGrams(Double)

    public static let usAdvisory = ProteinStandard.perKgBodyweight(gPerKg: 1.6)
    public static let chinaDraft = ProteinStandard.perKgIdealBodyweight(gPerKg: 1.2)
}

public struct UserProfile: Sendable, Codable, Equatable, Hashable {
    public var sex: BiologicalSex
    public var heightCm: Double
    public var birthDate: DayKey
    public var goalWeight: Kilograms?
    public var proteinStandard: ProteinStandard
    /// Multiplier on BMR for the initial expenditure estimate (1.2 sedentary … 1.725 very active).
    public var activityFactor: Double
    /// Turns on lean-mass protection rules (protein floor, ≥3 strength sessions/week, rate alerts).
    public var glp1Mode: Bool

    public init(
        sex: BiologicalSex,
        heightCm: Double,
        birthDate: DayKey,
        goalWeight: Kilograms? = nil,
        proteinStandard: ProteinStandard = .usAdvisory,
        activityFactor: Double = 1.375,
        glp1Mode: Bool = false
    ) {
        self.sex = sex
        self.heightCm = heightCm
        self.birthDate = birthDate
        self.goalWeight = goalWeight
        self.proteinStandard = proteinStandard
        self.activityFactor = activityFactor
        self.glp1Mode = glp1Mode
    }

    public func age(on day: DayKey, calendar: Calendar = .setmioDefault) -> Int {
        max(0, day.daysSince(birthDate, calendar: calendar) / 365)
    }

    /// Ideal body weight per the China draft standard (height − 105), floored at 40 kg.
    public var idealBodyWeight: Kilograms {
        max(40, heightCm - 105)
    }

    /// Daily kcal floor below which nutrient adequacy is at risk (1200 women / 1800 men).
    public var kcalFloor: Kilocalories {
        switch sex {
        case .female: 1200
        case .male: 1800
        case .other: 1500
        }
    }

    public func proteinTargetGrams(weight: Kilograms, leanMass: Kilograms?) -> Grams {
        switch proteinStandard {
        case .perKgBodyweight(let g): g * weight
        case .perKgIdealBodyweight(let g): g * idealBodyWeight
        case .perKgLeanMass(let g): g * (leanMass ?? weight * 0.75)
        case .fixedGrams(let grams): grams
        }
    }
}

public struct ReadinessWeights: Sendable, Codable, Equatable, Hashable {
    public var hrv: Double
    public var hrvAcute: Double
    public var rhr: Double
    public var sleep: Double
    public var load: Double
    public var subjective: Double

    public init(hrv: Double = 0.35, hrvAcute: Double = 0.10, rhr: Double = 0.15, sleep: Double = 0.20, load: Double = 0.10, subjective: Double = 0.10) {
        self.hrv = hrv
        self.hrvAcute = hrvAcute
        self.rhr = rhr
        self.sleep = sleep
        self.load = load
        self.subjective = subjective
    }

    public static let `default` = ReadinessWeights()

    public var total: Double { hrv + hrvAcute + rhr + sleep + load + subjective }
}

/// Engine-relevant settings. UI preferences live in UserDefaults, not here.
public struct Settings: Sendable, Codable, Equatable, Hashable {
    /// Local hour after which the day's resting heart rate is frozen.
    public var rhrFreezeHour: Int
    public var readinessWeights: ReadinessWeights
    public var defaultRestSeconds: [ExerciseCategory: Int]
    public var timeZoneIdentifier: String
    public var demoDataEnabled: Bool
    /// Preferred HRV metric; the engine falls back to SDNN when RMSSD is unavailable.
    public var preferRMSSD: Bool

    public init(
        rhrFreezeHour: Int = 10,
        readinessWeights: ReadinessWeights = .default,
        defaultRestSeconds: [ExerciseCategory: Int] = [.compound: 180, .isolation: 90],
        timeZoneIdentifier: String = "Asia/Shanghai",
        demoDataEnabled: Bool = false,
        preferRMSSD: Bool = true
    ) {
        self.rhrFreezeHour = rhrFreezeHour
        self.readinessWeights = readinessWeights
        self.defaultRestSeconds = defaultRestSeconds
        self.timeZoneIdentifier = timeZoneIdentifier
        self.demoDataEnabled = demoDataEnabled
        self.preferRMSSD = preferRMSSD
    }

    public static let `default` = Settings()

    public var calendar: Calendar { .setmio(timeZoneIdentifier: timeZoneIdentifier) }
}
