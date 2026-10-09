import Foundation

// MARK: - Estimated 1RM (RTS chart)

/// Reactive Training Systems chart: percent of 1RM by reps and RPE. Each step of −1 RPE (= +1 RIR) or +1 rep moves
/// one entry down the same diagonal, so the whole chart collapses to one sequence indexed by `reps + RIR`
/// (RPE 10 × 1 = 100%, RPE 9 × 1 = RPE 10 × 2 = 95.5%, RPE 8 × 5 = 81.1%, RPE 8 × 8 = 73.9%).
public enum E1RMTable {
    private static let sequence: [Double] = [
        100.0, 95.5, 92.2, 89.2, 86.3, 83.7, 81.1, 78.6, 76.2, 73.9, 70.7, 68.0, 65.3, 62.6, 59.9, 57.2,
    ]

    /// Fraction of 1RM (0…1) for `reps` performed with `rir` reps in reserve.
    public static func percentOf1RM(reps: Int, rir: Int) -> Double {
        let r = max(1, reps)
        let index = r + max(0, min(rir, 4))
        if index <= sequence.count {
            return sequence[index - 1] / 100
        }
        let extrapolated = sequence[sequence.count - 1] - 2.7 * Double(index - sequence.count)
        return max(extrapolated, 40) / 100
    }

    public static func e1RM(load: Kilograms, reps: Int, rir: Int) -> Kilograms {
        guard load > 0 else { return 0 }
        return load / percentOf1RM(reps: reps, rir: rir)
    }

    public static func load(forE1RM e1rm: Kilograms, reps: Int, rir: Int) -> Kilograms {
        e1rm * percentOf1RM(reps: reps, rir: rir)
    }
}

// MARK: - Inputs

public struct ProgressionConfig: Sendable, Equatable {
    public var e1rmDropThreshold = 0.05
    public var e1rmDropSessions = 2
    public var consecutiveFailuresForDeload = 3
    /// Joint pain or soreness at or above this (1–4) in the last two sessions triggers a deload.
    public var feedbackDeloadThreshold = 3
    public var readinessRedThreshold = 45
    public var readinessRedStreak = 3
    public var readinessStreakWindow = 5
    public var deloadLoadMultiplier = 0.90
    public var triggeredDeloadSetMultiplier = 0.5
    public var mesocycleDeloadSetMultiplier = 0.6
    /// Above this fraction of the current load, a load step is too big (dumbbell racks) → add reps instead.
    public var maxIncrementFraction = 0.05

    public init() {}
}

public struct MesocycleState: Sendable, Equatable {
    public var weekIndex: Int
    public var targetRIR: Int
    public var isDeload: Bool
    public var weeksTotal: Int

    public init(weekIndex: Int, targetRIR: Int, isDeload: Bool, weeksTotal: Int) {
        self.weekIndex = weekIndex
        self.targetRIR = targetRIR
        self.isDeload = isDeload
        self.weeksTotal = weeksTotal
    }

    public init(mesocycle: Mesocycle) {
        let week = mesocycle.currentWeek
        self.init(weekIndex: mesocycle.currentWeekIndex, targetRIR: week?.targetRIR ?? 2, isDeload: week?.isDeload ?? false, weeksTotal: mesocycle.weeks.count)
    }
}

public struct ExerciseHistory: Sendable, Equatable {
    /// Working and warm-up sets for this exercise, most recent first.
    public var sets: [LoggedSet]
    /// Session feedback, most recent first.
    public var feedback: [SessionFeedback]
    public var bestE1RMThisMeso: Kilograms?
    /// Readiness scores for recent days, most recent first.
    public var recentReadinessScores: [Int]

    public init(sets: [LoggedSet], feedback: [SessionFeedback] = [], bestE1RMThisMeso: Kilograms? = nil, recentReadinessScores: [Int] = []) {
        self.sets = sets
        self.feedback = feedback
        self.bestE1RMThisMeso = bestE1RMThisMeso
        self.recentReadinessScores = recentReadinessScores
    }

