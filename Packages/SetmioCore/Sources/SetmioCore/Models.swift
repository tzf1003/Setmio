import Foundation

public struct Exercise: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var muscleGroup: String

    public init(id: UUID = UUID(), name: String, muscleGroup: String) {
        self.id = id
        self.name = name
        self.muscleGroup = muscleGroup
    }
}

public struct PlannedSet: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var exercise: Exercise
    public var reps: Int
    public var weightKg: Double

    public init(id: UUID = UUID(), exercise: Exercise, reps: Int, weightKg: Double) {
        self.id = id
        self.exercise = exercise
        self.reps = reps
        self.weightKg = weightKg
    }

    public var volumeKg: Double { Double(reps) * weightKg }
}

public struct WorkoutPlan: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var sets: [PlannedSet]

    public init(id: UUID = UUID(), name: String, sets: [PlannedSet] = []) {
        self.id = id
        self.name = name
        self.sets = sets
    }

    public var totalVolumeKg: Double { sets.reduce(0) { $0 + $1.volumeKg } }
}
