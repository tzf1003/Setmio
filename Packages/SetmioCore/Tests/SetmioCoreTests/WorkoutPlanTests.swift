import XCTest
@testable import SetmioCore

final class WorkoutPlanTests: XCTestCase {
    func testTotalVolume() {
        let squat = Exercise(name: "Squat", muscleGroup: "Legs")
        let plan = WorkoutPlan(name: "Leg Day", sets: [
            PlannedSet(exercise: squat, reps: 5, weightKg: 100),
            PlannedSet(exercise: squat, reps: 5, weightKg: 110),
        ])
        XCTAssertEqual(plan.totalVolumeKg, 1050)
    }
}
