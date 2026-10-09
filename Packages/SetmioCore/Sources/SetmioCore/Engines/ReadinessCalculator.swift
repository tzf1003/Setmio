import Foundation

// MARK: - Configuration

public struct ReadinessConfig: Sendable, Equatable {
    public var baselineDays = 60
    public var rollingDays = 7
    public var minimumBaselineDays = 14
    /// Score on a perfectly average day.
    public var neutralScore = 65.0
    /// Points per unit of the weighted S-score.
    public var pointsPerUnit = 15.0
    public var greenThreshold = 60
    public var redThreshold = 45
    public var zClamp = 3.0
    public var sdFloorLnHRV = 0.05
    public var sdFloorRHR = 1.5
    public var sdFloorRespiratoryRate = 0.5
    public var defaultSleepNeedMinutes = 450.0
    /// Wrist-temperature deviation (°C) above which the night counts as an outlier.
    public var temperatureOutlierDeviation = 0.5
    /// Number of outlying overnight vitals that forces a recovery day (Apple Vitals uses 2).
    public var overrideMinOutliers = 2
    public var overrideScoreCap = 35
    public var acwrWindowDays = 28

    public init() {}
}

public struct ReadinessInputs: Sendable {
    public var day: DayKey
    /// Days strictly before `day`, ascending. Gaps are allowed.
    public var history: [DailyMetrics]
    public var today: DailyMetrics
    public var weights: ReadinessWeights
    public var preferRMSSD: Bool

    public init(day: DayKey, history: [DailyMetrics], today: DailyMetrics, weights: ReadinessWeights = .default, preferRMSSD: Bool = true) {
        self.day = day
        self.history = history
        self.today = today
        self.weights = weights
        self.preferRMSSD = preferRMSSD
    }
}

public enum ReadinessResult: Sendable, Equatable {
    case score(ReadinessScore)
    case insufficientData(daysAvailable: Int, required: Int)

    public var score: ReadinessScore? {
        if case .score(let s) = self { return s }
        return nil
    }
}

// MARK: - Calculator

/// Daily readiness from overnight HRV, resting heart rate, sleep, training load and a subjective check-in,
/// each compared with the user's own rolling baseline. Pure function; no clocks read implicitly.
public struct ReadinessCalculator: Sendable {
    public let config: ReadinessConfig

    public init(config: ReadinessConfig = ReadinessConfig()) {
        self.config = config
    }

