import Foundation

// MARK: - Label table loading

public extension GLP1LabelTable {
    enum LoadError: Error, Sendable { case resourceMissing(String) }

    /// Loads the bundled, versioned label table for a market (default mainland China).
    static func loadBundled(market: String = "cn", version: Int = 1) throws -> GLP1LabelTable {
        let name = "glp1_labels_\(market.lowercased())_v\(version)"
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: name, withExtension: "json") else {
            throw LoadError.resourceMissing(name)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(GLP1LabelTable.self, from: data)
    }
}

// MARK: - Hard blocks

public enum HardBlock: Error, Sendable, Equatable, Hashable {
    case doseExceedsLabelMax(maxMg: Milligrams)
    case skippedStep(expectedNextMg: Milligrams)
    case escalationTooSoon(daysOnStep: Int, requiredDays: Int)
    /// Also covers "doubling up" a missed dose.
    case minIntervalViolation(hoursSinceLast: Int, requiredHours: Int)
    case doseNotOnLadder
    /// Vials and unverified products get no mg→mL math and no plan templates.
    case vialVolumeMathUnsupported
    case penInUseExpired(expiry: Date)
    case unknownDrug

    public var messageZH: String {
        switch self {
        case .doseExceedsLabelMax(let max): "超过说明书最大剂量 \(Self.fmt(max)) mg"
        case .skippedStep(let next): "不能跳档：按阶梯下一档应为 \(Self.fmt(next)) mg"
        case .escalationTooSoon(let days, let required): "当前档位仅 \(days) 天，说明书要求至少 \(required) 天后再加量"
        case .minIntervalViolation(let hours, let required): "距上一针仅 \(hours) 小时，至少需间隔 \(required) 小时；请勿补打双倍剂量"
        case .doseNotOnLadder: "该剂量不在说明书阶梯上"
        case .vialVolumeMathUnsupported: "瓶装 / 未验证来源的产品不提供剂量换算与计划模板"
        case .penInUseExpired: "这支笔已超过首次使用后的有效期，请更换"
        case .unknownDrug: "未知药物"
        }
    }

    static func fmt(_ mg: Milligrams) -> String {
        mg == mg.rounded() ? String(Int(mg)) : String(format: "%.2g", mg)
    }
}

// MARK: - Plan validator

public struct GLP1PlanValidator: Sendable {
    public let table: GLP1LabelTable

    public init(table: GLP1LabelTable) {
        self.table = table
    }

    /// Checks a dose about to be logged against the label and the user's plan.
    public func validate(dose: DoseLog, medication: Medication, plan: GLP1Plan?, history: [DoseLog], pen: PenInventory?, now: Date, calendar: Calendar = .setmioDefault) -> Result<Void, HardBlock> {
        if medication.form.isVial || medication.isUnverifiedSource {
            return .failure(.vialVolumeMathUnsupported)
        }
        guard let drug = table.drug(medication.drug) else { return .failure(.unknownDrug) }

        if dose.doseMg > drug.maxMg + 0.011 { return .failure(.doseExceedsLabelMax(maxMg: drug.maxMg)) }
        guard let doseIndex = drug.stepIndex(of: dose.doseMg) else {
            if plan?.clinicianConfirmedOffLabel == true { /* allowed, no ladder checks */ } else { return .failure(.doseNotOnLadder) }
            return checkInterval(dose: dose, drug: drug, history: history, pen: pen)
        }

        if case .failure(let block) = checkInterval(dose: dose, drug: drug, history: history, pen: pen) {
            return .failure(block)
        }

        guard let plan, let current = plan.currentStep else { return .success(()) }
        let currentIndex = drug.stepIndex(of: current.doseMg) ?? doseIndex
        if doseIndex <= currentIndex { return .success(()) }   // same step or a label-permitted step-down
        let expectedNext = drug.steps.indices.contains(currentIndex + 1) ? drug.steps[currentIndex + 1] : drug.maxMg
        if doseIndex > currentIndex + 1 { return .failure(.skippedStep(expectedNextMg: expectedNext)) }

        let daysOnStep = Self.daysOnCurrentStep(plan: plan, history: history, drug: drug, now: now, calendar: calendar)
        if daysOnStep < current.minDays {
            return .failure(.escalationTooSoon(daysOnStep: daysOnStep, requiredDays: current.minDays))
        }
        return .success(())
    }

