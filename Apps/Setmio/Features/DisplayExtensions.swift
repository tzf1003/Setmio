import Foundation
import SetmioCore
import SetmioUI

// Chinese display text for Core enums that Core itself leaves unnamed (listed in openQuestions: candidates to
// move into SetmioCore if the watch or widgets ever need them).

extension HealthMetricKind {
    var nameZH: String {
        switch self {
        case .bodyMass: "体重"
        case .bodyFatPercentage: "体脂率"
        case .leanBodyMass: "瘦体重"
        case .heartRate: "心率"
        case .restingHeartRate: "静息心率"
        case .hrvSDNN: "HRV (SDNN)"
        case .hrvRMSSD: "HRV (RMSSD)"
        case .respiratoryRate: "呼吸频率"
        case .wristTemperature: "腕温"
        case .steps: "步数"
        case .activeEnergy: "活动能量"
        case .basalEnergy: "基础能量"
        case .sleep: "睡眠"
        case .workout: "训练记录"
        case .workoutEffort: "训练强度"
        }
    }
}

extension ReadinessComponent.Kind {
    var nameZH: String {
        switch self {
        case .hrv: "HRV 7 日趋势"
        case .hrvAcute: "今日 HRV"
        case .rhr: "静息心率"
        case .sleep: "睡眠"
        case .load: "训练负荷"
        case .subjective: "主观状态"
        }
    }
}

extension ReadinessFlag {
    var nameZH: String {
        switch self {
        case .recoveryDayOverride: "多项夜间指标偏离个人基线，建议今天以恢复为主"
        case .detraining: "近四周训练量明显下降"
        case .lowConfidence: "基线天数不足，评分仅供参考"
        }
    }
}

extension ProgressionDecision {
    var explanationZH: String {
        switch self {
        case .hold(let reason): reason
        case .increaseLoad(let by): "上次全部达到次数上限且余力充足：加重 \(SetmioFormat.compactKg(by))"
        case .addSet: "上次完成轻松、反馈良好：本次多做 1 组"
        case .deload(let reason):
            switch reason {
            case .e1rmDrop: "连续两次 e1RM 低于本周期最佳 5% 以上：减载（重量 −10%）"
            case .feedback: "最近两次酸痛或关节不适偏高：减载"
            case .readinessStreak: "近 5 天内 3 天恢复度偏低：减载"
            case .mesocycleEnd: "周期减载周：组数 60%、重量 −10%、多留余力"
            case .repeatedFailure: "连续三次未达最低次数：减载后重新累积"
            }
        }
    }

    var shortLabelZH: String {
        switch self {
        case .hold: "保持"
        case .increaseLoad: "加重"
        case .addSet: "加组"
        case .deload: "减载"
        }
    }
}

extension SessionOrigin {
    var nameZH: String {
        switch self {
        case .watch: "手表"
        case .phone: "手机"
        case .importedFromHealth: "健康导入"
        }
    }
}

extension BiologicalSex {
    var nameZH: String {
        switch self {
        case .male: "男"
        case .female: "女"
        case .other: "其他"
        }
    }
}

/// The protein standards offered in Settings, keyed by a stable tag for the picker.
enum ProteinStandardChoice: String, CaseIterable, Identifiable {
    case usAdvisory, lifter, chinaDraft, leanMass

    var id: String { rawValue }

    var nameZH: String {
        switch self {
        case .usAdvisory: "1.6 g/kg 体重"
        case .lifter: "2.0 g/kg 体重"
        case .chinaDraft: "1.2 g/kg 理想体重（国内草案）"
        case .leanMass: "2.2 g/kg 瘦体重"
        }
    }

    var standard: ProteinStandard {
        switch self {
        case .usAdvisory: .usAdvisory
        case .lifter: .perKgBodyweight(gPerKg: 2.0)
        case .chinaDraft: .chinaDraft
        case .leanMass: .perKgLeanMass(gPerKg: 2.2)
        }
    }

    init(_ standard: ProteinStandard) {
        switch standard {
        case .perKgBodyweight(let g) where g >= 1.9: self = .lifter
        case .perKgBodyweight: self = .usAdvisory
        case .perKgIdealBodyweight: self = .chinaDraft
        case .perKgLeanMass: self = .leanMass
        case .fixedGrams: self = .usAdvisory
        }
    }
}