    public func compute(_ inputs: ReadinessInputs, now: Date, calendar: Calendar = .setmioDefault) -> ReadinessResult {
        let day = inputs.day
        let windowStart = day.adding(days: -config.baselineDays, calendar: calendar)
        let history = inputs.history
            .filter { $0.day < day && $0.day >= windowStart }
            .sorted { $0.day < $1.day }

        // 1. Choose one HRV metric and keep it consistent across baseline and today.
        let rmssdDays = history.filter { $0.hrvRMSSD != nil }.count
        let useRMSSD = inputs.preferRMSSD && inputs.today.hrvRMSSD != nil && rmssdDays >= config.minimumBaselineDays
        func hrv(_ m: DailyMetrics) -> Double? { useRMSSD ? m.hrvRMSSD : m.hrvSDNN }

        let baselineHRV = history.compactMap { m -> (DayKey, Double)? in
            guard let v = hrv(m), v > 0 else { return nil }
            return (m.day, log(v))
        }
        let baselineDays = baselineHRV.count
        guard baselineDays >= config.minimumBaselineDays,
              let hrvMean = Stats.mean(baselineHRV.map(\.1)) else {
            return .insufficientData(daysAvailable: baselineDays, required: config.minimumBaselineDays)
        }
        let hrvSD = max(Stats.standardDeviation(baselineHRV.map(\.1)) ?? 0, config.sdFloorLnHRV)

        var components: [ReadinessComponent] = []
        var flags: [ReadinessFlag] = []
        let w = inputs.weights

        // 2. HRV: 7-day rolling mean of ln(HRV) vs the 60-day baseline (chronic), plus today's acute deviation.
        let rollingStart = day.adding(days: -(config.rollingDays - 1), calendar: calendar)
        var rolling = baselineHRV.filter { $0.0 >= rollingStart }.map(\.1)
        let todayLnHRV: Double? = hrv(inputs.today).flatMap { $0 > 0 ? log($0) : nil }
        if let todayLnHRV { rolling.append(todayLnHRV) }
        if let rollingMean = Stats.mean(rolling) {
            let z = clampZ(Stats.zScore(rollingMean, mean: hrvMean, sd: hrvSD, sdFloor: config.sdFloorLnHRV))
            components.append(ReadinessComponent(kind: .hrv, z: z, subScore: z, weight: w.hrv))
        }
        if let todayLnHRV {
            let z = clampZ(Stats.zScore(todayLnHRV, mean: hrvMean, sd: hrvSD, sdFloor: config.sdFloorLnHRV))
            components.append(ReadinessComponent(kind: .hrvAcute, z: z, subScore: z, weight: w.hrvAcute))
        }

        // 3. Resting heart rate (higher than baseline = worse).
        let rhrBaseline = history.compactMap(\.restingHR)
        var rhrOutlier = false
        if let todayRHR = inputs.today.restingHR, rhrBaseline.count >= config.minimumBaselineDays / 2,
           let rhrMean = Stats.mean(rhrBaseline) {
            let rhrSD = max(Stats.standardDeviation(rhrBaseline) ?? 0, config.sdFloorRHR)
            let z = clampZ(-Stats.zScore(todayRHR, mean: rhrMean, sd: rhrSD, sdFloor: config.sdFloorRHR))
            components.append(ReadinessComponent(kind: .rhr, z: z, subScore: z, weight: w.rhr))
            rhrOutlier = todayRHR > rhrMean + 2 * rhrSD
        }

        // 4. Sleep: last 3 nights vs personal need (median of the baseline window, default 7.5 h).
        if let todaySleep = inputs.today.sleep {
            let needCandidates = history.compactMap { $0.sleep?.asleepMinutes }
            let need = needCandidates.count >= 7 ? (Stats.median(needCandidates) ?? config.defaultSleepNeedMinutes) : config.defaultSleepNeedMinutes
            let threeNightStart = day.adding(days: -2, calendar: calendar)
            var nights = history.filter { $0.day >= threeNightStart }.compactMap { $0.sleep?.asleepMinutes }
            nights.append(todaySleep.asleepMinutes)
            let ratio = (Stats.mean(nights) ?? todaySleep.asleepMinutes) / max(need, 60)
            let sub = Stats.clamp((ratio - 1.0) * 4.0, -2.0, 0.5)
            components.append(ReadinessComponent(kind: .sleep, z: nil, subScore: sub, weight: w.sleep))
        }

        // 5. Training load: acute (7 d) : chronic (28 d) ratio of effort × minutes.
        let loadWindowStart = day.adding(days: -(config.acwrWindowDays - 1), calendar: calendar)
        let loadDays = history.filter { $0.day >= loadWindowStart }
        if loadDays.count >= config.minimumBaselineDays {
            var byDay: [DayKey: Double] = [:]
            for m in loadDays { byDay[m.day] = m.trainingLoad ?? 0 }
            byDay[day] = inputs.today.trainingLoad ?? 0
            let allDays = DayKey.range(from: loadWindowStart, to: day, calendar: calendar)
            let chronicValues = allDays.map { byDay[$0] ?? 0 }
            let acuteValues = allDays.suffix(config.rollingDays).map { byDay[$0] ?? 0 }
            let chronic = Stats.mean(chronicValues) ?? 0
            let acute = Stats.mean(acuteValues) ?? 0
            if chronic > 0 {
                let acwr = acute / chronic
                var sub = 0.0
                if acwr > 1.5 {
                    sub = -1.5
                } else if acwr > 1.2 {
                    sub = -0.75 * (acwr - 1.2) / 0.3
                } else if acwr < 0.5 {
                    flags.append(.detraining)
                }
                components.append(ReadinessComponent(kind: .load, z: acwr, subScore: sub, weight: w.load))
            }
        }

        // 6. Subjective check-in (energy/mood up = better; soreness/stress up = worse).
        if let s = inputs.today.subjective {
            let v = (Double(s.energy - 3) + Double(s.mood - 3) + Double(3 - s.soreness) + Double(3 - s.stress)) / 4.0
            let sub = Stats.clamp(v * 0.5, -1.0, 1.0)
            components.append(ReadinessComponent(kind: .subjective, z: nil, subScore: sub, weight: w.subjective))
        }

        // 7. Weighted S-score, renormalised over the components that are available.
        let availableWeight = components.reduce(0) { $0 + $1.weight }
        guard availableWeight > 0 else {
            return .insufficientData(daysAvailable: baselineDays, required: config.minimumBaselineDays)
        }
        let s = components.reduce(0) { $0 + $1.weight * $1.subScore } / availableWeight
        var score = Int((config.neutralScore + config.pointsPerUnit * s).rounded())
        score = max(0, min(100, score))

        // 8. Apple-Vitals-style override: ≥ 2 overnight vitals outside the personal range → recovery day.
        var outliers = rhrOutlier ? 1 : 0
        if let todayLnHRV, todayLnHRV < hrvMean - 2 * hrvSD { outliers += 1 }
        let rrBaseline = history.compactMap(\.overnightRespiratoryRate)
        if let rr = inputs.today.overnightRespiratoryRate, rrBaseline.count >= config.minimumBaselineDays / 2,
           let rrMean = Stats.mean(rrBaseline) {
            let rrSD = max(Stats.standardDeviation(rrBaseline) ?? 0, config.sdFloorRespiratoryRate)
            if rr > rrMean + 2 * rrSD { outliers += 1 }
        }
        if let dev = inputs.today.wristTemperatureDeviation, dev > config.temperatureOutlierDeviation {
            outliers += 1
        }
        if outliers >= config.overrideMinOutliers {
            score = min(score, config.overrideScoreCap)
            flags.append(.recoveryDayOverride)
        }

        let confidence = min(1.0, Double(baselineDays) / Double(config.baselineDays)) * (availableWeight / max(w.total, 0.0001))
        if baselineDays < 28 || confidence < 0.5 { flags.append(.lowConfidence) }

        let band: ReadinessBand = score >= config.greenThreshold ? .green : (score >= config.redThreshold ? .yellow : .red)
        return .score(ReadinessScore(
            day: day,
            score: score,
            band: band,
            confidence: (confidence * 100).rounded() / 100,
            components: components,
            flags: flags,
            baselineDays: baselineDays,
            computedAt: now
        ))
    }