    private func checkInterval(dose: DoseLog, drug: Drug, history: [DoseLog], pen: PenInventory?) -> Result<Void, HardBlock> {
        if let last = history.filter({ $0.id != dose.id && $0.takenAt < dose.takenAt }).max(by: { $0.takenAt < $1.takenAt }) {
            let hours = Int(dose.takenAt.timeIntervalSince(last.takenAt) / 3600)
            if hours < drug.minHoursBetweenDoses {
                return .failure(.minIntervalViolation(hoursSinceLast: hours, requiredHours: drug.minHoursBetweenDoses))
            }
        }
        if let pen, let expiry = pen.inUseExpiry, dose.takenAt > expiry {
            return .failure(.penInUseExpired(expiry: expiry))
        }
        return .success(())
    }

    /// Days since the current step started: the plan's recorded start, else the first logged dose at that level.
    public static func daysOnCurrentStep(plan: GLP1Plan, history: [DoseLog], drug: Drug, now: Date, calendar: Calendar = .setmioDefault) -> Int {
        guard let current = plan.currentStep else { return 0 }
        let today = DayKey(now, calendar: calendar)
        if let started = current.startedOn { return max(0, today.daysSince(started, calendar: calendar)) }
        let atLevel = history.filter { abs($0.doseMg - current.doseMg) <= 0.011 }.map(\.takenAt)
        guard let first = atLevel.min() else { return 0 }
        return max(0, today.daysSince(DayKey(first, calendar: calendar), calendar: calendar))
    }

    /// Builds a label-default plan starting at a given ladder step.
    public func buildPlan(for drug: Drug, medicationID: SetmioCore.ID<Medication>, startingStepIndex: Int = 0, weekday: Int = 1, reminderHour: Int = 9, startDay: DayKey? = nil) -> GLP1Plan {
        let start = max(0, min(startingStepIndex, drug.steps.count - 1))
        var steps = drug.steps[start...].map { GLP1PlanStep(doseMg: $0, minDays: drug.escalationMinIntervalDays) }
        if !steps.isEmpty { steps[0].startedOn = startDay }
        return GLP1Plan(medicationID: medicationID, drug: drug.id, labelVersion: table.version, steps: steps, currentStepIndex: 0, injectionWeekday: weekday, reminderHour: reminderHour)
    }

    /// Next scheduled dose: last dose + dosing interval, else the next occurrence of the plan's weekday.
    public func nextDue(plan: GLP1Plan, history: [DoseLog], now: Date, calendar: Calendar = .setmioDefault) -> Date? {
        guard let drug = table.drug(plan.drug) else { return nil }
        if let last = history.max(by: { $0.takenAt < $1.takenAt }) {
            return calendar.date(byAdding: .day, value: drug.dosingIntervalDays, to: last.takenAt)
        }
        var components = DateComponents()
        components.weekday = plan.injectionWeekday
        components.hour = plan.reminderHour
        components.minute = 0
        return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
    }

    /// Fixed label text for a missed dose (no computed catch-up doses).
    public func missedDoseGuidance(drug: Drug, lastDose: Date?, now: Date) -> MissedDoseGuidance {
        guard let lastDose else { return .contactPrescriber(messageZH: "没有注射记录，请按处方开始并与医生确认") }
        let hoursSinceDue = now.timeIntervalSince(lastDose) / 3600 - Double(drug.dosingIntervalDays * 24)
        if hoursSinceDue <= 0 { return .notMissed }
        if hoursSinceDue <= Double(drug.missedDoseWindowHours) {
            return .takeNow(messageZH: "错过的剂量在 \(drug.missedDoseWindowHours / 24) 天内可以补打，之后按原计划；不要补打双倍剂量")
        }
        return .skipAndResume(messageZH: "已超过说明书补打窗口（\(drug.missedDoseWindowHours) 小时），请跳过这一针，按原定日期打下一针；连续漏针请联系医生")
    }
}

