import Foundation
@testable import SetmioCatalogue

/// The bundled library, decoded once per test run. Decoding takes a moment, so the tests share the result.
enum Bundled {
    static let result = Result { try ExerciseCatalogue.loadBundled() }

    static func catalogue() throws -> ExerciseCatalogue {
        try result.get()
    }
}

/// The upstream strings exactly as they appear in the bundled `exercises.json`, before any enum mapping.
struct RawRow: Decodable {
    let id: String
    let bodyPart: String
    let equipment: String
    let target: String
    let textSource: String
}

enum RawData {
    static let rows = Result { try JSONDecoder().decode([RawRow].self, from: CatalogueResources.data("exercises")) }
}

/// A small in-memory exercise, for tests that need exact control over names and facets.
func makeExercise(
    _ id: String,
    _ name: String,
    zh: String? = nil,
    bodyPart: BodyPartCategory? = .chest,
    equipment: EquipmentKind? = .barbell,
    target: TargetMuscle? = .pectorals
) -> CatalogueExercise {
    var translations: [CatalogueLanguage: CatalogueTranslation] = [:]
    if let zh {
        translations[.zh] = CatalogueTranslation(name: zh)
    }
    return CatalogueExercise(
        id: id,
        nameEN: name,
        bodyPart: bodyPart,
        equipment: equipment,
        target: target,
        category: "strength",
        descriptionEN: "Test exercise.",
        instructionsEN: ["Set up.", "Move."],
        source: .opengym,
        translations: translations
    )
}