    public static let empty = ExerciseHistory(sets: [])
}

// MARK: - Engine

/// Rule-based, explainable progression. Decides the next session's load/reps/RIR for one exercise from its history
/// and the mesocycle state. Today-only readiness modulation is applied separately by `ReadinessModulator`.
public struct ProgressionEngine: Sendable {
    public let config: ProgressionConfig

    public init(config: ProgressionConfig = ProgressionConfig()) {
        self.config = config
    }

    public func plan(prescription: ExercisePrescription, exercise: Exercise, history: ExerciseHistory, meso: MesocycleState) -> PlannedExercise {
        let working = history.sets.filter { !$0.isWarmup && $0.exerciseID == prescription.exerciseID }
        let sessions = groupBySession(working)   // most recent first
        let targetRIR = meso.targetRIR
        let range = prescription.repRange
        let increment = max(exercise.loadIncrement, 0.5)

        guard let last = sessions.first, !last.isEmpty else {
            return build(prescription: prescription, load: nil, reps: range, rir: targetRIR, sets: prescription.sets,
                         decision: .hold(reason: "首次训练：请按感觉选择一个能在目标次数内留 \(targetRIR) 次余力的重量"))
        }

        let lastLoad = dominantLoad(last)
        let e1RMs = sessions.map { session in session.map { E1RMTable.e1RM(load: $0.load, reps: $0.reps, rir: $0.rir) }.max() ?? 0 }
        let bestE1RM = history.bestE1RMThisMeso ?? (e1RMs.max() ?? 0)

        // Deloads come first; they override progression.
        if meso.isDeload {
            let sets = max(1, Int((Double(prescription.sets) * config.mesocycleDeloadSetMultiplier).rounded(.up)))
            return build(prescription: prescription, load: Stats.round(lastLoad * config.deloadLoadMultiplier, toNearest: increment),
                         reps: range, rir: max(targetRIR, 3), sets: sets, decision: .deload(.mesocycleEnd))
        }
        if let reason = triggeredDeloadReason(sessions: sessions, e1RMs: e1RMs, bestE1RM: bestE1RM, history: history, range: range) {
            let sets = max(1, Int((Double(prescription.sets) * config.triggeredDeloadSetMultiplier).rounded(.up)))
            return build(prescription: prescription, load: Stats.round(lastLoad * config.deloadLoadMultiplier, toNearest: increment),
                         reps: range, rir: max(targetRIR, 2), sets: sets, decision: .deload(reason))
        }

        switch prescription.progression {
        case .rtsPercent(let percent):
            let recentE1RM = e1RMs.first ?? bestE1RM
            let load = Stats.round(recentE1RM * percent, toNearest: increment)
            let delta = load - lastLoad
            let decision: ProgressionDecision = delta > 0.01 ? .increaseLoad(by: delta) : .hold(reason: "按近期 e1RM × \(Int(percent * 100))% 处方重量")
            return build(prescription: prescription, load: load, reps: range, rir: targetRIR, sets: prescription.sets, decision: decision)

        case .doubleProgression:
            let allAtTop = last.allSatisfy { $0.reps >= range.upperBound }
            let allAboveBottom = last.allSatisfy { $0.reps >= range.lowerBound }
            let avgRIR = Stats.mean(last.map { Double($0.rir) }) ?? 0
            let minReps = last.map(\.reps).min() ?? range.lowerBound
            let easySession = (history.feedback.first.map { $0.soreness <= 1 && $0.pump <= 2 && $0.joint <= 1 } ?? false) && avgRIR >= Double(targetRIR + 1)

            if allAtTop && avgRIR >= Double(targetRIR) {
                if increment / max(lastLoad, 0.1) > config.maxIncrementFraction {
                    return build(prescription: prescription, load: lastLoad, reps: (range.lowerBound + 1)...(range.upperBound + 2), rir: targetRIR, sets: prescription.sets,
                                 decision: .hold(reason: "下一档重量跳幅超过 5%，本次改为增加次数"))
                }
                return build(prescription: prescription, load: lastLoad + increment, reps: range, rir: targetRIR, sets: prescription.sets,
                             decision: .increaseLoad(by: increment))
            }
            if allAboveBottom {
                if easySession {
                    return build(prescription: prescription, load: lastLoad, reps: min(minReps + 1, range.upperBound)...range.upperBound, rir: targetRIR, sets: prescription.sets + 1,
                                 decision: .addSet)
                }
                return build(prescription: prescription, load: lastLoad, reps: min(minReps + 1, range.upperBound)...range.upperBound, rir: targetRIR, sets: prescription.sets,
                             decision: .hold(reason: "重量不变，目标比上次多 1 次"))
            }
            return build(prescription: prescription, load: lastLoad, reps: range, rir: targetRIR, sets: prescription.sets,
                         decision: .hold(reason: "上次未达最低次数，重量不变再做一次"))
        }
    }

