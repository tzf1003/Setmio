import Foundation
import Testing
@testable import SetmioCore

@Suite("GLP1")
struct GLP1Tests {
    let table: GLP1LabelTable
    let validator: GLP1PlanValidator
    let medication = Medication(drug: .tirzepatide, form: .penFixedDose, startedOn: DayKey(year: 2026, month: 6, day: 1))

    init() throws {
        table = try GLP1LabelTable.loadBundled()
        validator = GLP1PlanValidator(table: table)
    }

    private var tirzepatide: Drug { table.drug(.tirzepatide)! }

    private func block(_ result: Result<Void, HardBlock>) -> HardBlock? {
        if case .failure(let b) = result { return b }
        return nil
    }

    private func weeklyDoses(mg: Double, count: Int, lastDaysAgo: Int = 1) -> [DoseLog] {
        (0..<count).map { i in
            DoseLog(medicationID: medication.id, takenAt: Fixture.now.addingTimeInterval(-Double(lastDaysAgo + 7 * i) * 86_400), doseMg: mg, site: .abdomenLeft)
        }
    }

    private func plan(currentMg: Double, daysOnStep: Int) -> GLP1Plan {
        var p = validator.buildPlan(for: tirzepatide, medicationID: medication.id, startingStepIndex: 0, startDay: Fixture.today.adding(days: -120, calendar: Fixture.calendar))
        p.currentStepIndex = tirzepatide.stepIndex(of: currentMg)!
        p.steps[p.currentStepIndex].startedOn = Fixture.today.adding(days: -daysOnStep, calendar: Fixture.calendar)
        return p
    }

    @Test("bundled CN label table has the expected ladders")
    func labelTable() {
        #expect(table.market == "CN")
        #expect(table.drug(.semaglutide)?.steps == [0.25, 0.5, 1.0, 1.7, 2.4])
        #expect(table.drug(.tirzepatide)?.steps == [2.5, 5, 7.5, 10, 12.5, 15])
        #expect(table.drug(.mazdutide)?.steps == [2, 4, 6])
        #expect(table.drug(.mazdutide)?.minHoursBetweenDoses == 120)
        #expect(table.drug(.tirzepatide)?.forms.contains(.penMultiDose(inUseDays: 30)) == true)
    }

    @Test("tolerated step for 35 days with slow loss → discuss escalating to 7.5 mg")
    func escalate() throws {
        let inputs = GLP1DecisionInputs(plan: plan(currentMg: 5, daysOnStep: 35), medication: medication, drug: tirzepatide,
                                        doses: weeklyDoses(mg: 5, count: 5), sideEffects: [SideEffectLog(medicationID: medication.id, day: Fixture.today.adding(days: -3, calendar: Fixture.calendar), kind: .nausea, severity: 1)],
                                        weightTrendPercentPerWeek: -0.2, goalReached: false, now: Fixture.now)
        let advice = try GLP1DecisionSupport(validator: validator).advise(inputs, calendar: Fixture.calendar).get()
        #expect(advice.kind == .escalate(toMg: 7.5))
        #expect(advice.framing == .discussWithDoctor)
        #expect(!advice.rationaleZH.isEmpty)
    }

    @Test("only 20 days on the step → escalation blocked as too soon")
    func tooSoon() {
        let inputs = GLP1DecisionInputs(plan: plan(currentMg: 5, daysOnStep: 20), medication: medication, drug: tirzepatide,
                                        doses: weeklyDoses(mg: 5, count: 3), sideEffects: [], weightTrendPercentPerWeek: -0.2, goalReached: false, now: Fixture.now)
        let result = GLP1DecisionSupport(validator: validator).advise(inputs, calendar: Fixture.calendar)
        #expect(result == .failure(.escalationTooSoon(daysOnStep: 20, requiredDays: 28)))
    }

