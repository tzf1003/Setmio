import Foundation
import Testing
@testable import SetmioCore

@Suite("ReadinessCalculator")
struct ReadinessTests {
    let calculator = ReadinessCalculator()

    @Test("average day on a 30-day baseline scores in the neutral band with half confidence")
    func neutralDay() throws {
        let history = Fixture.history(days: 30, hrv: { $0 % 2 == 0 ? 48 : 52 })
        let inputs = ReadinessInputs(day: Fixture.today, history: history, today: Fixture.todayMetrics())
        let result = calculator.compute(inputs, now: Fixture.now, calendar: Fixture.calendar)
        let score = try #require(result.score)
        #expect((58...72).contains(score.score), "score was \(score.score)")
        #expect(score.band == .green)
        #expect(abs(score.confidence - 0.5) < 0.06, "confidence was \(score.confidence)")
        #expect(score.baselineDays == 30)
        #expect(score.components.contains { $0.kind == .load })
    }

    @Test("a bad week (low HRV, high RHR, short sleep, poor check-in) is red")
    func badWeek() throws {
        let history = Fixture.history(
            days: 30,
            hrv: { $0 <= 7 ? 35 : 50 },
            rhr: { $0 <= 7 ? 64 : 55 },
            sleepMinutes: { $0 <= 2 ? 300 : 450 }
        )
        let today = Fixture.todayMetrics(hrv: 33, rhr: 66, sleepMinutes: 300, subjective: SubjectiveCheckIn(energy: 1, soreness: 5, mood: 2, stress: 5))
        let result = calculator.compute(ReadinessInputs(day: Fixture.today, history: history, today: today), now: Fixture.now, calendar: Fixture.calendar)
        let score = try #require(result.score)
        #expect(score.score < 45, "score was \(score.score)")
        #expect(score.band == .red)
        let hrv = try #require(score.components.first { $0.kind == .hrv })
        #expect((hrv.z ?? 0) < 0)
    }

    @Test("fewer than 14 baseline days is insufficient data")
    func insufficient() {
        let history = Fixture.history(days: 10)
        let result = calculator.compute(ReadinessInputs(day: Fixture.today, history: history, today: Fixture.todayMetrics()), now: Fixture.now, calendar: Fixture.calendar)
        #expect(result == .insufficientData(daysAvailable: 10, required: 14))
    }

    @Test("two outlying overnight vitals force a recovery day")
    func vitalsOverride() throws {
        let history = Fixture.history(days: 30)
        let today = Fixture.todayMetrics(hrv: 30, rhr: 65)
        let score = try #require(calculator.compute(ReadinessInputs(day: Fixture.today, history: history, today: today), now: Fixture.now, calendar: Fixture.calendar).score)
        #expect(score.score <= 35)
        #expect(score.flags.contains(.recoveryDayOverride))
        #expect(score.band == .red)
    }

    @Test("RMSSD is preferred over SDNN only when both today and the baseline have it")
    func metricSelection() throws {
        var history = Fixture.history(days: 30)
        for i in history.indices { history[i].hrvRMSSD = 40 }
        var today = Fixture.todayMetrics()
        today.hrvRMSSD = 40
        today.hrvSDNN = 10   // would be a huge drop if SDNN were used
        let score = try #require(calculator.compute(ReadinessInputs(day: Fixture.today, history: history, today: today), now: Fixture.now, calendar: Fixture.calendar).score)
        #expect(score.score >= 58, "RMSSD path should ignore the SDNN outlier; score was \(score.score)")
    }

