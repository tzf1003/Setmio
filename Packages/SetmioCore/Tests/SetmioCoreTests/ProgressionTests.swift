import Foundation
import Testing
@testable import SetmioCore

@Suite("E1RMTable")
struct E1RMTableTests {
    @Test("RTS chart anchors")
    func anchors() {
        #expect(E1RMTable.percentOf1RM(reps: 1, rir: 0) == 1.0)
        #expect(abs(E1RMTable.percentOf1RM(reps: 5, rir: 2) - 0.811) < 0.001)
        #expect(abs(E1RMTable.percentOf1RM(reps: 8, rir: 2) - 0.739) < 0.001)
        #expect(abs(E1RMTable.percentOf1RM(reps: 3, rir: 1) - 0.892) < 0.001)
    }

    @Test("e1RM of 100 kg × 5 @ RIR 2 ≈ 123 kg")
    func e1rm() {
        let e = E1RMTable.e1RM(load: 100, reps: 5, rir: 2)
        #expect(abs(e - 123.3) < 1.0, "e1RM was \(e)")
    }

    @Test("beyond the chart, percentages keep falling but never below 40%")
    func extrapolation() {
        #expect(E1RMTable.percentOf1RM(reps: 20, rir: 4) >= 0.40)
        #expect(E1RMTable.percentOf1RM(reps: 15, rir: 2) < E1RMTable.percentOf1RM(reps: 12, rir: 2))
    }
}

@Suite("ProgressionEngine")
struct ProgressionEngineTests {
    let engine = ProgressionEngine()
    let meso = MesocycleState(weekIndex: 1, targetRIR: 2, isDeload: false, weeksTotal: 5)

    @Test("double progression: all sets at the top of the range at target RIR → add the plate increment")
    func increaseLoad() throws {
        let prescription = ExercisePrescription(exerciseID: Fixture.bench.id, sets: 3, repRange: 8...12)
        let history = ExerciseHistory(sets: Fixture.session(exercise: Fixture.bench, load: 60, reps: 12, rir: 2, daysAgo: 3))
        let planned = engine.plan(prescription: prescription, exercise: Fixture.bench, history: history, meso: meso)
        #expect(planned.decision == .increaseLoad(by: 2.5))
        #expect(planned.sets.first?.targetLoad == 62.5)
        #expect(planned.sets.first?.targetReps == 8...12)
        #expect(planned.sets.count == 3)
    }

    @Test("inside the range → keep load, aim for one more rep")
    func addRep() {
        let prescription = ExercisePrescription(exerciseID: Fixture.bench.id, sets: 3, repRange: 8...12)
        let history = ExerciseHistory(sets: Fixture.session(exercise: Fixture.bench, load: 60, reps: 9, rir: 2, daysAgo: 3))
        let planned = engine.plan(prescription: prescription, exercise: Fixture.bench, history: history, meso: meso)
        if case .hold = planned.decision {} else { Issue.record("expected hold, got \(planned.decision)") }
        #expect(planned.sets.first?.targetLoad == 60)
        #expect(planned.sets.first?.targetReps == 10...12)
    }

    @Test("two sessions ≥ 5% below the mesocycle best e1RM → deload")
    func e1rmDropDeload() {
        let prescription = ExercisePrescription(exerciseID: Fixture.bench.id, sets: 3, repRange: 4...6)
        let recent = Fixture.session(exercise: Fixture.bench, load: 93, reps: 5, rir: 2, daysAgo: 2)
        let previous = Fixture.session(exercise: Fixture.bench, load: 94, reps: 5, rir: 2, daysAgo: 5)
        let best = E1RMTable.e1RM(load: 100, reps: 5, rir: 2)
        let history = ExerciseHistory(sets: recent + previous, bestE1RMThisMeso: best)
        let planned = engine.plan(prescription: prescription, exercise: Fixture.bench, history: history, meso: meso)
        #expect(planned.decision == .deload(.e1rmDrop))
        #expect(planned.sets.count == 2)
        #expect(planned.sets.first?.targetLoad == 82.5)   // 93 × 0.9 = 83.7 → nearest 2.5
    }

    @Test("dumbbell jump larger than 5% → add reps instead of load")
    func dumbbellJump() {
        let prescription = ExercisePrescription(exerciseID: Fixture.curl.id, sets: 3, repRange: 10...15)
        let history = ExerciseHistory(sets: Fixture.session(exercise: Fixture.curl, load: 10, reps: 15, rir: 2, daysAgo: 3))
        let planned = engine.plan(prescription: prescription, exercise: Fixture.curl, history: history, meso: meso)
        if case .hold = planned.decision {} else { Issue.record("expected hold, got \(planned.decision)") }
        #expect(planned.sets.first?.targetLoad == 10)
        #expect(planned.sets.first?.targetReps == 11...17)
    }

    @Test("first ever session has no target load")
    func firstSession() {
        let prescription = ExercisePrescription(exerciseID: Fixture.bench.id, sets: 3, repRange: 8...12)
        let planned = engine.plan(prescription: prescription, exercise: Fixture.bench, history: .empty, meso: meso)
        #expect(planned.sets.first?.targetLoad == nil)
        #expect(planned.sets.first?.targetRIR == 2)
    }

