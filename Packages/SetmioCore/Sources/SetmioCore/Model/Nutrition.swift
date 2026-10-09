import Foundation

public struct NutritionFacts: Sendable, Codable, Equatable, Hashable {
    public var kcal: Kilocalories
    public var protein: Grams
    public var carbs: Grams
    public var fat: Grams
    public var fiber: Grams

    public init(kcal: Kilocalories, protein: Grams = 0, carbs: Grams = 0, fat: Grams = 0, fiber: Grams = 0) {
        self.kcal = kcal
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
    }

    public static let zero = NutritionFacts(kcal: 0)

    public static func + (lhs: NutritionFacts, rhs: NutritionFacts) -> NutritionFacts {
        NutritionFacts(kcal: lhs.kcal + rhs.kcal, protein: lhs.protein + rhs.protein, carbs: lhs.carbs + rhs.carbs, fat: lhs.fat + rhs.fat, fiber: lhs.fiber + rhs.fiber)
    }

    public func scaled(by factor: Double) -> NutritionFacts {
        NutritionFacts(kcal: kcal * factor, protein: protein * factor, carbs: carbs * factor, fat: fat * factor, fiber: fiber * factor)
    }
}

public enum FoodItemSource: String, Sendable, Codable, Hashable {
    case manual, photoLLM, textLLM, barcode, labelOCR, database
}

public enum MealType: String, Sendable, Codable, Hashable, CaseIterable {
    case breakfast, lunch, dinner, snack

    public var nameZH: String {
        switch self {
        case .breakfast: "早餐"
        case .lunch: "午餐"
        case .dinner: "晚餐"
        case .snack: "加餐"
        }
    }
}

public struct FoodItem: Identifiable, Sendable, Codable, Equatable, Hashable {
    public var id: SetmioCore.ID<FoodItem>
    public var nameZH: String
    public var nameEN: String?
    public var portionGrams: Grams
    /// Human label such as "1碗" or "1份".
    public var portionLabel: String?
    public var facts: NutritionFacts
    /// Uncertainty band from photo estimation; nil for exact entries.
    public var kcalLow: Kilocalories?
    public var kcalHigh: Kilocalories?
    public var confidence: Double?
    public var source: FoodItemSource
    /// Original model estimate before the user corrected it (for per-user bias learning).
    public var originalKcalEstimate: Kilocalories?

    public init(
        id: SetmioCore.ID<FoodItem> = SetmioCore.ID(),
        nameZH: String,
        nameEN: String? = nil,
        portionGrams: Grams,
        portionLabel: String? = nil,
        facts: NutritionFacts,
        kcalLow: Kilocalories? = nil,
        kcalHigh: Kilocalories? = nil,
        confidence: Double? = nil,
        source: FoodItemSource,
        originalKcalEstimate: Kilocalories? = nil
    ) {
        self.id = id
        self.nameZH = nameZH
        self.nameEN = nameEN
        self.portionGrams = portionGrams
        self.portionLabel = portionLabel
        self.facts = facts
        self.kcalLow = kcalLow
        self.kcalHigh = kcalHigh
        self.confidence = confidence
        self.source = source
        self.originalKcalEstimate = originalKcalEstimate
    }
}

public struct FoodEntry: Identifiable, Sendable, Codable, Equatable, Hashable {
    public var id: SetmioCore.ID<FoodEntry>
    public var day: DayKey
    public var time: Date
    public var meal: MealType
    public var items: [FoodItem]
    public var photoLocalPath: String?
    /// True once the user has confirmed portions (photo entries start unconfirmed).
    public var confirmed: Bool

    public init(id: SetmioCore.ID<FoodEntry> = SetmioCore.ID(), day: DayKey, time: Date, meal: MealType, items: [FoodItem], photoLocalPath: String? = nil, confirmed: Bool = true) {
        self.id = id
        self.day = day
        self.time = time
        self.meal = meal
        self.items = items
        self.photoLocalPath = photoLocalPath
        self.confirmed = confirmed
    }

    public var totals: NutritionFacts {
        items.reduce(.zero) { $0 + $1.facts }
    }
}

/// Adaptive expenditure state (Kalman-style filter over intake and trended weight).
public struct EnergyEstimate: Sendable, Codable, Equatable, Hashable {
    public var day: DayKey
    public var tdee: Kilocalories
    /// Variance of the TDEE estimate (kcal²).
    public var variance: Double
    public var trendWeight: Kilograms
    public var trendSlopePerWeek: Kilograms
    /// 0–1: share of days in the window with intake logged.
    public var loggingCompleteness: Double
    public var windowDays: Int

    public init(day: DayKey, tdee: Kilocalories, variance: Double, trendWeight: Kilograms, trendSlopePerWeek: Kilograms = 0, loggingCompleteness: Double = 0, windowDays: Int = 14) {
        self.day = day
        self.tdee = tdee
        self.variance = variance
        self.trendWeight = trendWeight
        self.trendSlopePerWeek = trendSlopePerWeek
        self.loggingCompleteness = loggingCompleteness
        self.windowDays = windowDays
    }
}
