import Foundation

// MARK: - Label table (versioned data, shipped as JSON)

public enum DrugID: String, Codable, Sendable, Hashable, CaseIterable {
    case semaglutide
    case tirzepatide
    case mazdutide
    case liraglutide
    case ecnoglutide
    case oralSemaglutide
    case orforglipron
}

public enum DosageForm: Sendable, Codable, Equatable, Hashable {
    /// Single-dose prefilled pen.
    case penFixedDose
    /// Multi-dose pen; `inUseDays` is the in-use shelf life after first use.
    case penMultiDose(inUseDays: Int)
    /// Oral tablet.
    case tablet
    /// Vial / unverified source: logging allowed, no plan templates, no volume math.
    case vial

    public var isVial: Bool {
        if case .vial = self { return true }
        return false
    }
}

public struct Drug: Identifiable, Sendable, Codable, Equatable, Hashable {
    public var id: DrugID
    public var nameZH: String
    public var brandsZH: [String]
    public var market: String
    public var forms: [DosageForm]
    /// Ladder of label doses in mg, ascending.
    public var steps: [Milligrams]
    public var startMg: Milligrams
    public var maxMg: Milligrams
    public var maintenanceMg: [Milligrams]
    /// Days between doses (7 weekly, 1 daily).
    public var dosingIntervalDays: Int
    /// Minimum days on a step before moving to the next.
    public var escalationMinIntervalDays: Int
    /// Hard minimum hours between two doses (never log closer than this).
    public var minHoursBetweenDoses: Int
    /// Label missed-dose window: take the missed dose if within this many hours, else skip.
    public var missedDoseWindowHours: Int
    public var notesZH: String?

    public init(
        id: DrugID,
        nameZH: String,
        brandsZH: [String],
        market: String,
        forms: [DosageForm],
        steps: [Milligrams],
        startMg: Milligrams,
        maxMg: Milligrams,
        maintenanceMg: [Milligrams],
        dosingIntervalDays: Int,
        escalationMinIntervalDays: Int,
        minHoursBetweenDoses: Int,
        missedDoseWindowHours: Int,
        notesZH: String? = nil
    ) {
        self.id = id
        self.nameZH = nameZH
        self.brandsZH = brandsZH
        self.market = market
        self.forms = forms
        self.steps = steps
        self.startMg = startMg
        self.maxMg = maxMg
        self.maintenanceMg = maintenanceMg
        self.dosingIntervalDays = dosingIntervalDays
        self.escalationMinIntervalDays = escalationMinIntervalDays
        self.minHoursBetweenDoses = minHoursBetweenDoses
        self.missedDoseWindowHours = missedDoseWindowHours
        self.notesZH = notesZH
    }

    public func stepIndex(of dose: Milligrams, tolerance: Double = 0.011) -> Int? {
        steps.firstIndex { abs($0 - dose) <= tolerance }
    }
}

public struct GLP1LabelTable: Sendable, Codable, Equatable {
    public var version: Int
    public var market: String
    public var updatedAt: String
    public var drugs: [Drug]

    public init(version: Int, market: String, updatedAt: String, drugs: [Drug]) {
        self.version = version
        self.market = market
        self.updatedAt = updatedAt
        self.drugs = drugs
    }

    public func drug(_ id: DrugID) -> Drug? {
        drugs.first { $0.id == id }
    }
}

// MARK: - User records

public struct Medication: Identifiable, Sendable, Codable, Equatable, Hashable {
    public var id: SetmioCore.ID<Medication>
    public var drug: DrugID
    public var form: DosageForm
    public var startedOn: DayKey
    public var isActive: Bool
    /// True when the product did not come through a verified pharmacy channel (海淘 / 代购 / 瓶装).
    public var isUnverifiedSource: Bool
    /// iOS 26 HealthKit medication concept identifier, if linked.
    public var hkMedicationConceptID: String?

    public init(id: SetmioCore.ID<Medication> = SetmioCore.ID(), drug: DrugID, form: DosageForm, startedOn: DayKey, isActive: Bool = true, isUnverifiedSource: Bool = false, hkMedicationConceptID: String? = nil) {
        self.id = id
        self.drug = drug
        self.form = form
        self.startedOn = startedOn
        self.isActive = isActive
        self.isUnverifiedSource = isUnverifiedSource
        self.hkMedicationConceptID = hkMedicationConceptID
    }
}

public enum InjectionSite: String, Codable, Sendable, CaseIterable, Hashable {
    case abdomenLeft, abdomenRight, thighLeft, thighRight, upperArmLeft, upperArmRight

    public var nameZH: String {
        switch self {
        case .abdomenLeft: "腹部左侧"
        case .abdomenRight: "腹部右侧"
        case .thighLeft: "左大腿"
        case .thighRight: "右大腿"
        case .upperArmLeft: "左上臂"
        case .upperArmRight: "右上臂"
        }
    }

    /// Simple rotation: the site after `last` in the list; starts at abdomen left.
    public static func next(after last: InjectionSite?) -> InjectionSite {
        guard let last, let index = allCases.firstIndex(of: last) else { return .abdomenLeft }
        return allCases[(index + 1) % allCases.count]
    }
}

public struct DoseLog: Identifiable, Sendable, Codable, Equatable, Hashable {
    public var id: SetmioCore.ID<DoseLog>
    public var medicationID: SetmioCore.ID<Medication>
    public var takenAt: Date
    public var doseMg: Milligrams
    public var site: InjectionSite?
    public var penID: SetmioCore.ID<PenInventory>?
    public var wasMissedMakeup: Bool
    public var hkDoseEventUUID: UUID?
    public var note: String?

