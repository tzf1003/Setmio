import Foundation

/// The body-map view a region is drawn on.
public enum BodySide: String, Sendable, Codable, CaseIterable, Hashable {
    case front
    case back
}

/// A region of the body map the UI can highlight. This list is Setmio's own and deliberately coarser than
/// upstream's muscle names. `TargetMuscle.regions` is the only bridge from upstream words to these regions.
public enum MuscleRegion: String, Sendable, Codable, CaseIterable, Hashable {
    // Front view.
    case chest
    case shoulders
    case biceps
    case forearms
    case abs
    case obliques
    case serratus
    case neck
    case quads
    case adductors
    case abductors
    // Back view.
    case upperBack
    case lats
    case traps
    case rearDelts
    case triceps
    case lowerBack
    case glutes
    case hamstrings
    case calves
    // Not a single muscle. Used for cardio, which works the whole body.
    case wholeBody

    /// The view this region is drawn on. Each region has exactly one side, so a muscle that is also visible from the
    /// other side (forearm extensors, the back of the neck) is drawn only on the side listed here.
    public var side: BodySide {
        switch self {
        case .chest, .shoulders, .biceps, .forearms, .abs, .obliques, .serratus, .neck,
             .quads, .adductors, .abductors:
            .front
        case .upperBack, .lats, .traps, .rearDelts, .triceps, .lowerBack, .glutes, .hamstrings, .calves:
            .back
        // The silhouette is highlighted in both views; `.front` only fixes where the region is listed.
        case .wholeBody:
            .front
        }
    }

    public var nameZH: String {
        switch self {
        case .chest: "胸肌"
        case .shoulders: "三角肌（前、中束）"
        case .biceps: "肱二头肌"
        case .forearms: "前臂"
        case .abs: "腹直肌"
        case .obliques: "腹斜肌"
        case .serratus: "前锯肌"
        case .neck: "颈部"
        case .quads: "股四头肌"
        case .adductors: "内收肌"
        case .abductors: "外展肌"
        case .upperBack: "上背部"
        case .lats: "背阔肌"
        case .traps: "斜方肌"
        case .rearDelts: "三角肌（后束）"
        case .triceps: "肱三头肌"
        case .lowerBack: "下背部"
        case .glutes: "臀大肌"
        case .hamstrings: "腘绳肌"
        case .calves: "小腿三头肌"
        case .wholeBody: "全身"
        }
    }
}

public extension TargetMuscle {
    /// Body-map regions this upstream target lights up. Never empty (see `MuscleMapTests`).
    ///
    /// Mapping choices, because upstream's vocabulary is coarser than the body map:
    /// - `abs` also lights `obliques`. Upstream has no oblique target, and much of its `abs` work is side or twisting.
    /// - `delts` lights `shoulders` (front and side heads) and `rearDelts`, since upstream does not split the heads.
    /// - `cardiovascularSystem` lights `wholeBody`. There is no single muscle to draw, so the whole silhouette is shown.
    /// - `spine` lights `lowerBack`. Upstream's spine work is mostly erector-spinae extension (back extensions).
    /// - `levatorScapulae` lights `neck` and `traps`. The muscle runs from the upper vertebrae to the shoulder blade.
    /// - `serratusAnterior` gets its own front region, because it is not part of the abs or obliques.
    /// - `forearms` is drawn on the front. The extensors on the back are not drawn separately.
    var regions: [MuscleRegion] {
        switch self {
        case .abs: [.abs, .obliques]
        case .glutes: [.glutes]
        case .quads: [.quads]
        case .delts: [.shoulders, .rearDelts]
        case .pectorals: [.chest]
        case .lats: [.lats]
        case .biceps: [.biceps]
        case .triceps: [.triceps]
        case .calves: [.calves]
        case .upperBack: [.upperBack]
        case .hamstrings: [.hamstrings]
        case .cardiovascularSystem: [.wholeBody]
        case .spine: [.lowerBack]
        case .forearms: [.forearms]
        case .abductors: [.abductors]
        case .adductors: [.adductors]
        case .levatorScapulae: [.neck, .traps]
        case .traps: [.traps]
        case .serratusAnterior: [.serratus]
        }
    }
}