    @Test("golden cases")
    func golden() throws {
        struct Spec: Decodable {
            struct Values: Decodable { var hrv: Double; var rhr: Double; var sleepMinutes: Double }
            var name: String
            var historyDays: Int
            var baseline: Values
            var today: Values
            var expectedScore: Int?
            var tolerance: Int?
            var expectedBand: String?
            var expectedFlag: String?
            var insufficient: Bool?
        }
        struct File: Decodable { var cases: [Spec] }

        let url = try #require(Fixture.url("readiness_golden"))
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        for spec in file.cases {
            let history = Fixture.history(days: spec.historyDays, hrv: { _ in spec.baseline.hrv }, rhr: { _ in spec.baseline.rhr }, sleepMinutes: { _ in spec.baseline.sleepMinutes })
            let today = Fixture.todayMetrics(hrv: spec.today.hrv, rhr: spec.today.rhr, sleepMinutes: spec.today.sleepMinutes)
            let result = calculator.compute(ReadinessInputs(day: Fixture.today, history: history, today: today), now: Fixture.now, calendar: Fixture.calendar)
            if spec.insufficient == true {
                #expect(result.score == nil, "\(spec.name)")
                continue
            }
            let score = try #require(result.score, "\(spec.name)")
            if let expected = spec.expectedScore {
                #expect(abs(score.score - expected) <= (spec.tolerance ?? 0), "\(spec.name): got \(score.score), expected \(expected)")
            }
            if let band = spec.expectedBand { #expect(score.band.rawValue == band, "\(spec.name)") }
            if let flag = spec.expectedFlag { #expect(score.flags.map(\.rawValue).contains(flag), "\(spec.name)") }
        }
    }
}

@Suite("DailyMetricsAggregation")
struct DailyMetricsAggregationTests {
    private func sample(_ kind: HealthMetricKind, _ value: Double, hour: Int, minute: Int = 0, dayOffset: Int = 0, durationMinutes: Double = 0, stage: SleepStage? = nil) -> HealthSample {
        let start = Fixture.today.adding(days: dayOffset, calendar: Fixture.calendar).date(atHour: hour, minute: minute, calendar: Fixture.calendar)
        return HealthSample(kind: kind, value: value, unit: "", start: start, end: start.addingTimeInterval(durationMinutes * 60), sourceBundleID: "watch", categoryValue: stage?.rawValue)
    }

    @Test("overnight HRV uses only samples inside the sleep window; sleep minutes are summed")
    func overnightWindow() {
        let sleep = [
            sample(.sleep, 0, hour: 23, minute: 30, dayOffset: -1, durationMinutes: 150, stage: .asleepCore),   // 23:30–02:00
            sample(.sleep, 0, hour: 2, minute: 0, durationMinutes: 60, stage: .asleepDeep),                     // 02:00–03:00
            sample(.sleep, 0, hour: 3, minute: 0, durationMinutes: 250, stage: .asleepREM),                     // 03:00–07:10
        ]
        let hrv = [sample(.hrvSDNN, 45, hour: 2), sample(.hrvSDNN, 55, hour: 3, minute: 30), sample(.hrvSDNN, 30, hour: 14)]
        let input = DailyMetricsAggregation.Input(day: Fixture.today, sleepSamples: sleep, hrvSDNNSamples: hrv, now: Fixture.now)
        let metrics = DailyMetricsAggregation.aggregate(input)
        #expect(metrics.hrvSDNN == 50)
        #expect(metrics.sleep?.asleepMinutes == 460)
        #expect(metrics.sleep?.deepMinutes == 60)
    }

    @Test("a frozen resting heart rate is not overwritten by later samples")
    func rhrFreeze() {
        var existing = DailyMetrics(day: Fixture.today)
        existing.restingHR = 50
        existing.restingHRFrozenAt = Fixture.today.date(atHour: 10, calendar: Fixture.calendar)
        let later = [sample(.restingHeartRate, 60, hour: 15)]
        let metrics = DailyMetricsAggregation.aggregate(.init(day: Fixture.today, restingHeartRateSamples: later, existing: existing, now: Fixture.today.date(atHour: 16, calendar: Fixture.calendar)))
        #expect(metrics.restingHR == 50)
    }

    @Test("before the freeze hour the RHR is provisional; after it, it freezes")
    func rhrProvisionalThenFrozen() {
        let early = DailyMetricsAggregation.aggregate(.init(day: Fixture.today, restingHeartRateSamples: [sample(.restingHeartRate, 52, hour: 8)], now: Fixture.today.date(atHour: 8, minute: 30, calendar: Fixture.calendar)))
        #expect(early.restingHR == 52)
        #expect(early.restingHRFrozenAt == nil)
        let late = DailyMetricsAggregation.aggregate(.init(day: Fixture.today, restingHeartRateSamples: [sample(.restingHeartRate, 52, hour: 8)], existing: early, now: Fixture.now))
        #expect(late.restingHRFrozenAt != nil)
    }

    @Test("RMSSD is computed from beat-to-beat intervals")
    func rmssdFromSeries() {
        // Alternating 0.80 s / 0.84 s intervals → successive differences of ±40 ms → RMSSD 40.
        var times: [Double] = [0]
        for i in 1...20 { times.append(times[i - 1] + (i % 2 == 0 ? 0.80 : 0.84)) }
        let series = HeartbeatSeries(start: Date(), end: Date().addingTimeInterval(20), beatTimes: times)
        let rmssd = series.rmssd ?? 0
        #expect(abs(rmssd - 40) < 0.5, "rmssd was \(rmssd)")
    }
}