    // MARK: Helpers

    private func triggeredDeloadReason(sessions: [[LoggedSet]], e1RMs: [Kilograms], bestE1RM: Kilograms, history: ExerciseHistory, range: ClosedRange<Int>) -> DeloadReason? {
        let recent = history.recentReadinessScores.prefix(config.readinessStreakWindow)
        if recent.filter({ $0 < config.readinessRedThreshold }).count >= config.readinessRedStreak {
            return .readinessStreak
        }
        if bestE1RM > 0, e1RMs.count >= config.e1rmDropSessions {
            let dropped = e1RMs.prefix(config.e1rmDropSessions).allSatisfy { $0 < bestE1RM * (1 - config.e1rmDropThreshold) }
            if dropped { return .e1rmDrop }
        }
        let feedback = history.feedback.prefix(2)
        if feedback.count == 2, feedback.allSatisfy({ $0.joint >= config.feedbackDeloadThreshold || $0.soreness >= config.feedbackDeloadThreshold }) {
            return .feedback
        }
        var failures = 0
        for session in sessions {
            if session.contains(where: { $0.reps < range.lowerBound }) { failures += 1 } else { break }
        }
        if failures >= config.consecutiveFailuresForDeload { return .repeatedFailure }
        return nil
    }

    private func build(prescription: ExercisePrescription, load: Kilograms?, reps: ClosedRange<Int>, rir: Int, sets: Int, decision: ProgressionDecision) -> PlannedExercise {
        let planned = (0..<max(sets, 1)).map { index in
            PlannedSet(index: index, targetLoad: load, targetReps: reps, targetRIR: rir)
        }
        return PlannedExercise(exerciseID: prescription.exerciseID, sets: planned, decision: decision, restSecondsOverride: prescription.restPolicyOverrideSeconds)
    }

    /// Groups sets by session, keeping the most recent session first and sets inside a session in index order.
    private func groupBySession(_ sets: [LoggedSet]) -> [[LoggedSet]] {
        var order: [SetmioCore.ID<LoggedSession>] = []
        var bySession: [SetmioCore.ID<LoggedSession>: [LoggedSet]] = [:]
        for set in sets {
            if bySession[set.sessionID] == nil { order.append(set.sessionID) }
            bySession[set.sessionID, default: []].append(set)
        }
        return order.map { bySession[$0]!.sorted { $0.index < $1.index } }
    }

    /// The most frequently used load in a session (the working load), falling back to the heaviest.
    private func dominantLoad(_ session: [LoggedSet]) -> Kilograms {
        var counts: [Double: Int] = [:]
        for s in session { counts[s.load, default: 0] += 1 }
        let best = counts.max { a, b in a.value == b.value ? a.key < b.key : a.value < b.value }
        return best?.key ?? (session.map(\.load).max() ?? 0)
    }
}

// MARK: - Readiness modulation (today only)