    private func clampZ(_ z: Double) -> Double {
        Stats.clamp(z, -config.zClamp, config.zClamp)
    }
}

// MARK: - Daily metrics aggregation (overnight window → DailyMetrics)

/// Turns raw samples around one day into `DailyMetrics`. HealthKit-specific fetching lives in SetmioHealth;
/// this is the pure part so it can be unit-tested with synthetic samples.
public enum DailyMetricsAggregation {
    public struct Input: Sendable {
        public var day: DayKey
        public var sleepSamples: [HealthSample]
        public var hrvSDNNSamples: [HealthSample]
        public var hrvRMSSDSamples: [HealthSample]
        public var heartbeatSeries: [HeartbeatSeries]
        public var heartRateSamples: [HealthSample]
        public var restingHeartRateSamples: [HealthSample]
        public var respiratoryRateSamples: [HealthSample]
        public var wristTemperatureSamples: [HealthSample]
        public var steps: Int?
        public var activeEnergy: Kilocalories?
        public var basalEnergy: Kilocalories?
        public var workoutEffort: Int?
        public var trainingLoad: Double?
        public var subjective: SubjectiveCheckIn?
        /// Personal baseline wrist temperature (mean of previous nights), used to compute the deviation.
        public var baselineWristTemperature: Double?
        /// Previously stored metrics for the same day (keeps a frozen RHR).
        public var existing: DailyMetrics?
        public var settings: Settings
        public var now: Date

