import Foundation
import SetmioCore

// Wire contract with `proxy/` (方案.md §7.8). Every key is camelCase and mirrors `proxy/src/schemas/*.ts` exactly;
// the zod schemas are the source of truth and `ContractDecodingTests` pins both sides to the same fixture.

// MARK: - Shared

public struct ModelInfo: Sendable, Codable, Equatable, Hashable {
    public var provider: String
    public var id: String

    public init(provider: String, id: String) {
        self.provider = provider
        self.id = id
    }
}

/// Proxy error body: `{ error: { code, message, retryable, retryAfterSeconds? } }`.
public struct ErrorEnvelope: Sendable, Codable, Equatable {
    public struct Body: Sendable, Codable, Equatable {
        public var code: String
        public var message: String
        public var retryable: Bool
        public var retryAfterSeconds: Double?

        public init(code: String, message: String, retryable: Bool, retryAfterSeconds: Double? = nil) {
            self.code = code
            self.message = message
            self.retryable = retryable
            self.retryAfterSeconds = retryAfterSeconds
        }
    }

    public var error: Body

    public init(error: Body) {
        self.error = error
    }

    /// Error codes the proxy emits (`proxy/src/errors.ts`). Unknown codes map to `upstream`.
    public enum Code: String, Sendable {
        case unauthorized
        case rateLimited = "rate_limited"
        case invalidRequest = "invalid_request"
        case imageTooLarge = "image_too_large"
        case upstreamRefusal = "upstream_refusal"
        case upstreamError = "upstream_error"
        case backendUnavailable = "backend_unavailable"
    }

    public var llmError: LLMError {
        switch Code(rawValue: error.code) {
        case .unauthorized: .unauthorized
        case .rateLimited: .rateLimited(retryAfter: error.retryAfterSeconds)
        case .invalidRequest: .invalidRequest(error.message)
        case .imageTooLarge: .imageTooLarge
        case .upstreamRefusal: .upstreamRefusal
        case .upstreamError: .upstream(retryable: error.retryable)
        case .backendUnavailable: .providerUnavailable
        case nil: .upstream(retryable: error.retryable)
        }
    }
}

// MARK: - Devices

public struct DeviceRegisterRequest: Sendable, Codable, Equatable {
    public var inviteCode: String
    public var deviceName: String
    public var platform: String

    public init(inviteCode: String, deviceName: String, platform: String = "ios") {
        self.inviteCode = inviteCode
        self.deviceName = deviceName
        self.platform = platform
    }
}

public struct DeviceRegisterResponse: Sendable, Codable, Equatable {
    /// Shown once; the proxy only keeps its SHA-256.
    public var deviceToken: String
    public var deviceId: String

    public init(deviceToken: String, deviceId: String) {
        self.deviceToken = deviceToken
        self.deviceId = deviceId
    }
}

// MARK: - Food

public struct FoodHints: Sendable, Codable, Equatable {
    public var mealType: MealType?
    public var locale: String
    public var userNote: String?
    public var recentFoods: [String]?

    public init(mealType: MealType? = nil, locale: String = "zh-CN", userNote: String? = nil, recentFoods: [String]? = nil) {
        self.mealType = mealType
        self.locale = locale
        self.userNote = userNote
        self.recentFoods = recentFoods
    }
}

public struct FoodRecognizeRequest: Sendable, Codable, Equatable {
    public var imageJpegBase64: String
    public var imageWidth: Int
    public var imageHeight: Int
    public var hints: FoodHints

    public init(imageJpegBase64: String, imageWidth: Int, imageHeight: Int, hints: FoodHints = FoodHints()) {
        self.imageJpegBase64 = imageJpegBase64
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.hints = hints
    }

    /// Convenience over the `ImagePreprocessor` output `(data, width, height)`.
    public init(jpeg data: Data, width: Int, height: Int, hints: FoodHints = FoodHints()) {
        self.init(imageJpegBase64: data.base64EncodedString(), imageWidth: width, imageHeight: height, hints: hints)
    }
}

public struct FoodParseTextRequest: Sendable, Codable, Equatable {
    public var text: String
    public var locale: String
    public var hints: FoodHints?

    public init(text: String, locale: String = "zh-CN", hints: FoodHints? = nil) {
        self.text = text
        self.locale = locale
        self.hints = hints
    }
}

