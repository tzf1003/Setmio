import Foundation

/// One exercise from the bundled library. The English fields are what `Codable` reads and writes, using the upstream
/// JSON keys. `translations` is not part of that JSON: `ExerciseCatalogue` fills it in from the per-language tables.
public struct CatalogueExercise: Identifiable, Sendable, Codable, Hashable {
    /// Upstream's permanent id, zero-padded below 10,000 ("0025"). Compare and store it as a string.
    public var id: String
    /// Lowercase with equipment first ("barbell bench press"). Capitalisation for display is the UI's job.
    public var nameEN: String
    /// nil when the upstream word is not in `BodyPartCategory`. The data tests reject such a word.
    public var bodyPart: BodyPartCategory?
    public var equipment: EquipmentKind?
    public var target: TargetMuscle?
    public var secondaryMuscles: [String]
    /// Upstream's free-form category ("strength", "calisthenics"). Kept as a string: no UI needs it as a closed set yet.
    public var category: String
    public var descriptionEN: String
    public var instructionsEN: [String]
    public var source: TextSource
    /// Translated text by language. Empty means every localised accessor returns the English text.
    public var translations: [CatalogueLanguage: CatalogueTranslation]

    public init(
        id: String,
        nameEN: String,
        bodyPart: BodyPartCategory? = nil,
        equipment: EquipmentKind? = nil,
        target: TargetMuscle? = nil,
        secondaryMuscles: [String] = [],
        category: String = "",
        descriptionEN: String = "",
        instructionsEN: [String] = [],
        source: TextSource = .unknown,
        translations: [CatalogueLanguage: CatalogueTranslation] = [:]
    ) {
        self.id = id
        self.nameEN = nameEN
        self.bodyPart = bodyPart
        self.equipment = equipment
        self.target = target
        self.secondaryMuscles = secondaryMuscles
        self.category = category
        self.descriptionEN = descriptionEN
        self.instructionsEN = instructionsEN
        self.source = source
        self.translations = translations
    }

    /// The name in `language`, or the English name when that language has none.
    public func localizedName(for language: CatalogueLanguage) -> String {
        translations[language]?.name ?? nameEN
    }

    /// The description in `language`, or the English description when that language has none.
    public func localizedDescription(for language: CatalogueLanguage) -> String {
        translations[language]?.description ?? descriptionEN
    }

    /// The steps in `language`, or the English steps when that language has none. Steps are never mixed across languages.
    public func localizedInstructions(for language: CatalogueLanguage) -> [String] {
        translations[language]?.instructions ?? instructionsEN
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case nameEN = "name"
        case bodyPart
        case equipment
        case target
        case secondaryMuscles
        case category
        case descriptionEN = "description"
        case instructionsEN = "instructions"
        case source = "textSource"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        nameEN = try container.decode(String.self, forKey: .nameEN)
        // An unknown upstream word becomes nil rather than failing the whole library. The data tests catch it instead.
        bodyPart = try container.decodeIfPresent(String.self, forKey: .bodyPart).flatMap(BodyPartCategory.init(rawValue:))
        equipment = try container.decodeIfPresent(String.self, forKey: .equipment).flatMap(EquipmentKind.init(rawValue:))
        target = try container.decodeIfPresent(String.self, forKey: .target).flatMap(TargetMuscle.init(rawValue:))
        secondaryMuscles = try container.decodeIfPresent([String].self, forKey: .secondaryMuscles) ?? []
        category = try container.decode(String.self, forKey: .category)
        descriptionEN = try container.decode(String.self, forKey: .descriptionEN)
        instructionsEN = try container.decode([String].self, forKey: .instructionsEN)
        source = try container.decodeIfPresent(String.self, forKey: .source).flatMap(TextSource.init(rawValue:)) ?? .unknown
        translations = [:]
    }
}

/// Translated text for one exercise, keyed by upstream id in each language's table. Each field is optional, so a
/// translation can cover just the name, or just the name and steps, and anything missing falls back to English.
public struct CatalogueTranslation: Sendable, Codable, Hashable {
    public var name: String?
    public var description: String?
    public var instructions: [String]?

    public init(name: String? = nil, description: String? = nil, instructions: [String]? = nil) {
        self.name = name
        self.description = description
        self.instructions = instructions
    }
}
