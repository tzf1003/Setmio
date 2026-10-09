import Foundation

// MARK: - Exercise library

public enum MuscleGroup: String, Codable, Sendable, CaseIterable, Hashable {
    case chest, back, shoulders, biceps, triceps, forearms
    case quads, hamstrings, glutes, calves, core

    public var nameZH: String {
        switch self {
        case .chest: "胸"
        case .back: "背"
        case .shoulders: "肩"
        case .biceps: "二头"
        case .triceps: "三头"
        case .forearms: "前臂"
        case .quads: "股四头"
        case .hamstrings: "腘绳肌"
        case .glutes: "臀"
        case .calves: "小腿"
        case .core: "核心"
        }
    }
}

public enum ExerciseCategory: String, Codable, Sendable, CaseIterable, Hashable {
    case compound, isolation
}

public enum Equipment: String, Codable, Sendable, CaseIterable, Hashable {
    case barbell, dumbbell, machine, cable, bodyweight, smith, kettlebell
}

/// V2: parameters for on-wrist rep estimation (peak detection on a known movement template).
public struct RepTemplate: Sendable, Codable, Equatable, Hashable {
    /// Which device-motion axis carries the dominant oscillation ("x", "y", "z" or "magnitude").
    public var axis: String
    /// Minimum seconds between two counted peaks.
    public var minPeakIntervalSeconds: Double
    /// Peak threshold in g after gravity removal.
    public var peakThresholdG: Double

    public init(axis: String = "magnitude", minPeakIntervalSeconds: Double = 0.8, peakThresholdG: Double = 0.15) {
        self.axis = axis
        self.minPeakIntervalSeconds = minPeakIntervalSeconds
        self.peakThresholdG = peakThresholdG
    }
}

public struct Exercise: Identifiable, Sendable, Codable, Hashable {
    public var id: SetmioCore.ID<Exercise>
    public var nameZH: String
    public var nameEN: String?
    public var primary: [MuscleGroup]
    public var secondary: [MuscleGroup]
    public var category: ExerciseCategory
    public var equipment: Equipment
    /// Smallest practical load step in kg (2.5 for most barbell upper-body lifts, 5 for squat/deadlift).
    public var loadIncrement: Kilograms
    public var isUnilateral: Bool
    public var repTemplate: RepTemplate?
    public var isCustom: Bool

    public init(
        id: SetmioCore.ID<Exercise> = SetmioCore.ID(),
        nameZH: String,
        nameEN: String? = nil,
        primary: [MuscleGroup],
        secondary: [MuscleGroup] = [],
        category: ExerciseCategory,
        equipment: Equipment,
        loadIncrement: Kilograms = 2.5,
        isUnilateral: Bool = false,
        repTemplate: RepTemplate? = nil,
        isCustom: Bool = false
    ) {
        self.id = id
        self.nameZH = nameZH
        self.nameEN = nameEN
        self.primary = primary
        self.secondary = secondary
        self.category = category
        self.equipment = equipment
        self.loadIncrement = loadIncrement
        self.isUnilateral = isUnilateral
        self.repTemplate = repTemplate
        self.isCustom = isCustom
    }
}

// MARK: - Programs and mesocycles

public enum ProgressionRule: Sendable, Codable, Equatable, Hashable {
    /// Add reps inside the range; when every set hits the top at or above target RIR, add load and reset to the bottom.
    case doubleProgression
    /// Prescribe load as a percentage of the recent estimated 1RM (RTS style).
    case rtsPercent(targetPercentOfE1RM: Double)
}

public struct ExercisePrescription: Sendable, Codable, Equatable, Hashable {
    public var exerciseID: SetmioCore.ID<Exercise>
    public var sets: Int
    public var repRange: ClosedRange<Int>
    public var progression: ProgressionRule
    public var restPolicyOverrideSeconds: Int?

    public init(
        exerciseID: SetmioCore.ID<Exercise>,
        sets: Int,
        repRange: ClosedRange<Int>,
        progression: ProgressionRule = .doubleProgression,
        restPolicyOverrideSeconds: Int? = nil
    ) {
        self.exerciseID = exerciseID
        self.sets = sets
        self.repRange = repRange
        self.progression = progression
        self.restPolicyOverrideSeconds = restPolicyOverrideSeconds
    }
}

public struct ProgramDay: Sendable, Codable, Equatable, Hashable {
    public var nameZH: String
    public var prescriptions: [ExercisePrescription]

    public init(nameZH: String, prescriptions: [ExercisePrescription]) {
        self.nameZH = nameZH
        self.prescriptions = prescriptions
    }
}

public struct ProgramTemplate: Identifiable, Sendable, Codable, Equatable, Hashable {
    public var id: SetmioCore.ID<ProgramTemplate>
    public var nameZH: String
    public var daysPerWeek: Int
    public var days: [ProgramDay]
    /// Total weeks in one mesocycle including the deload week (e.g. 4 working + 1 deload = 5).
    public var mesocycleWeeks: Int