public struct FoodItemDTO: Sendable, Codable, Equatable {
    public struct Portion: Sendable, Codable, Equatable {
        public var amount: Double
        /// 碗 / 份 / 个 / 克 …
        public var unit: String
        public var gramsEstimate: Double

        public init(amount: Double, unit: String, gramsEstimate: Double) {
            self.amount = amount
            self.unit = unit
            self.gramsEstimate = gramsEstimate
        }
    }

    public struct KcalRange: Sendable, Codable, Equatable {
        public var low: Double
        public var best: Double
        public var high: Double

        public init(low: Double, best: Double, high: Double) {
            self.low = low
            self.best = best
            self.high = high
        }
    }

    public struct Macros: Sendable, Codable, Equatable {
        public var proteinG: Double
        public var carbsG: Double
        public var fatG: Double

        public init(proteinG: Double, carbsG: Double, fatG: Double) {
            self.proteinG = proteinG
            self.carbsG = carbsG
            self.fatG = fatG
        }
    }

    public var nameZH: String
    public var nameEN: String
    public var portion: Portion
    public var kcal: KcalRange
    public var macrosBest: Macros
    /// 0–1.
    public var confidence: Double
    /// True when the model wants the user to confirm (unknown cooking oil, hidden portion…).
    public var needsConfirmation: Bool

    public init(nameZH: String, nameEN: String, portion: Portion, kcal: KcalRange, macrosBest: Macros, confidence: Double, needsConfirmation: Bool) {
        self.nameZH = nameZH
        self.nameEN = nameEN
        self.portion = portion
        self.kcal = kcal
        self.macrosBest = macrosBest
        self.confidence = confidence
        self.needsConfirmation = needsConfirmation
    }
}

public struct FoodRecognitionResultDTO: Sendable, Codable, Equatable {
    public var items: [FoodItemDTO]
    public var overallConfidence: Double
    public var notesZH: String
    public var model: ModelInfo

    public init(items: [FoodItemDTO], overallConfidence: Double, notesZH: String, model: ModelInfo) {
        self.items = items
        self.overallConfidence = overallConfidence
        self.notesZH = notesZH
        self.model = model
    }
}

public extension FoodItemDTO {
    /// "1碗", "0.5份", "150克".
    var portionLabel: String {
        let amount = portion.amount
        let text = amount == amount.rounded() ? String(Int(amount)) : String(format: "%g", amount)
        return text + portion.unit
    }

    func toFoodItem(source: FoodItemSource) -> FoodItem {
        FoodItem(
            nameZH: nameZH,
            nameEN: nameEN.isEmpty ? nil : nameEN,
            portionGrams: portion.gramsEstimate,
            portionLabel: portionLabel,
            facts: NutritionFacts(kcal: kcal.best, protein: macrosBest.proteinG, carbs: macrosBest.carbsG, fat: macrosBest.fatG),
            kcalLow: kcal.low,
            kcalHigh: kcal.high,
            confidence: confidence,
            source: source,
            originalKcalEstimate: kcal.best
        )
    }
}

public extension FoodRecognitionResultDTO {
    /// Maps the wire result into Core `FoodItem`s. `source` is `.photoLLM` for `/food/recognize`
    /// and `.textLLM` for `/food/parse-text`; the best estimate is kept in `originalKcalEstimate`
    /// so later user corrections can feed per-user bias learning.
    func toFoodItems(source: FoodItemSource = .photoLLM) -> [FoodItem] {
        items.map { $0.toFoodItem(source: source) }
    }

    /// Items the model flagged for confirmation.
    var itemsNeedingConfirmation: [FoodItemDTO] {
        items.filter(\.needsConfirmation)
    }
}

// MARK: - Coach

public struct ChatMessage: Sendable, Codable, Equatable {
    public enum Role: String, Sendable, Codable {
        case user, assistant
    }

    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// Aggregated numbers only — no identity, no raw HealthKit samples (§7.9).
public struct CoachContext: Sendable, Codable, Equatable {
    public var readinessScore: Int?
    public var weightTrendKgPerWeek: Double?
    public var tdee: Double?
    public var proteinTargetG: Double?
    public var last7DaysSessions: Int?
    /// e.g. "替尔泊肽 5 mg，第 5 周，近 4 周依从 100%，轻度恶心"
    public var glp1Summary: String?

