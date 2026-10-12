import Foundation

/// Errors from building or loading a catalogue. Data problems surface here, at load time, not during a search.
public enum CatalogueError: Error, Sendable, Equatable {
    case resourceMissing(String)
    case duplicateExerciseID(String)
    case translationForUnknownExercise(language: CatalogueLanguage, id: String)
}

/// The offline exercise library. Immutable once built: exercises are sorted by numeric id, translations are attached,
/// and search keys are precomputed.
public struct ExerciseCatalogue: Sendable {
    /// Every exercise, sorted by numeric id, with translations attached.
    public let all: [CatalogueExercise]
    private let positions: [String: Int]
    private let searchIndex: SearchIndex

    public var count: Int { all.count }

    /// Builds a catalogue from in-memory parts. Throws on a duplicate id or on a translation for an id that does not exist.
    /// English is the source text, so a `.en` table is ignored.
    public init(
        exercises: [CatalogueExercise],
        translations: [CatalogueLanguage: [String: CatalogueTranslation]] = [:]
    ) throws {
        var ordered = exercises.sorted { Self.isOrderedBefore($0.id, $1.id) }
        var positions: [String: Int] = [:]
        for (position, exercise) in ordered.enumerated() {
            guard positions.updateValue(position, forKey: exercise.id) == nil else {
                throw CatalogueError.duplicateExerciseID(exercise.id)
            }
        }
        for language in CatalogueLanguage.allCases where language != .en {
            guard let table = translations[language] else { continue }
            for id in table.keys.sorted(by: Self.isOrderedBefore) {
                guard let position = positions[id] else {
                    throw CatalogueError.translationForUnknownExercise(language: language, id: id)
                }
                ordered[position].translations[language] = table[id]
            }
        }
        all = ordered
        self.positions = positions
        searchIndex = SearchIndex(exercises: ordered)
    }

    /// Loads `exercises.json` and every non-English translation table bundled under `Resources/`.
    public static func loadBundled() throws -> ExerciseCatalogue {
        let exercises: [CatalogueExercise] = try CatalogueResources.decode("exercises")
        var translations: [CatalogueLanguage: [String: CatalogueTranslation]] = [:]
        for language in CatalogueLanguage.allCases {
            guard let resource = language.translationResource else { continue }
            translations[language] = try CatalogueResources.decode(resource)
        }
        return try ExerciseCatalogue(exercises: exercises, translations: translations)
    }

    public func exercise(id: String) -> CatalogueExercise? {
        positions[id].map { all[$0] }
    }

    /// Exercises matching `query`, ordered by the name in `query.language`, then by id.
    public func search(_ query: ExerciseQuery) -> [CatalogueExercise] {
        searchIndex.matches(in: all, query: query).map { all[$0] }
    }

    /// Counts per target and per equipment, for drawing facet chips beside the results.
    ///
    /// Each facet ignores its own selection, so choosing "chest" does not zero out "back". The target counts are for
    /// the query with the target filter removed, and the equipment counts are for the query with the equipment filter
    /// removed. Every case appears, with 0 when nothing matches, so the UI can show disabled chips without a fallback.
    public func facetCounts(
        for query: ExerciseQuery
    ) -> (targets: [TargetMuscle: Int], equipment: [EquipmentKind: Int]) {
        var targets = Dictionary(uniqueKeysWithValues: TargetMuscle.allCases.map { ($0, 0) })
        for position in searchIndex.matches(in: all, query: query, applyingTargets: false) {
            if let target = all[position].target { targets[target, default: 0] += 1 }
        }
        var equipment = Dictionary(uniqueKeysWithValues: EquipmentKind.allCases.map { ($0, 0) })
        for position in searchIndex.matches(in: all, query: query, applyingEquipment: false) {
            if let kind = all[position].equipment { equipment[kind, default: 0] += 1 }
        }
        return (targets, equipment)
    }

    /// Numeric order for upstream ids ("0025" < "0100" < "10187"). The string breaks ties, so the order is total.
    private static func isOrderedBefore(_ lhs: String, _ rhs: String) -> Bool {
        (Int(lhs) ?? .max, lhs) < (Int(rhs) ?? .max, rhs)
    }
}