    @Test("fast loss → hold; moderate side effects → hold; severe → seek care")
    func holdsAndSafety() throws {
        let base = plan(currentMg: 5, daysOnStep: 35)
        let fast = GLP1DecisionInputs(plan: base, medication: medication, drug: tirzepatide, doses: weeklyDoses(mg: 5, count: 5), sideEffects: [], weightTrendPercentPerWeek: -1.4, goalReached: false, now: Fixture.now)
        if case .hold = try GLP1DecisionSupport(validator: validator).advise(fast, calendar: Fixture.calendar).get().kind {} else { Issue.record("expected hold for fast loss") }

        let moderate = GLP1DecisionInputs(plan: base, medication: medication, drug: tirzepatide, doses: weeklyDoses(mg: 5, count: 5),
                                          sideEffects: [SideEffectLog(medicationID: medication.id, day: Fixture.today.adding(days: -5, calendar: Fixture.calendar), kind: .vomiting, severity: 2)],
                                          weightTrendPercentPerWeek: -0.2, goalReached: false, now: Fixture.now)
        if case .hold = try GLP1DecisionSupport(validator: validator).advise(moderate, calendar: Fixture.calendar).get().kind {} else { Issue.record("expected hold for moderate side effects") }

        let severe = GLP1DecisionInputs(plan: base, medication: medication, drug: tirzepatide, doses: weeklyDoses(mg: 5, count: 5),
                                        sideEffects: [SideEffectLog(medicationID: medication.id, day: Fixture.today.adding(days: -1, calendar: Fixture.calendar), kind: .abdominalPain, severity: 3)],
                                        weightTrendPercentPerWeek: -0.2, goalReached: false, now: Fixture.now)
        if case .seekCareNow = try GLP1DecisionSupport(validator: validator).advise(severe, calendar: Fixture.calendar).get().kind {} else { Issue.record("expected seekCareNow") }

        let goal = GLP1DecisionInputs(plan: base, medication: medication, drug: tirzepatide, doses: weeklyDoses(mg: 5, count: 5), sideEffects: [], weightTrendPercentPerWeek: -0.2, goalReached: true, now: Fixture.now)
        #expect(try GLP1DecisionSupport(validator: validator).advise(goal, calendar: Fixture.calendar).get().kind == .maintenance)
    }

    @Test("skipping a step and exceeding the label max are hard blocks")
    func ladderBlocks() {
        let p = plan(currentMg: 10, daysOnStep: 40)
        let history = weeklyDoses(mg: 10, count: 5, lastDaysAgo: 7)
        let skip = DoseLog(medicationID: medication.id, takenAt: Fixture.now, doseMg: 15)
        #expect(block(validator.validate(dose: skip, medication: medication, plan: p, history: history, pen: nil, now: Fixture.now, calendar: Fixture.calendar)) == .skippedStep(expectedNextMg: 12.5))
        let over = DoseLog(medicationID: medication.id, takenAt: Fixture.now, doseMg: 20)
        #expect(block(validator.validate(dose: over, medication: medication, plan: p, history: history, pen: nil, now: Fixture.now, calendar: Fixture.calendar)) == .doseExceedsLabelMax(maxMg: 15))
        let next = DoseLog(medicationID: medication.id, takenAt: Fixture.now, doseMg: 12.5)
        #expect(block(validator.validate(dose: next, medication: medication, plan: p, history: history, pen: nil, now: Fixture.now, calendar: Fixture.calendar)) == nil)
        let stepDown = DoseLog(medicationID: medication.id, takenAt: Fixture.now, doseMg: 7.5)
        #expect(block(validator.validate(dose: stepDown, medication: medication, plan: p, history: history, pen: nil, now: Fixture.now, calendar: Fixture.calendar)) == nil)
    }

    @Test("two doses 24 h apart violate the 72 h minimum interval")
    func minInterval() {
        let history = [DoseLog(medicationID: medication.id, takenAt: Fixture.now.addingTimeInterval(-24 * 3600), doseMg: 5)]
        let dose = DoseLog(medicationID: medication.id, takenAt: Fixture.now, doseMg: 5)
        #expect(block(validator.validate(dose: dose, medication: medication, plan: nil, history: history, pen: nil, now: Fixture.now, calendar: Fixture.calendar)) == .minIntervalViolation(hoursSinceLast: 24, requiredHours: 72))
    }