    public init(readinessScore: Int? = nil, weightTrendKgPerWeek: Double? = nil, tdee: Double? = nil, proteinTargetG: Double? = nil, last7DaysSessions: Int? = nil, glp1Summary: String? = nil) {
        self.readinessScore = readinessScore
        self.weightTrendKgPerWeek = weightTrendKgPerWeek
        self.tdee = tdee
        self.proteinTargetG = proteinTargetG
        self.last7DaysSessions = last7DaysSessions
        self.glp1Summary = glp1Summary
    }
}

public struct CoachChatRequest: Sendable, Codable, Equatable {
    /// At most 20 turns (40 messages); the client trims older history.
    public var messages: [ChatMessage]
    public var context: CoachContext
    public var locale: String

    public init(messages: [ChatMessage], context: CoachContext = CoachContext(), locale: String = "zh-CN") {
        self.messages = messages
        self.context = context
        self.locale = locale
    }
}

public struct CoachChatResponse: Sendable, Codable, Equatable {
    public var replyZH: String
    public var suggestions: [String]
    /// e.g. "medication_question", "rapid_weight_loss", "injury" — the UI shows a doctor reminder for these.
    public var safetyFlags: [String]

    public init(replyZH: String, suggestions: [String], safetyFlags: [String]) {
        self.replyZH = replyZH
        self.suggestions = suggestions
        self.safetyFlags = safetyFlags
    }
}

// MARK: - Weekly report

public struct MedicationSummaryDTO: Sendable, Codable, Equatable {
    public var adherencePct: Double
    public var sideEffectSummary: String

    public init(adherencePct: Double, sideEffectSummary: String) {
        self.adherencePct = adherencePct
        self.sideEffectSummary = sideEffectSummary
    }
}

public struct WeeklyReportRequest: Sendable, Codable, Equatable {
    /// `yyyy-MM-dd` of the week's first day.
    public var weekStart: String
    /// e.g. ["avgReadiness": 68, "avgHRV": 52, "avgSleepMinutes": 430, "weightTrendKg": -0.4]
    public var metrics: [String: Double]
    /// e.g. ["sessions": 3, "totalVolumeKg": 12_400, "avgEffort": 7]
    public var training: [String: Double]
    /// e.g. ["avgKcal": 1850, "avgProteinG": 128, "tdee": 2350, "loggedDays": 6]
    public var nutrition: [String: Double]
    public var medication: MedicationSummaryDTO

    public init(weekStart: String, metrics: [String: Double], training: [String: Double], nutrition: [String: Double], medication: MedicationSummaryDTO) {
        self.weekStart = weekStart
        self.metrics = metrics
        self.training = training
        self.nutrition = nutrition
        self.medication = medication
    }

    public init(weekStart: DayKey, metrics: [String: Double], training: [String: Double], nutrition: [String: Double], medication: MedicationSummaryDTO) {
        self.init(weekStart: weekStart.description, metrics: metrics, training: training, nutrition: nutrition, medication: medication)
    }
}

public struct WeeklyReportResponse: Sendable, Codable, Equatable {
    public var titleZH: String
    public var summaryZH: String
    public var highlights: [String]
    public var concerns: [String]
    public var nextWeekFocus: [String]

    public init(titleZH: String, summaryZH: String, highlights: [String], concerns: [String], nextWeekFocus: [String]) {
        self.titleZH = titleZH
        self.summaryZH = summaryZH
        self.highlights = highlights
        self.concerns = concerns
        self.nextWeekFocus = nextWeekFocus
    }
}

// MARK: - Routes

/// Proxy routes and their client timeouts (§7.8).
public enum ProxyRoute {
    public static let register = "/v1/devices/register"
    public static let foodRecognize = "/v1/food/recognize"
    public static let foodParseText = "/v1/food/parse-text"
    public static let coachChat = "/v1/coach/chat"
    public static let weeklyReport = "/v1/report/weekly"

    public static let defaultTimeout: TimeInterval = 30
    public static let foodRecognizeTimeout: TimeInterval = 60
    public static let weeklyReportTimeout: TimeInterval = 120
}

/// Codable helpers shared by the client and tests: ISO-8601 dates, stable key order for fixtures.
public enum AIJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
