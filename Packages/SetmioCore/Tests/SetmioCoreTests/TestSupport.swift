import Foundation
@testable import SetmioCore

enum Fixture {
    static let calendar = Calendar.setmioDefault
    /// A fixed "today" so every test is deterministic.
    static let today = DayKey(year: 2026, month: 10, day: 9)
    static let now = today.date(atHour: 11, calendar: calendar)

    static func url(_ name: String, ext: String = "json") -> URL? {
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: ext)
    }

    /// Builds `days` days of history ending the day before `today`.
    static func history(
        days: Int,
        hrv: (Int) -> Double = { _ in 50 },
        rhr: (Int) -> Double = { _ in 55 },
        sleepMinutes: (Int) -> Double = { _ in 450 },
        load: (Int) -> Double? = { $0 % 2 == 0 ? 300 : 0 },
        respiratoryRate: (Int) -> Double = { _ in 15 }
    ) -> [DailyMetrics] {
        (1...days).reversed().map { offset in
            let day = today.adding(days: -offset, calendar: calendar)
            let start = day.adding(days: -1, calendar: calendar).date(atHour: 23, minute: 30, calendar: calendar)
            let end = day.date(atHour: 7, calendar: calendar)
            return DailyMetrics(
                day: day,
                hrvSDNN: hrv(offset),
                restingHR: rhr(offset),
                overnightRespiratoryRate: respiratoryRate(offset),
                sleep: SleepWindow(start: start, end: end, asleepMinutes: sleepMinutes(offset)),
                trainingLoad: load(offset)
            )
        }
    }

    static func todayMetrics(hrv: Double? = 50, rhr: Double? = 55, sleepMinutes: Double? = 450, load: Double? = 300, subjective: SubjectiveCheckIn? = SubjectiveCheckIn(energy: 3, soreness: 3, mood: 3, stress: 3), respiratoryRate: Double? = 15, tempDeviation: Double? = nil) -> DailyMetrics {
        let start = today.adding(days: -1, calendar: calendar).date(atHour: 23, minute: 30, calendar: calendar)
        let end = today.date(atHour: 7, calendar: calendar)
        return DailyMetrics(
            day: today,
            hrvSDNN: hrv,
            restingHR: rhr,
            overnightRespiratoryRate: respiratoryRate,
            wristTemperatureDeviation: tempDeviation,
            sleep: sleepMinutes.map { SleepWindow(start: start, end: end, asleepMinutes: $0) },
            trainingLoad: load,
            subjective: subjective
        )
    }

    static let bench = Exercise(id: ID(uuidString: "00000000-0000-4000-8000-000000000003")!, nameZH: "杠铃卧推", primary: [.chest], category: .compound, equipment: .barbell, loadIncrement: 2.5)
    static let squat = Exercise(id: ID(uuidString: "00000000-0000-4000-8000-000000000001")!, nameZH: "杠铃深蹲", primary: [.quads], category: .compound, equipment: .barbell, loadIncrement: 5)
    static let curl = Exercise(id: ID(uuidString: "00000000-0000-4000-8000-000000000015")!, nameZH: "哑铃弯举", primary: [.biceps], category: .isolation, equipment: .dumbbell, loadIncrement: 1)

    /// One logged session with `sets` identical working sets, `daysAgo` days before today.
    static func session(exercise: Exercise, load: Double, reps: Int, rir: Int, sets: Int = 3, daysAgo: Int) -> [LoggedSet] {
        let sessionID = ID<LoggedSession>()
        let base = today.adding(days: -daysAgo, calendar: calendar).date(atHour: 18, calendar: calendar)
        return (0..<sets).map { index in
            LoggedSet(sessionID: sessionID, exerciseID: exercise.id, index: index, load: load, reps: reps, rir: rir,
                      completedAt: base.addingTimeInterval(Double(index) * 240))
        }
    }
}
