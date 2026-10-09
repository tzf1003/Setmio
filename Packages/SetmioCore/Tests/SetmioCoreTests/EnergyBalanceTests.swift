import Foundation
import Testing
@testable import SetmioCore

@Suite("EnergyBalanceEstimator")
struct EnergyBalanceTests {
    let estimator = EnergyBalanceEstimator()
    let profile = UserProfile(sex: .male, heightCm: 175, birthDate: DayKey(year: 1990, month: 1, day: 1), activityFactor: 1.375)

    private func window(days: Int, startDaysAgo: Int, weight: (Int) -> Double, intake: Double?, completeness: Double = 1) -> [EnergyObservation] {
        (0..<days).map { i in
            let day = Fixture.today.adding(days: -startDaysAgo + i, calendar: Fixture.calendar)
            return EnergyObservation(day: day, weight: weight(i), intakeKcal: intake, loggedMealsRatio: completeness)
        }
    }

    @Test("Mifflin-St Jeor prior")
    func prior() {
        let bmr = EnergyBalanceEstimator.mifflinStJeorBMR(sex: .male, weight: 80, heightCm: 175, age: 36)
        let expectedBMR: Double = 800 + 1093.75 - 180 + 5
        #expect(bmr == expectedBMR)
        let initial = EnergyBalanceEstimator.initialEstimate(profile: profile, weight: 80, age: 36, day: Fixture.today)
        #expect(abs(initial.tdee - bmr * 1.375) < 1)
        #expect(initial.variance == 400 * 400)
    }

    @Test("flat weight on 2200 kcal pulls a 2500 kcal prior into 2200…2300 within three updates")
    func convergesDown() {
        var state = EnergyEstimate(day: Fixture.today.adding(days: -42, calendar: Fixture.calendar), tdee: 2500, variance: 400 * 400, trendWeight: 80)
        for round in (0..<3).reversed() {
            let obs = window(days: 14, startDaysAgo: 14 * (round + 1), weight: { _ in 80 }, intake: 2200)
            state = estimator.update(state, with: obs)
        }
        #expect((2200...2300).contains(state.tdee), "tdee was \(state.tdee)")
        #expect(state.variance < 400 * 400)
        #expect(abs(state.trendSlopePerWeek) < 0.05)
    }

    @Test("losing 0.5 kg/week on 1800 kcal converges toward ≈ 2340 kcal")
    func convergesUp() {
        var state = EnergyEstimate(day: Fixture.today.adding(days: -200, calendar: Fixture.calendar), tdee: 2500, variance: 400 * 400, trendWeight: 90)
        let perDay = 0.5 / 7
        for round in (0..<12).reversed() {
            let startDaysAgo = 28 * (round + 1)
            let obs = window(days: 28, startDaysAgo: startDaysAgo, weight: { i in 90 - Double(336 - startDaysAgo + i) * perDay }, intake: 1800)
            state = estimator.update(state, with: obs)
        }
        let expected = 1800 + perDay * EnergyConfig().energyDensityPerKg
        #expect(abs(state.tdee - expected) < 80, "tdee was \(state.tdee), expected ≈ \(expected)")
        #expect(abs(state.trendSlopePerWeek + 0.5) < 0.1)
    }

    @Test("lower logging completeness moves the estimate less; below 4/7 it pauses")
    func completenessGates() {
        let state = EnergyEstimate(day: Fixture.today.adding(days: -14, calendar: Fixture.calendar), tdee: 2500, variance: 400 * 400, trendWeight: 80)
        let full = estimator.update(state, with: window(days: 14, startDaysAgo: 14, weight: { _ in 80 }, intake: 2200, completeness: 1.0))
        let partial = estimator.update(state, with: window(days: 14, startDaysAgo: 14, weight: { _ in 80 }, intake: 2200, completeness: 0.6))
        let paused = estimator.update(state, with: window(days: 14, startDaysAgo: 14, weight: { _ in 80 }, intake: 2200, completeness: 0.3))
        #expect(abs(partial.tdee - 2500) < abs(full.tdee - 2500))
        #expect(paused.tdee == 2500)
        #expect(paused.loggingCompleteness == 0.3)
    }

    @Test("deficit and floor")
    func deficit() {
        let d = estimator.dailyDeficit(weight: 80, ratePercentPerWeek: 0.7)
        let expectedDeficit: Double = 80 * 0.007 * EnergyConfig().energyDensityPerKg / 7
        #expect(abs(d - expectedDeficit) < 1)
        let (target, floorHit) = estimator.intakeTarget(tdee: 2000, deficit: 900, profile: profile)
        #expect(floorHit)
        #expect(target == 1800)
    }
}