        public init(
            day: DayKey,
            sleepSamples: [HealthSample] = [],
            hrvSDNNSamples: [HealthSample] = [],
            hrvRMSSDSamples: [HealthSample] = [],
            heartbeatSeries: [HeartbeatSeries] = [],
            heartRateSamples: [HealthSample] = [],
            restingHeartRateSamples: [HealthSample] = [],
            respiratoryRateSamples: [HealthSample] = [],
            wristTemperatureSamples: [HealthSample] = [],
            steps: Int? = nil,
            activeEnergy: Kilocalories? = nil,
            basalEnergy: Kilocalories? = nil,
            workoutEffort: Int? = nil,
            trainingLoad: Double? = nil,
            subjective: SubjectiveCheckIn? = nil,
            baselineWristTemperature: Double? = nil,
            existing: DailyMetrics? = nil,
            settings: Settings = .default,
            now: Date
        ) {
            self.day = day
            self.sleepSamples = sleepSamples
            self.hrvSDNNSamples = hrvSDNNSamples
            self.hrvRMSSDSamples = hrvRMSSDSamples
            self.heartbeatSeries = heartbeatSeries
            self.heartRateSamples = heartRateSamples
            self.restingHeartRateSamples = restingHeartRateSamples
            self.respiratoryRateSamples = respiratoryRateSamples
            self.wristTemperatureSamples = wristTemperatureSamples
            self.steps = steps
            self.activeEnergy = activeEnergy
            self.basalEnergy = basalEnergy
            self.workoutEffort = workoutEffort
            self.trainingLoad = trainingLoad
            self.subjective = subjective
            self.baselineWristTemperature = baselineWristTemperature
            self.existing = existing
            self.settings = settings
            self.now = now
        }
    }

    /// The window in which "overnight" samples are searched when no sleep is recorded: 22:00 the evening before to 10:00.
    public static func fallbackNightWindow(for day: DayKey, calendar: Calendar) -> ClosedRange<Date> {
        let start = day.adding(days: -1, calendar: calendar).date(atHour: 22, calendar: calendar)
        let end = day.date(atHour: 10, calendar: calendar)
        return start...end
    }

