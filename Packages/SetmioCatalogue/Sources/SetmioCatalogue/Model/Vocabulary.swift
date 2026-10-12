import Foundation

// Closed vocabularies for the upstream catalogue. Each `rawValue` is the exact upstream string, so the bundled
// JSON decodes straight into these cases. A value that is not listed here decodes to nil instead of failing, and
// `VocabularyTests` plus `CatalogueDataTests` fail as soon as the bundled data contains a word missing from this file.

/// Upstream `bodyPart` (11 values).
public enum BodyPartCategory: String, Sendable, Codable, CaseIterable, Hashable {
    case upperLegs = "upper legs"
    case waist
    case back
    case shoulders
    case upperArms = "upper arms"
    case chest
    case lowerLegs = "lower legs"
    case fullBody = "full body"
    case lowerArms = "lower arms"
    case cardio
    case neck

    public var nameZH: String {
        switch self {
        case .upperLegs: "大腿"
        case .waist: "腰腹"
        case .back: "背部"
        case .shoulders: "肩部"
        case .upperArms: "上臂"
        case .chest: "胸部"
        case .lowerLegs: "小腿"
        case .fullBody: "全身"
        case .lowerArms: "前臂"
        case .cardio: "有氧"
        case .neck: "颈部"
        }
    }
}

/// Upstream `target` (19 values): the primary muscle an exercise trains. `regions` maps each one onto body-map regions.
public enum TargetMuscle: String, Sendable, Codable, CaseIterable, Hashable {
    case abs
    case glutes
    case quads
    case delts
    case pectorals
    case lats
    case biceps
    case triceps
    case calves
    case upperBack = "upper back"
    case hamstrings
    case cardiovascularSystem = "cardiovascular system"
    case spine
    case forearms
    case abductors
    case adductors
    case levatorScapulae = "levator scapulae"
    case traps
    case serratusAnterior = "serratus anterior"

    public var nameZH: String {
        switch self {
        case .abs: "腹肌"
        case .glutes: "臀部"
        case .quads: "股四头肌"
        case .delts: "三角肌"
        case .pectorals: "胸肌"
        case .lats: "背阔肌"
        case .biceps: "肱二头肌"
        case .triceps: "肱三头肌"
        case .calves: "小腿肌群"
        case .upperBack: "上背部"
        case .hamstrings: "腘绳肌"
        case .cardiovascularSystem: "心血管系统"
        case .spine: "脊柱"
        case .forearms: "前臂"
        case .abductors: "外展肌"
        case .adductors: "内收肌"
        case .levatorScapulae: "肩胛提肌"
        case .traps: "斜方肌"
        case .serratusAnterior: "前锯肌"
        }
    }
}

/// Upstream `equipment` (33 values).
public enum EquipmentKind: String, Sendable, Codable, CaseIterable, Hashable {
    case bodyWeight = "body weight"
    case dumbbell
    case cable
    case barbell
    case leverageMachine = "leverage machine"
    case band
    case kettlebell
    case resistanceBand = "resistance band"
    case weighted
    case suspensionTrainer = "suspension trainer"
    case roller
    case smithMachine = "smith machine"
    case stabilityBall = "stability ball"
    case ezBarbell = "ez barbell"
    case medicineBall = "medicine ball"
    case sledMachine = "sled machine"
    case weightPlate = "weight plate"
    case rope
    case assisted
    case landmine
    case bosuBall = "bosu ball"
    case sandbag
    case trapBar = "trap bar"
    case olympicBarbell = "olympic barbell"
    case ellipticalMachine = "elliptical machine"
    case stationaryBike = "stationary bike"
    case wheelRoller = "wheel roller"
    case macebell
    case tire
    case hammer
    case skiergMachine = "skierg machine"
    case stepmillMachine = "stepmill machine"
    case upperBodyErgometer = "upper body ergometer"

    public var nameZH: String {
        switch self {
        case .bodyWeight: "自重"
        case .dumbbell: "哑铃"
        case .cable: "拉索"
        case .barbell: "杠铃"
        case .leverageMachine: "杠杆器械"
        case .band: "弹力带"
        case .kettlebell: "壶铃"
        case .resistanceBand: "阻力带"
        case .weighted: "负重"
        case .suspensionTrainer: "悬挂训练带"
        case .roller: "滚轴"
        case .smithMachine: "史密斯机"
        case .stabilityBall: "稳定球"
        case .ezBarbell: "EZ杠"
        case .medicineBall: "药球"
        case .sledMachine: "滑车机"
        case .weightPlate: "杠铃片"
        case .rope: "绳索"
        case .assisted: "辅助器械"
        case .landmine: "地雷杆"
        case .bosuBall: "BOSU球"
        case .sandbag: "沙袋"
        case .trapBar: "六角杠"
        case .olympicBarbell: "奥林匹克杠"
        case .ellipticalMachine: "椭圆机"
        case .stationaryBike: "健身单车"
        case .wheelRoller: "健腹轮"
        case .macebell: "钢制重锤"
        case .tire: "轮胎"
        case .hammer: "大锤"
        case .skiergMachine: "滑雪机"
        case .stepmillMachine: "阶梯机"
        case .upperBodyErgometer: "手摇车"
        }
    }
}

/// Where an entry's English text came from. Upstream marks the original ExerciseDB-derived entries `exercisedb`
/// (MIT, see NOTICE.md) and everything else `opengym` (AGPL-3.0). `unknown` covers a missing or unrecognised value.
public enum TextSource: String, Sendable, Codable, CaseIterable, Hashable {
    case exercisedb
    case opengym
    case unknown
}