    public init(id: SetmioCore.ID<ProgramTemplate> = SetmioCore.ID(), nameZH: String, daysPerWeek: Int, days: [ProgramDay], mesocycleWeeks: Int = 5) {
        self.id = id
        self.nameZH = nameZH
        self.daysPerWeek = daysPerWeek
        self.days = days
        self.mesocycleWeeks = mesocycleWeeks
    }
}

public struct MesocycleWeek: Sendable, Codable, Equatable, Hashable {
    public var index: Int
    /// Reps-in-reserve target for working sets this week (3 → 2 → 1 → 0, deload ≥ 3).
    public var targetRIR: Int
    public var isDeload: Bool

    public init(index: Int, targetRIR: Int, isDeload: Bool) {
        self.index = index
        self.targetRIR = targetRIR
        self.isDeload = isDeload
    }

    /// Default hypertrophy block: RIR 3, 2, 1, 1 then a deload at RIR 3.
    public static func defaultBlock(workingWeeks: Int = 4) -> [MesocycleWeek] {
        let rirs = [3, 2, 1, 1, 0, 0]
        var weeks: [MesocycleWeek] = []
        for i in 0..<max(workingWeeks, 1) {
            weeks.append(MesocycleWeek(index: i, targetRIR: rirs[min(i, rirs.count - 1)], isDeload: false))
        }
        weeks.append(MesocycleWeek(index: weeks.count, targetRIR: 3, isDeload: true))
        return weeks
    }
}

public struct Mesocycle: Identifiable, Sendable, Codable, Equatable, Hashable {
    public var id: SetmioCore.ID<Mesocycle>
    public var templateID: SetmioCore.ID<ProgramTemplate>
    public var startDay: DayKey
    public var weeks: [MesocycleWeek]
    public var currentWeekIndex: Int
    public var isActive: Bool

    public init(
        id: SetmioCore.ID<Mesocycle> = SetmioCore.ID(),
        templateID: SetmioCore.ID<ProgramTemplate>,
        startDay: DayKey,
        weeks: [MesocycleWeek] = MesocycleWeek.defaultBlock(),
        currentWeekIndex: Int = 0,
        isActive: Bool = true
    ) {
        self.id = id
        self.templateID = templateID
        self.startDay = startDay
        self.weeks = weeks
        self.currentWeekIndex = currentWeekIndex
        self.isActive = isActive
    }

    public var currentWeek: MesocycleWeek? {
        weeks.indices.contains(currentWeekIndex) ? weeks[currentWeekIndex] : weeks.last
    }
}

// MARK: - Planned sessions

public enum DeloadReason: String, Sendable, Codable, Hashable {
    case e1rmDrop, feedback, readinessStreak, mesocycleEnd, repeatedFailure
}

public enum ProgressionDecision: Sendable, Codable, Equatable, Hashable {
    case hold(reason: String)
    case increaseLoad(by: Kilograms)
    case addSet
    case deload(DeloadReason)
}

public struct ReadinessAdjustment: Sendable, Codable, Equatable, Hashable {
    public var readinessScore: Int
    public var loadMultiplier: Double
    public var setsDelta: Int
    public var rirDelta: Int
    public var noteZH: String

    public init(readinessScore: Int, loadMultiplier: Double, setsDelta: Int, rirDelta: Int, noteZH: String) {
        self.readinessScore = readinessScore
        self.loadMultiplier = loadMultiplier
        self.setsDelta = setsDelta
        self.rirDelta = rirDelta
        self.noteZH = noteZH
    }
}

public struct PlannedSet: Identifiable, Sendable, Codable, Equatable, Hashable {
    public var id: SetmioCore.ID<PlannedSet>
    public var index: Int
    public var targetLoad: Kilograms?
    public var targetReps: ClosedRange<Int>
    public var targetRIR: Int
    public var isWarmup: Bool

    public init(id: SetmioCore.ID<PlannedSet> = SetmioCore.ID(), index: Int, targetLoad: Kilograms?, targetReps: ClosedRange<Int>, targetRIR: Int, isWarmup: Bool = false) {
        self.id = id
        self.index = index
        self.targetLoad = targetLoad
        self.targetReps = targetReps
        self.targetRIR = targetRIR
        self.isWarmup = isWarmup
    }
}

public struct PlannedExercise: Sendable, Codable, Equatable, Hashable {
    public var exerciseID: SetmioCore.ID<Exercise>
    public var sets: [PlannedSet]
    public var decision: ProgressionDecision
    public var restSecondsOverride: Int?

    public init(exerciseID: SetmioCore.ID<Exercise>, sets: [PlannedSet], decision: ProgressionDecision, restSecondsOverride: Int? = nil) {
        self.exerciseID = exerciseID
        self.sets = sets
        self.decision = decision
        self.restSecondsOverride = restSecondsOverride
    }
}