    public static func aggregate(_ input: Input) -> DailyMetrics {
        let calendar = input.settings.calendar
        var metrics = input.existing ?? DailyMetrics(day: input.day)
        metrics.day = input.day

        let sleep = detectSleepWindow(samples: input.sleepSamples)
        metrics.sleep = sleep ?? metrics.sleep
        let window: ClosedRange<Date> = sleep.map { $0.start...$0.end } ?? fallbackNightWindow(for: input.day, calendar: calendar)

        func inWindow(_ s: HealthSample) -> Bool { window.contains(s.start) }

        // HRV: median of overnight samples (robust to a single spike).
        let sdnn = input.hrvSDNNSamples.filter(inWindow).map(\.value)
        if let m = Stats.median(sdnn) { metrics.hrvSDNN = m }
        var rmssdValues = input.hrvRMSSDSamples.filter(inWindow).map(\.value)
        if rmssdValues.isEmpty {
            rmssdValues = input.heartbeatSeries.filter { window.contains($0.start) }.compactMap(\.rmssd)
        }
        if let m = Stats.median(rmssdValues) { metrics.hrvRMSSD = m }

        // Resting HR: Apple's value if present, else 5th percentile of overnight HR; frozen after the freeze hour.
        if metrics.restingHRFrozenAt == nil {
            let appleRHR = input.restingHeartRateSamples.sorted { $0.start < $1.start }.last?.value
            let overnightHR = input.heartRateSamples.filter(inWindow).map(\.value)
            let candidate = appleRHR ?? Stats.percentile(overnightHR, 5)
            if let candidate {
                metrics.restingHR = candidate
                let freezeTime = input.day.date(atHour: input.settings.rhrFreezeHour, calendar: calendar)
                if input.now >= freezeTime { metrics.restingHRFrozenAt = input.now }
            }
        }

        if let rr = Stats.median(input.respiratoryRateSamples.filter(inWindow).map(\.value)) {
            metrics.overnightRespiratoryRate = rr
        }
        if let temp = input.wristTemperatureSamples.filter(inWindow).sorted(by: { $0.start < $1.start }).last?.value
            ?? input.wristTemperatureSamples.sorted(by: { $0.start < $1.start }).last?.value {
            metrics.wristTemperature = temp
            if let baseline = input.baselineWristTemperature {
                metrics.wristTemperatureDeviation = temp - baseline
            }
        }

        if let steps = input.steps { metrics.steps = steps }
        if let e = input.activeEnergy { metrics.activeEnergy = e }
        if let e = input.basalEnergy { metrics.basalEnergy = e }
        if let effort = input.workoutEffort { metrics.workoutEffort = effort }
        if let load = input.trainingLoad { metrics.trainingLoad = load }
        if let s = input.subjective { metrics.subjective = s }
        return metrics
    }

    /// Main sleep block: asleep samples from the source with the most sleep, merged across gaps shorter than
    /// `mergeGapMinutes`, longest block wins.
    public static func detectSleepWindow(samples: [HealthSample], mergeGapMinutes: Double = 30) -> SleepWindow? {
        let asleep = samples.filter { $0.kind == .sleep && ($0.sleepStage?.isAsleep ?? false) }
        guard !asleep.isEmpty else { return nil }

        // Prefer the source with the most recorded sleep (typically the watch).
        var minutesBySource: [String: Double] = [:]
        for s in asleep {
            minutesBySource[s.sourceBundleID ?? "", default: 0] += s.end.timeIntervalSince(s.start) / 60
        }
        let bestSource = minutesBySource.max { $0.value < $1.value }?.key ?? ""
        let chosen = asleep.filter { ($0.sourceBundleID ?? "") == bestSource }.sorted { $0.start < $1.start }

        // Merge into blocks.
        var blocks: [[HealthSample]] = []
        for s in chosen {
            if var last = blocks.last, let lastEnd = last.map(\.end).max(),
               s.start.timeIntervalSince(lastEnd) <= mergeGapMinutes * 60 {
                last.append(s)
                blocks[blocks.count - 1] = last
            } else {
                blocks.append([s])
            }
        }
        guard let block = blocks.max(by: { span($0) < span($1) }), let start = block.map(\.start).min(), let end = block.map(\.end).max() else {
            return nil
        }

        func minutes(_ stage: SleepStage) -> Double {
            block.filter { $0.sleepStage == stage }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) / 60 }
        }
        let asleepMinutes = block.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) / 60 }
        let awakeMinutes = samples
            .filter { $0.kind == .sleep && $0.sleepStage == .awake && ($0.sourceBundleID ?? "") == bestSource && $0.start >= start && $0.end <= end }
            .reduce(0) { $0 + $1.end.timeIntervalSince($1.start) / 60 }

        return SleepWindow(
            start: start,
            end: end,
            asleepMinutes: asleepMinutes,
            deepMinutes: minutes(.asleepDeep),
            remMinutes: minutes(.asleepREM),
            coreMinutes: minutes(.asleepCore) + minutes(.asleepUnspecified),
            awakeMinutes: awakeMinutes
        )
    }

    private static func span(_ block: [HealthSample]) -> TimeInterval {
        guard let start = block.map(\.start).min(), let end = block.map(\.end).max() else { return 0 }
        return end.timeIntervalSince(start)
    }
}
