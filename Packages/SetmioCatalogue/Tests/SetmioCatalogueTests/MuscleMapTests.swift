import Foundation
import Testing
@testable import SetmioCatalogue

@Suite("Target to body-map regions")
struct MuscleMapTests {
    @Test("every target maps to at least one region")
    func everyTargetMapped() {
        for target in TargetMuscle.allCases {
            #expect(!target.regions.isEmpty, "\(target.rawValue) maps to no region")
        }
    }

    @Test("every region is reachable from some target, so no region is dead")
    func everyRegionReachable() {
        let reached = Set(TargetMuscle.allCases.flatMap(\.regions))
        #expect(reached == Set(MuscleRegion.allCases))
    }

    @Test("every bundled exercise lights at least one region")
    func bundledExercisesMapped() throws {
        let unmapped = try Bundled.catalogue().all.filter { ($0.target?.regions ?? []).isEmpty }.map(\.id)
        #expect(unmapped.isEmpty)
    }

    @Test("regions are split between the front and back views as drawn")
    func sides() {
        #expect(MuscleRegion.chest.side == .front)
        #expect(MuscleRegion.glutes.side == .back)
        #expect(MuscleRegion.rearDelts.side == .back)
        #expect(MuscleRegion.allCases.filter { $0.side == .back }.count == 9)
    }

    @Test("the targets that light several regions do so as documented")
    func multiRegionTargets() {
        #expect(TargetMuscle.delts.regions == [.shoulders, .rearDelts])
        #expect(TargetMuscle.abs.regions == [.abs, .obliques])
        #expect(TargetMuscle.levatorScapulae.regions == [.neck, .traps])
        #expect(TargetMuscle.cardiovascularSystem.regions == [.wholeBody])
    }
}