    public init(id: SetmioCore.ID<DoseLog> = SetmioCore.ID(), medicationID: SetmioCore.ID<Medication>, takenAt: Date, doseMg: Milligrams, site: InjectionSite? = nil, penID: SetmioCore.ID<PenInventory>? = nil, wasMissedMakeup: Bool = false, hkDoseEventUUID: UUID? = nil, note: String? = nil) {
        self.id = id
        self.medicationID = medicationID
        self.takenAt = takenAt
        self.doseMg = doseMg
        self.site = site
        self.penID = penID
        self.wasMissedMakeup = wasMissedMakeup
        self.hkDoseEventUUID = hkDoseEventUUID
        self.note = note
    }
}

public struct PenInventory: Identifiable, Sendable, Codable, Equatable, Hashable {
    public var id: SetmioCore.ID<PenInventory>
    public var medicationID: SetmioCore.ID<Medication>
    public var strengthMg: Milligrams
    public var dosesRemaining: Int?
    public var firstUsedAt: Date?
    public var inUseExpiry: Date?
    public var lotExpiry: Date?
    public var coldChainBreach: Bool

    public init(id: SetmioCore.ID<PenInventory> = SetmioCore.ID(), medicationID: SetmioCore.ID<Medication>, strengthMg: Milligrams, dosesRemaining: Int? = nil, firstUsedAt: Date? = nil, inUseExpiry: Date? = nil, lotExpiry: Date? = nil, coldChainBreach: Bool = false) {
        self.id = id
        self.medicationID = medicationID
        self.strengthMg = strengthMg
        self.dosesRemaining = dosesRemaining
        self.firstUsedAt = firstUsedAt
        self.inUseExpiry = inUseExpiry
        self.lotExpiry = lotExpiry
        self.coldChainBreach = coldChainBreach
    }
}

public struct SideEffectLog: Identifiable, Sendable, Codable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case nausea, vomiting, diarrhea, constipation, injectionSiteReaction, fatigue, abdominalPain, other

        public var nameZH: String {
            switch self {
            case .nausea: "恶心"
            case .vomiting: "呕吐"
            case .diarrhea: "腹泻"
            case .constipation: "便秘"
            case .injectionSiteReaction: "注射部位反应"
            case .fatigue: "乏力"
            case .abdominalPain: "腹痛"
            case .other: "其他"
            }
        }
    }

    public var id: SetmioCore.ID<SideEffectLog>
    public var medicationID: SetmioCore.ID<Medication>
    public var day: DayKey
    public var kind: Kind
    /// 0 none, 1 mild, 2 moderate, 3 severe.
    public var severity: Int
    public var note: String?

    public init(id: SetmioCore.ID<SideEffectLog> = SetmioCore.ID(), medicationID: SetmioCore.ID<Medication>, day: DayKey, kind: Kind, severity: Int, note: String? = nil) {
        self.id = id
        self.medicationID = medicationID
        self.day = day
        self.kind = kind
        self.severity = severity
        self.note = note
    }
}

public struct GLP1PlanStep: Sendable, Codable, Equatable, Hashable {
    public var doseMg: Milligrams
    /// Minimum days on this step before the next one is allowed.
    public var minDays: Int
    public var startedOn: DayKey?

    public init(doseMg: Milligrams, minDays: Int, startedOn: DayKey? = nil) {
        self.doseMg = doseMg
        self.minDays = minDays
        self.startedOn = startedOn
    }
}

/// A prescriber-set (or label-default) titration plan the app executes and reminds about.
public struct GLP1Plan: Identifiable, Sendable, Codable, Equatable, Hashable {
    public var id: SetmioCore.ID<GLP1Plan>
    public var medicationID: SetmioCore.ID<Medication>
    public var drug: DrugID
    public var labelVersion: Int
    public var steps: [GLP1PlanStep]
    public var currentStepIndex: Int
    /// 1 = Sunday … 7 = Saturday (Foundation weekday numbering).
    public var injectionWeekday: Int
    public var reminderHour: Int
    /// Set when the prescriber confirmed a plan that departs from the label ladder.
    public var clinicianConfirmedOffLabel: Bool

    public init(
        id: SetmioCore.ID<GLP1Plan> = SetmioCore.ID(),
        medicationID: SetmioCore.ID<Medication>,
        drug: DrugID,
        labelVersion: Int,
        steps: [GLP1PlanStep],
        currentStepIndex: Int = 0,
        injectionWeekday: Int = 1,
        reminderHour: Int = 9,
        clinicianConfirmedOffLabel: Bool = false
    ) {
        self.id = id
        self.medicationID = medicationID
        self.drug = drug
        self.labelVersion = labelVersion
        self.steps = steps
        self.currentStepIndex = currentStepIndex
        self.injectionWeekday = injectionWeekday
        self.reminderHour = reminderHour
        self.clinicianConfirmedOffLabel = clinicianConfirmedOffLabel
    }

    public var currentStep: GLP1PlanStep? {
        steps.indices.contains(currentStepIndex) ? steps[currentStepIndex] : nil
    }

    public var nextStep: GLP1PlanStep? {
        steps.indices.contains(currentStepIndex + 1) ? steps[currentStepIndex + 1] : nil
    }
}