public enum MissedDoseGuidance: Sendable, Equatable {
    case notMissed
    case takeNow(messageZH: String)
    case skipAndResume(messageZH: String)
    case contactPrescriber(messageZH: String)
}

// MARK: - Decision support (always framed "discuss with your doctor")

public struct Advice: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case escalate(toMg: Milligrams)
        case hold(reason: String)
        case maintenance
        case taper
        case seekCareNow(reason: String)
    }

    public enum Framing: String, Sendable { case discussWithDoctor }

    public var kind: Kind
    public var rationaleZH: [String]
    /// Cannot be anything else: the app never instructs, it prepares a conversation with the prescriber.
    public let framing: Framing = .discussWithDoctor

    public init(kind: Kind, rationaleZH: [String]) {
        self.kind = kind
        self.rationaleZH = rationaleZH
    }
}

public struct GLP1DecisionInputs: Sendable {
    public var plan: GLP1Plan
    public var medication: Medication
    public var drug: Drug
    public var doses: [DoseLog]
    public var sideEffects: [SideEffectLog]
    /// Trended weight change in percent of body weight per week (negative = losing).
    public var weightTrendPercentPerWeek: Double?
    public var goalReached: Bool
    /// True when the user explicitly asked for a stop-plan assessment.
    public var requestedStopAssessment: Bool
    public var now: Date

    public init(plan: GLP1Plan, medication: Medication, drug: Drug, doses: [DoseLog], sideEffects: [SideEffectLog], weightTrendPercentPerWeek: Double?, goalReached: Bool, requestedStopAssessment: Bool = false, now: Date) {
        self.plan = plan
        self.medication = medication
        self.drug = drug
        self.doses = doses
        self.sideEffects = sideEffects
        self.weightTrendPercentPerWeek = weightTrendPercentPerWeek
        self.goalReached = goalReached
        self.requestedStopAssessment = requestedStopAssessment
        self.now = now
    }
}

public struct GLP1DecisionConfig: Sendable, Equatable {
    public var severeWindowDays = 7
    public var moderateWindowDays = 14
    public var adherenceWindowDays = 28
    public var minAdherence = 0.75
    /// Losing faster than this (percent of body weight per week) → hold and protect lean mass.
    public var tooFastPercentPerWeek = 1.0
    /// Losing slower than this on a tolerated step → discuss escalation.
    public var slowResponsePercentPerWeek = 0.25

    public init() {}
}

public struct GLP1DecisionSupport: Sendable {
    public let validator: GLP1PlanValidator
    public let config: GLP1DecisionConfig

    public init(validator: GLP1PlanValidator, config: GLP1DecisionConfig = GLP1DecisionConfig()) {
        self.validator = validator
        self.config = config
    }

