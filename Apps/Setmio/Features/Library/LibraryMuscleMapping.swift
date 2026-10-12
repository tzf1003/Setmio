import SetmioCatalogue

#if canImport(MuscleMap)
import MuscleMap

/// Connects the library's `MuscleRegion`s to MuscleMap's drawing, in both directions: which `Muscle`s to paint for a
/// region, and which region a tapped `Muscle` belongs to. MuscleMap's own `parentGroup` is not used for taps, because it
/// maps adductors to hamstring and serratus to obliques (checked in MuscleMap 1.9.0).
enum LibraryMuscleMapping {
    /// Muscles to highlight for `region`, on the side that region is drawn on.
    static func muscles(for region: MuscleRegion) -> [Muscle] {
        switch region {
        case .chest: [.chest, .upperChest, .lowerChest]
        case .shoulders: [.deltoids, .frontDeltoid]
        case .biceps: [.biceps]
        case .forearms: [.forearm]
        case .abs: [.abs, .upperAbs, .lowerAbs]
        case .obliques: [.obliques]
        case .serratus: [.serratus]
        case .neck: [.neck]
        case .quads: [.quadriceps, .innerQuad, .outerQuad]
        case .adductors: [.adductors]
        // No dedicated artwork: the glutes are the nearest drawing, so abductors share it (a known weak match).
        case .abductors: [.gluteal]
        case .upperBack: [.upperBack, .rhomboids, .rotatorCuff]
        case .lats: [.upperBack]
        case .traps: [.trapezius, .upperTrapezius, .lowerTrapezius]
        case .rearDelts: [.rearDeltoid]
        case .triceps: [.triceps]
        case .lowerBack: [.lowerBack]
        case .glutes: [.gluteal]
        case .hamstrings: [.hamstring]
        case .calves: [.calves]
        // Cardio has no single muscle to paint.
        case .wholeBody: []
        }
    }

    /// The region a tapped muscle stands for, or nil for parts the library has no exercises for (head, hands, feet...).
    static func region(for muscle: Muscle) -> MuscleRegion? {
        switch muscle {
        case .chest, .upperChest, .lowerChest: .chest
        case .deltoids, .frontDeltoid: .shoulders
        case .rearDeltoid: .rearDelts
        case .biceps: .biceps
        case .forearm: .forearms
        case .abs, .upperAbs, .lowerAbs: .abs
        case .obliques: .obliques
        case .serratus: .serratus
        case .neck: .neck
        case .quadriceps, .innerQuad, .outerQuad: .quads
        case .adductors: .adductors
        case .upperBack, .rhomboids, .rotatorCuff: .upperBack
        case .trapezius, .upperTrapezius, .lowerTrapezius: .traps
        case .triceps: .triceps
        case .lowerBack: .lowerBack
        case .gluteal: .glutes
        case .hamstring: .hamstrings
        case .calves: .calves
        default: nil
        }
    }

    /// Muscles to paint for a set of selected targets.
    static func muscles(for targets: Set<TargetMuscle>) -> Set<Muscle> {
        var result: Set<Muscle> = []
        for target in targets {
            for region in target.regions { result.formUnion(muscles(for: region)) }
        }
        return result
    }

    /// Targets a tap on `muscle` should toggle: every target that lights the tapped region.
    static func targets(for muscle: Muscle) -> Set<TargetMuscle> {
        guard let region = region(for: muscle) else { return [] }
        return Set(TargetMuscle.allCases.filter { $0.regions.contains(region) })
    }
}
#endif