    @Test("vials and unverified products get no plan math")
    func vial() {
        let vial = Medication(drug: .tirzepatide, form: .vial, startedOn: Fixture.today)
        let dose = DoseLog(medicationID: vial.id, takenAt: Fixture.now, doseMg: 5)
        #expect(block(validator.validate(dose: dose, medication: vial, plan: nil, history: [], pen: nil, now: Fixture.now, calendar: Fixture.calendar)) == .vialVolumeMathUnsupported)
        let unverified = Medication(drug: .tirzepatide, form: .penFixedDose, startedOn: Fixture.today, isUnverifiedSource: true)
        #expect(block(validator.validate(dose: dose, medication: unverified, plan: nil, history: [], pen: nil, now: Fixture.now, calendar: Fixture.calendar)) == .vialVolumeMathUnsupported)
    }

    @Test("expired pen is blocked; next due date is last dose + 7 days")
    func penAndNextDue() {
        let pen = PenInventory(medicationID: medication.id, strengthMg: 5, firstUsedAt: Fixture.now.addingTimeInterval(-40 * 86_400), inUseExpiry: Fixture.now.addingTimeInterval(-10 * 86_400))
        let dose = DoseLog(medicationID: medication.id, takenAt: Fixture.now, doseMg: 5, penID: pen.id)
        if case .failure(.penInUseExpired) = validator.validate(dose: dose, medication: medication, plan: nil, history: [], pen: pen, now: Fixture.now, calendar: Fixture.calendar) {} else { Issue.record("expected penInUseExpired") }

        let p = plan(currentMg: 5, daysOnStep: 10)
        let last = DoseLog(medicationID: medication.id, takenAt: Fixture.now.addingTimeInterval(-3 * 86_400), doseMg: 5)
        let due = validator.nextDue(plan: p, history: [last], now: Fixture.now, calendar: Fixture.calendar)
        #expect(due == Fixture.calendar.date(byAdding: .day, value: 7, to: last.takenAt))
    }

    @Test("missed-dose guidance is fixed label text")
    func missedDose() {
        let drug = tirzepatide
        let last = Fixture.now.addingTimeInterval(-(7 * 24 + 48) * 3600)   // 2 days late
        if case .takeNow = validator.missedDoseGuidance(drug: drug, lastDose: last, now: Fixture.now) {} else { Issue.record("expected takeNow within 96 h") }
        let veryLate = Fixture.now.addingTimeInterval(-(7 * 24 + 120) * 3600)
        if case .skipAndResume = validator.missedDoseGuidance(drug: drug, lastDose: veryLate, now: Fixture.now) {} else { Issue.record("expected skipAndResume after 96 h") }
        #expect(validator.missedDoseGuidance(drug: drug, lastDose: Fixture.now.addingTimeInterval(-3 * 86_400), now: Fixture.now) == .notMissed)
    }
}

@Suite("Seed data")
struct SeedDataTests {
    @Test("exercise and program seeds decode and reference each other")
    func seeds() throws {
        let exercises = try SeedData.exercises()
        let programs = try SeedData.programs()
        #expect(exercises.count >= 20)
        #expect(programs.count == 2)
        let ids = Set(exercises.map(\.id))
        for program in programs {
            for day in program.days {
                for prescription in day.prescriptions {
                    #expect(ids.contains(prescription.exerciseID), "\(program.nameZH)/\(day.nameZH) references an unknown exercise")
                }
            }
        }
    }

    @Test("profile protein targets")
    func protein() {
        let profile = UserProfile(sex: .female, heightCm: 165, birthDate: DayKey(year: 1995, month: 5, day: 5), proteinStandard: .chinaDraft)
        #expect(profile.proteinTargetGrams(weight: 70, leanMass: nil) == 72)   // (165−105) × 1.2
        #expect(profile.kcalFloor == 1200)
        let us = UserProfile(sex: .male, heightCm: 180, birthDate: DayKey(year: 1990, month: 1, day: 1), proteinStandard: .perKgBodyweight(gPerKg: 1.6))
        #expect(us.proteinTargetGrams(weight: 80, leanMass: nil) == 128)
    }
}