public struct ReadinessModulator: Sendable {
    public var redThreshold: Int
    public var greenThreshold: Int
    public var highThreshold: Int
    public var redLoadMultiplier: Double

    public init(redThreshold: Int = 45, greenThreshold: Int = 60, highThreshold: Int = 85, redLoadMultiplier: Double = 0.9) {
        self.redThreshold = redThreshold
        self.greenThreshold = greenThreshold
        self.highThreshold = highThreshold
        self.redLoadMultiplier = redLoadMultiplier
    }

    /// Returns an adjusted copy of `session`. The input is never mutated, so persisted progression state stays clean.
    public func modulate(_ session: PlannedSession, readiness: ReadinessScore?, categories: [SetmioCore.ID<Exercise>: ExerciseCategory] = [:], increments: [SetmioCore.ID<Exercise>: Kilograms] = [:]) -> PlannedSession {
        guard let readiness else { return session }
        var copy = session

        if readiness.score < redThreshold || readiness.flags.contains(.recoveryDayOverride) {
            copy.exercises = session.exercises.map { exercise in
                var e = exercise
                let increment = increments[exercise.exerciseID] ?? 2.5
                e.sets = Array(exercise.sets.dropLast(exercise.sets.count > 1 ? 1 : 0)).map { set in
                    var s = set
                    if let load = set.targetLoad { s.targetLoad = Stats.round(load * redLoadMultiplier, toNearest: increment) }
                    s.targetRIR = set.targetRIR + 1
                    return s
                }
                return e
            }
            copy.readinessAdjustment = ReadinessAdjustment(readinessScore: readiness.score, loadMultiplier: redLoadMultiplier, setsDelta: -1, rirDelta: 1,
                                                           noteZH: "恢复度偏低：重量 −10%，每个动作少 1 组，多留 1 次余力")
            return copy
        }

        if readiness.score < greenThreshold {
            if let index = session.exercises.lastIndex(where: { (categories[$0.exerciseID] ?? .compound) == .compound }),
               session.exercises[index].sets.count > 1 {
                copy.exercises[index].sets.removeLast()
            }
            copy.readinessAdjustment = ReadinessAdjustment(readinessScore: readiness.score, loadMultiplier: 1, setsDelta: -1, rirDelta: 0,
                                                           noteZH: "恢复度一般：最后一个复合动作少 1 组")
            return copy
        }

        if readiness.score >= highThreshold {
            copy.readinessAdjustment = ReadinessAdjustment(readinessScore: readiness.score, loadMultiplier: 1, setsDelta: 0, rirDelta: 0,
                                                           noteZH: "状态很好：主项可自选加 1 组")
        }
        return copy
    }
}

// MARK: - Rest timer policy

public struct RestTimerConfig: Sendable, Equatable {
    public var compoundSeconds = 180.0
    public var isolationSeconds = 90.0
    public var warmupSeconds = 60.0
    /// Added when the set was heavy (RIR ≤ 1 and reps ≤ 6).
    public var heavyBonusSeconds = 30.0
    public var lowReadinessBonusSeconds = 15.0
    public var lowReadinessThreshold = 45

    public init() {}
}

public struct RestTimerPolicy: Sendable {
    public let config: RestTimerConfig

    public init(config: RestTimerConfig = RestTimerConfig()) {
        self.config = config
    }

    public func duration(after set: LoggedSet, exercise: Exercise, next: PlannedSet?, readiness: ReadinessScore?, overrideSeconds: Int? = nil) -> TimeInterval {
        if let overrideSeconds { return TimeInterval(overrideSeconds) }
        if set.isWarmup || (next?.isWarmup ?? false) { return config.warmupSeconds }
        var seconds = exercise.category == .compound ? config.compoundSeconds : config.isolationSeconds
        if set.rir <= 1 && set.reps <= 6 { seconds += config.heavyBonusSeconds }
        if let readiness, readiness.score < config.lowReadinessThreshold { seconds += config.lowReadinessBonusSeconds }
        return seconds
    }
}