    public func advise(_ i: GLP1DecisionInputs, calendar: Calendar = .setmioDefault) -> Result<Advice, HardBlock> {
        if i.medication.form.isVial || i.medication.isUnverifiedSource {
            return .failure(.vialVolumeMathUnsupported)
        }
        let today = DayKey(i.now, calendar: calendar)

        // 1. Safety first.
        let severeSince = today.adding(days: -config.severeWindowDays, calendar: calendar)
        if let severe = i.sideEffects.first(where: { $0.severity >= 3 && $0.day >= severeSince }) {
            return .success(Advice(kind: .seekCareNow(reason: "近 7 天出现重度\(severe.kind.nameZH)"),
                                   rationaleZH: ["说明书要求重度胃肠道反应、脱水或持续腹痛时停药并就医", "请立即联系医生"]))
        }
        let moderateSince = today.adding(days: -config.moderateWindowDays, calendar: calendar)
        if let moderate = i.sideEffects.first(where: { $0.severity >= 2 && $0.day >= moderateSince }) {
            return .success(Advice(kind: .hold(reason: "近 14 天有中度\(moderate.kind.nameZH)"),
                                   rationaleZH: ["中度副作用期间不建议加量，可与医生讨论维持当前档位或推迟 4 周再评估"]))
        }

        // 2. Adherence.
        let adherenceSince = calendar.date(byAdding: .day, value: -config.adherenceWindowDays, to: i.now) ?? i.now
        let expected = max(1, config.adherenceWindowDays / max(i.drug.dosingIntervalDays, 1))
        let taken = i.doses.filter { $0.takenAt >= adherenceSince && $0.takenAt <= i.now }.count
        let adherence = Double(taken) / Double(expected)
        if adherence < config.minAdherence {
            return .success(Advice(kind: .hold(reason: "近 4 周依从率 \(Int((adherence * 100).rounded()))%"),
                                   rationaleZH: ["漏针较多时无法判断当前档位的效果，先稳定按周注射，再评估是否加量"]))
        }

        // 3. Goal reached → maintenance conversation.
        if i.requestedStopAssessment {
            return .success(Advice(kind: .taper, rationaleZH: [
                "停药后一年内体重平均回升约减重量的 2/3（SURMOUNT-4、STEP 1 延长期）",
                "降档维持（如替尔泊肽 5 mg）比停药更能保持减重（SURMOUNT-MAINTAIN）",
                "减停表必须由医生给出；App 只执行并监测反弹",
            ]))
        }
        if i.goalReached {
            return .success(Advice(kind: .maintenance, rationaleZH: [
                "已达目标体重：ADA 2026 建议达标后继续用药，维持剂量不必是最大剂量",
                "与医生选择：继续当前档位 / 降档维持 / 逐步减停，App 负责执行与反弹监测",
            ]))
        }

        // 4. Rate of loss and step timing.
        guard let current = i.plan.currentStep else { return .failure(.unknownDrug) }
        let daysOnStep = GLP1PlanValidator.daysOnCurrentStep(plan: i.plan, history: i.doses, drug: i.drug, now: i.now, calendar: calendar)
        guard let trend = i.weightTrendPercentPerWeek else {
            return .success(Advice(kind: .hold(reason: "缺少体重趋势数据"), rationaleZH: ["至少 2 周的晨起称重后才能评估当前档位是否足够"]))
        }
        if trend <= -config.tooFastPercentPerWeek {
            return .success(Advice(kind: .hold(reason: "减重速度 \(String(format: "%.1f", -trend))%/周，快于 1%/周"),
                                   rationaleZH: ["过快减重会增加瘦体重与骨量流失，中国药学会草案建议暂停加量并复查体成分", "确保蛋白质目标与每周 ≥3 次力量训练"]))
        }
        guard let next = i.plan.nextStep else {
            return .success(Advice(kind: .hold(reason: "已在最高档位"), rationaleZH: ["已达说明书最大剂量或方案终点，按当前档位维持"]))
        }
        if trend > -config.slowResponsePercentPerWeek {
            if daysOnStep < current.minDays {
                return .failure(.escalationTooSoon(daysOnStep: daysOnStep, requiredDays: current.minDays))
            }
            return .success(Advice(kind: .escalate(toMg: next.doseMg), rationaleZH: [
                "当前档位已满 \(daysOnStep) 天，副作用轻微或无",
                "近期减重速度低于 0.25%/周（4–8 周不足 1%），可与医生讨论按阶梯加到 \(HardBlock.fmt(next.doseMg)) mg",
            ]))
        }
        return .success(Advice(kind: .hold(reason: "当前档位有效"), rationaleZH: ["减重速度在 0.25–1%/周的健康区间内，维持当前档位即可"]))
    }
}
