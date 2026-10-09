import Foundation

public struct EnergyObservation: Sendable, Equatable {
    public var day: DayKey
    public var weight: Kilograms?
    public var intakeKcal: Kilocalories?
    /// 0–1: share of the day's meals that were logged (1 when fully logged).
    public var loggedMealsRatio: Double

    public init(day: DayKey, weight: Kilograms?, intakeKcal: Kilocalories?, loggedMealsRatio: Double = 1) {
        self.day = day
        self.weight = weight
        self.intakeKcal = intakeKcal
        self.loggedMealsRatio = loggedMealsRatio
    }
}

public struct EnergyConfig: Sendable, Equatable {
    /// EMA weight of the newest weigh-in (≈ 20-day lag at 0.1).
    public var emaAlpha = 0.1
    /// Fat share of tissue change; lower early in a diet or on GLP-1 without strength training.
    public var fatFraction = 0.75
    public var kcalPerKgFat = 9440.0
    public var kcalPerKgLean = 1817.0
    public var initialVariance = 400.0 * 400.0
    public var processNoise = 50.0 * 50.0
    /// Measurement noise at full logging completeness (kcal/day).
    public var baseMeasurementNoise = 300.0
    /// Below this completeness the estimate is paused (> 3 of 7 days unlogged).
    public var minCompleteness = 4.0 / 7.0
    public var maxChangePerUpdate = 150.0
    public var windowDays = 14

    public init() {}

    /// Energy density of a kg of weight change under `fatFraction`.
    public var energyDensityPerKg: Double {
        kcalPerKgFat * fatFraction + kcalPerKgLean * (1 - fatFraction)
    }
}

/// Adaptive total daily energy expenditure: Mifflin-St Jeor prior, then a Kalman-style update from logged intake
/// and the trended body-weight slope ("expenditure = intake − stored energy change").
public struct EnergyBalanceEstimator: Sendable {
    public let config: EnergyConfig

    public init(config: EnergyConfig = EnergyConfig()) {
        self.config = config
    }

    public static func mifflinStJeorBMR(sex: BiologicalSex, weight: Kilograms, heightCm: Double, age: Int) -> Kilocalories {
        let base = 10 * weight + 6.25 * heightCm - 5 * Double(age)
        switch sex {
        case .male: return base + 5
        case .female: return base - 161
        case .other: return base - 78
        }
    }

    public static func initialEstimate(profile: UserProfile, weight: Kilograms, age: Int, day: DayKey, config: EnergyConfig = EnergyConfig()) -> EnergyEstimate {
        let bmr = mifflinStJeorBMR(sex: profile.sex, weight: weight, heightCm: profile.heightCm, age: age)
        return EnergyEstimate(day: day, tdee: (bmr * profile.activityFactor).rounded(), variance: config.initialVariance, trendWeight: weight, windowDays: config.windowDays)
    }

    /// One update step over a window of daily observations (ascending by day).
    public func update(_ state: EnergyEstimate, with window: [EnergyObservation]) -> EnergyEstimate {
        let observations = window.sorted { $0.day < $1.day }
        var next = state
        guard let lastDay = observations.last?.day else { return next }
        next.day = lastDay
        next.windowDays = observations.count

        // Trend weight via EMA, seeded from the previous trend (or the first weigh-in).
        let weighIns = observations.compactMap { obs -> (DayKey, Double)? in
            guard let w = obs.weight else { return nil }
            return (obs.day, w)
        }
        var trendPoints: [(Double, Double)] = []
        if !weighIns.isEmpty {
            let seed = state.trendWeight > 0 ? state.trendWeight : weighIns[0].1
            let trend = Stats.ema(weighIns.map(\.1), alpha: config.emaAlpha, seed: seed)
            let origin = weighIns[0].0
            for (index, point) in weighIns.enumerated() {
                trendPoints.append((Double(point.0.daysSince(origin)), trend[index]))
            }
            next.trendWeight = trend.last ?? state.trendWeight
        }
        let slopePerDay = Stats.linearSlope(x: trendPoints.map(\.0), y: trendPoints.map(\.1)) ?? 0
        next.trendSlopePerWeek = (slopePerDay * 7 * 1000).rounded() / 1000

        // Logging completeness gates the expenditure update.
        let intakes = observations.compactMap(\.intakeKcal)
        let completeness = observations.isEmpty ? 0 : observations.reduce(0.0) { $0 + ($1.intakeKcal == nil ? 0 : $1.loggedMealsRatio) } / Double(observations.count)
        next.loggingCompleteness = (completeness * 100).rounded() / 100
        guard completeness >= config.minCompleteness, let meanIntake = Stats.mean(intakes), trendPoints.count >= 2 else {
            return next
        }

        let measured = meanIntake - slopePerDay * config.energyDensityPerKg
        let r = pow(config.baseMeasurementNoise / max(completeness, 0.2), 2)
        let p = state.variance
        let gain = p / (p + r)
        var delta = gain * (measured - state.tdee)
        delta = Stats.clamp(delta, -config.maxChangePerUpdate, config.maxChangePerUpdate)
        next.tdee = (state.tdee + delta).rounded()
        next.variance = (1 - gain) * p + config.processNoise
        return next
    }

    /// Daily deficit (positive number) for a target loss rate in percent of body weight per week.
    public func dailyDeficit(weight: Kilograms, ratePercentPerWeek: Double) -> Kilocalories {
        let kgPerWeek = weight * ratePercentPerWeek / 100
        return (kgPerWeek * config.energyDensityPerKg / 7).rounded()
    }

    /// Intake target with the profile's kcal floor applied; `floorHit` tells the UI to warn.
    public func intakeTarget(tdee: Kilocalories, deficit: Kilocalories, profile: UserProfile) -> (target: Kilocalories, floorHit: Bool) {
        let raw = tdee - deficit
        if raw < profile.kcalFloor { return (profile.kcalFloor, true) }
        return (raw.rounded(), false)
    }
}
