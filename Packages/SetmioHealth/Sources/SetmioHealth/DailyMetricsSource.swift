import Foundation
import SetmioCore

/// Fetches the overnight window around one day from a `HealthSampleSource` and hands it to Core's pure
/// `DailyMetricsAggregation.aggregate`. No numbers are computed here.
public struct DailyMetricsSource: Sendable {
    public let source: any HealthSampleSource

    public init(source: any HealthSampleSource) {
        self.source = source
    }

    /// The fetch window: 18:00 the evening before to 12:00 on `day`, wide enough for late bedtimes and
    /// late risers. The precise sleep window is detected inside Core from the sleep samples.
    public static func fetchWindow(for day: DayKey, calendar: Calendar) -> ClosedRange<Date> {
        let start = day.adding(days: -1, calendar: calendar).date(atHour: 18, calendar: calendar)
        let end = day.date(atHour: 12, calendar: calendar)
        return start...end
    }

    /// Full-day range `[00:00, 23:59:59]` of `day`.
    public static func dayRange(for day: DayKey, calendar: Calendar) -> ClosedRange<Date> {
        let start = day.startOfDay(calendar: calendar)
        let end = day.adding(days: 1, calendar: calendar).startOfDay(calendar: calendar).addingTimeInterval(-1)
        return start...max(start, end)
    }

    public func metrics(
        for day: DayKey,
        settings: Settings,
        existing: DailyMetrics? = nil,
        trainingLoad: Double? = nil,
        subjective: SubjectiveCheckIn? = nil,
        baselineWristTemperature: Double? = nil,
        now: Date
    ) async throws -> DailyMetrics {
        let calendar = settings.calendar
        let window = Self.fetchWindow(for: day, calendar: calendar)
        let dayStart = day.startOfDay(calendar: calendar)

        async let sleep = source.samples(of: .sleep, in: window)
        async let sdnn = source.samples(of: .hrvSDNN, in: window)
        async let rmssd = optionalSamples(of: .hrvRMSSD, in: window)
        async let heartRate = source.samples(of: .heartRate, in: window)
        async let restingHR = source.samples(of: .restingHeartRate, in: window)
        async let respiratory = source.samples(of: .respiratoryRate, in: window)
        async let temperature = source.samples(of: .wristTemperature, in: window)
        async let series = source.heartbeatSeries(in: window)
        async let steps = source.dailyTotal(of: .steps, on: day, calendar: calendar)
        async let active = source.dailyTotal(of: .activeEnergy, on: day, calendar: calendar)
        async let basal = source.dailyTotal(of: .basalEnergy, on: day, calendar: calendar)

        // Apple's resting-heart-rate samples span a whole day; yesterday's final sample overlaps the window
        // start, so keep only samples that belong to `day`.
        let todaysRestingHR = try await restingHR.filter { $0.start >= dayStart }

        let input = try await DailyMetricsAggregation.Input(
            day: day,
            sleepSamples: sleep,
            hrvSDNNSamples: sdnn,
            hrvRMSSDSamples: rmssd,
            heartbeatSeries: series,
            heartRateSamples: heartRate,
            restingHeartRateSamples: todaysRestingHR,
            respiratoryRateSamples: respiratory,
            wristTemperatureSamples: temperature,
            steps: steps.map { Int($0.rounded()) },
            activeEnergy: active,
            basalEnergy: basal,
            workoutEffort: nil,
            trainingLoad: trainingLoad,
            subjective: subjective,
            baselineWristTemperature: baselineWristTemperature,
            existing: existing,
            settings: settings,
            now: now
        )
        return DailyMetricsAggregation.aggregate(input)
    }

    /// Apple-Training-Load-style daily load: Σ (effort score, default 5 when unrated) × workout minutes.
    public func trainingLoad(for day: DayKey, calendar: Calendar) async throws -> Double {
        let workouts = try await source.workouts(in: Self.dayRange(for: day, calendar: calendar))
        return workouts.reduce(0) { total, workout in
            total + Double(workout.effortScore ?? 5) * workout.durationMinutes
        }
    }

    /// Kinds without a system type on the current OS (RMSSD before iOS 27) simply contribute nothing.
    private func optionalSamples(of kind: HealthMetricKind, in range: ClosedRange<Date>) async -> [HealthSample] {
        (try? await source.samples(of: kind, in: range)) ?? []
    }
}