    @Test("mesocycle deload week: −10% load, 60% sets, RIR ≥ 3")
    func mesocycleDeload() {
        let prescription = ExercisePrescription(exerciseID: Fixture.squat.id, sets: 4, repRange: 5...8)
        let history = ExerciseHistory(sets: Fixture.session(exercise: Fixture.squat, load: 100, reps: 8, rir: 1, daysAgo: 3))
        let deload = MesocycleState(weekIndex: 4, targetRIR: 3, isDeload: true, weeksTotal: 5)
        let planned = engine.plan(prescription: prescription, exercise: Fixture.squat, history: history, meso: deload)
        #expect(planned.decision == .deload(.mesocycleEnd))
        #expect(planned.sets.count == 3)
        #expect(planned.sets.first?.targetLoad == 90)
        #expect(planned.sets.first?.targetRIR == 3)
    }

    @Test("three red readiness days in the last five → readiness deload")
    func readinessStreak() {
        let prescription = ExercisePrescription(exerciseID: Fixture.squat.id, sets: 4, repRange: 5...8)
        let history = ExerciseHistory(sets: Fixture.session(exercise: Fixture.squat, load: 100, reps: 8, rir: 1, daysAgo: 3), recentReadinessScores: [40, 55, 42, 70, 38])
        let planned = engine.plan(prescription: prescription, exercise: Fixture.squat, history: history, meso: meso)
        #expect(planned.decision == .deload(.readinessStreak))
    }

    @Test("RTS percent prescription uses the recent e1RM")
    func rtsPercent() {
        let prescription = ExercisePrescription(exerciseID: Fixture.squat.id, sets: 3, repRange: 3...5, progression: .rtsPercent(targetPercentOfE1RM: 0.8))
        let history = ExerciseHistory(sets: Fixture.session(exercise: Fixture.squat, load: 100, reps: 5, rir: 2, daysAgo: 3))
        let planned = engine.plan(prescription: prescription, exercise: Fixture.squat, history: history, meso: meso)
        // e1RM ≈ 123.3 → 80% ≈ 98.6 → nearest 5 kg = 100
        #expect(planned.sets.first?.targetLoad == 100)
    }
}

@Suite("ReadinessModulator")
struct ReadinessModulatorTests {
    private func session(sets: Int, load: Double) -> PlannedSession {
        let planned = (0..<sets).map { PlannedSet(index: $0, targetLoad: load, targetReps: 5...8, targetRIR: 2) }
        return PlannedSession(mesocycleID: nil, day: Fixture.today, dayNameZH: "腿", exercises: [PlannedExercise(exerciseID: Fixture.squat.id, sets: planned, decision: .hold(reason: ""))])
    }

    private func readiness(_ score: Int, flags: [ReadinessFlag] = []) -> ReadinessScore {
        ReadinessScore(day: Fixture.today, score: score, band: score >= 60 ? .green : (score >= 45 ? .yellow : .red), confidence: 1, components: [], flags: flags, baselineDays: 60, computedAt: Fixture.now)
    }

    @Test("red readiness: 4 × 100 kg becomes 3 × 90 kg with +1 RIR, and the input is untouched")
    func redDay() {
        let original = session(sets: 4, load: 100)
        let modulated = ReadinessModulator().modulate(original, readiness: readiness(30), increments: [Fixture.squat.id: 5])
        #expect(modulated.exercises[0].sets.count == 3)
        #expect(modulated.exercises[0].sets.allSatisfy { $0.targetLoad == 90 && $0.targetRIR == 3 })
        #expect(modulated.readinessAdjustment?.setsDelta == -1)
        #expect(original.exercises[0].sets.count == 4)
        #expect(original.readinessAdjustment == nil)
    }

    @Test("yellow readiness drops one set from the last compound exercise only")
    func yellowDay() {
        let original = session(sets: 4, load: 100)
        let modulated = ReadinessModulator().modulate(original, readiness: readiness(52), categories: [Fixture.squat.id: .compound])
        #expect(modulated.exercises[0].sets.count == 3)
        #expect(modulated.exercises[0].sets.first?.targetLoad == 100)
    }

    @Test("green readiness leaves the plan alone; very high adds only a note")
    func greenDay() {
        let original = session(sets: 4, load: 100)
        #expect(ReadinessModulator().modulate(original, readiness: readiness(70)) == original)
        let high = ReadinessModulator().modulate(original, readiness: readiness(90))
        #expect(high.exercises == original.exercises)
        #expect(high.readinessAdjustment?.setsDelta == 0)
    }
}

@Suite("RestTimerPolicy")
struct RestTimerPolicyTests {
    let policy = RestTimerPolicy()
    let sessionID = ID<LoggedSession>()

    @Test("heavy squat set → 210 s") func heavySquat() {
        let set = LoggedSet(sessionID: sessionID, exerciseID: Fixture.squat.id, index: 0, load: 140, reps: 5, rir: 1, completedAt: Fixture.now)
        #expect(policy.duration(after: set, exercise: Fixture.squat, next: nil, readiness: nil) == 210)
    }

    @Test("dumbbell curl → 90 s") func curl() {
        let set = LoggedSet(sessionID: sessionID, exerciseID: Fixture.curl.id, index: 0, load: 12, reps: 12, rir: 2, completedAt: Fixture.now)
        #expect(policy.duration(after: set, exercise: Fixture.curl, next: nil, readiness: nil) == 90)
    }

    @Test("warm-up set → 60 s; override wins") func warmupAndOverride() {
        let set = LoggedSet(sessionID: sessionID, exerciseID: Fixture.squat.id, index: 0, load: 60, reps: 5, rir: 5, completedAt: Fixture.now, isWarmup: true)
        #expect(policy.duration(after: set, exercise: Fixture.squat, next: nil, readiness: nil) == 60)
        #expect(policy.duration(after: set, exercise: Fixture.squat, next: nil, readiness: nil, overrideSeconds: 45) == 45)
    }
}