public struct PlannedSession: Identifiable, Sendable, Codable, Equatable, Hashable {
    public var id: SetmioCore.ID<PlannedSession>
    public var mesocycleID: SetmioCore.ID<Mesocycle>?
    public var day: DayKey
    public var dayNameZH: String
    public var exercises: [PlannedExercise]
    /// Today-only modulation. Never written back into progression state.
    public var readinessAdjustment: ReadinessAdjustment?

    public init(
        id: SetmioCore.ID<PlannedSession> = SetmioCore.ID(),
        mesocycleID: SetmioCore.ID<Mesocycle>?,
        day: DayKey,
        dayNameZH: String,
        exercises: [PlannedExercise],
        readinessAdjustment: ReadinessAdjustment? = nil
    ) {
        self.id = id
        self.mesocycleID = mesocycleID
        self.day = day
        self.dayNameZH = dayNameZH
        self.exercises = exercises
        self.readinessAdjustment = readinessAdjustment
    }
}

// MARK: - Logged sessions

public struct Tempo: Sendable, Codable, Equatable, Hashable {
    public var eccentric: Int
    public var pauseBottom: Int
    public var concentric: Int
    public var pauseTop: Int

    public init(eccentric: Int, pauseBottom: Int, concentric: Int, pauseTop: Int) {
        self.eccentric = eccentric
        self.pauseBottom = pauseBottom
        self.concentric = concentric
        self.pauseTop = pauseTop
    }
}

public enum SessionOrigin: String, Sendable, Codable, Hashable {
    case watch, phone, importedFromHealth
}

public struct SessionFeedback: Sendable, Codable, Equatable, Hashable {
    /// 1 (none) … 4 (severe), RP-style.
    public var soreness: Int
    public var pump: Int
    public var joint: Int
    public var note: String?

    public init(soreness: Int, pump: Int, joint: Int, note: String? = nil) {
        self.soreness = soreness
        self.pump = pump
        self.joint = joint
        self.note = note
    }
}

public struct LoggedSet: Identifiable, Sendable, Codable, Equatable, Hashable {
    public var id: SetmioCore.ID<LoggedSet>
    public var sessionID: SetmioCore.ID<LoggedSession>
    public var exerciseID: SetmioCore.ID<Exercise>
    public var index: Int
    public var load: Kilograms
    public var reps: Int
    /// Reps in reserve; RPE = 10 − RIR.
    public var rir: Int
    public var tempo: Tempo?
    public var startedAt: Date?
    public var completedAt: Date
    public var isWarmup: Bool
    /// V2: on-wrist sensor estimate shown as an editable prefill.
    public var estimatedReps: Int?

    public init(
        id: SetmioCore.ID<LoggedSet> = SetmioCore.ID(),
        sessionID: SetmioCore.ID<LoggedSession>,
        exerciseID: SetmioCore.ID<Exercise>,
        index: Int,
        load: Kilograms,
        reps: Int,
        rir: Int,
        tempo: Tempo? = nil,
        startedAt: Date? = nil,
        completedAt: Date,
        isWarmup: Bool = false,
        estimatedReps: Int? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.exerciseID = exerciseID
        self.index = index
        self.load = load
        self.reps = reps
        self.rir = rir
        self.tempo = tempo
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.isWarmup = isWarmup
        self.estimatedReps = estimatedReps
    }

    public var volume: Kilograms { load * Double(reps) }
}

public struct LoggedSession: Identifiable, Sendable, Codable, Equatable, Hashable {
    public var id: SetmioCore.ID<LoggedSession>
    public var plannedSessionID: SetmioCore.ID<PlannedSession>?
    public var start: Date
    public var end: Date?
    public var sets: [LoggedSet]
    public var feedback: SessionFeedback?
    public var hkWorkoutUUID: UUID?
    /// Apple workout effort score 1–10 (user rated).
    public var effortScore: Int?
    public var origin: SessionOrigin
    /// Bumped on every phone-side edit; the watch never sends revision > 0.
    public var revision: Int

    public init(
        id: SetmioCore.ID<LoggedSession> = SetmioCore.ID(),
        plannedSessionID: SetmioCore.ID<PlannedSession>? = nil,
        start: Date,
        end: Date? = nil,
        sets: [LoggedSet] = [],
        feedback: SessionFeedback? = nil,
        hkWorkoutUUID: UUID? = nil,
        effortScore: Int? = nil,
        origin: SessionOrigin,
        revision: Int = 0
    ) {
        self.id = id
        self.plannedSessionID = plannedSessionID
        self.start = start
        self.end = end
        self.sets = sets
        self.feedback = feedback
        self.hkWorkoutUUID = hkWorkoutUUID
        self.effortScore = effortScore
        self.origin = origin
        self.revision = revision
    }

    public var durationMinutes: Minutes? {
        guard let end else { return nil }
        return end.timeIntervalSince(start) / 60
    }

    public var totalVolume: Kilograms {
        sets.filter { !$0.isWarmup }.reduce(0) { $0 + $1.volume }
    }
}
