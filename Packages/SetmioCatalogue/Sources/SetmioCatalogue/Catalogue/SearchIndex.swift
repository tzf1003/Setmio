import Foundation

/// Search keys for one catalogue, built once when it is created. Every name is folded (case and diacritics removed),
/// so a keystroke costs one linear pass of substring checks. Nothing is normalised or compiled per call.
///
/// Display order is precomputed per language: folded name, then catalogue position. Positions follow numeric id,
/// so the order is total and stable.
struct SearchIndex: Sendable {
    /// Folded name per language, parallel to the catalogue's `all`.
    private let folded: [[CatalogueLanguage: String]]
    /// Catalogue positions in display order, per language.
    private let order: [CatalogueLanguage: [Int]]

    /// `exercises` must already be sorted by numeric id.
    init(exercises: [CatalogueExercise]) {
        let folded = exercises.map { exercise in
            Dictionary(uniqueKeysWithValues: CatalogueLanguage.allCases.map { language in
                (language, Self.fold(exercise.localizedName(for: language)))
            })
        }
        var order: [CatalogueLanguage: [Int]] = [:]
        for language in CatalogueLanguage.allCases {
            order[language] = exercises.indices.sorted { lhs, rhs in
                let left = folded[lhs][language] ?? ""
                let right = folded[rhs][language] ?? ""
                return left == right ? lhs < rhs : left < right
            }
        }
        self.folded = folded
        self.order = order
    }

    /// Positions in `exercises` that match `query`, in display order. The two flags let a facet count leave out its own selection.
    func matches(
        in exercises: [CatalogueExercise],
        query: ExerciseQuery,
        applyingTargets: Bool = true,
        applyingEquipment: Bool = true
    ) -> [Int] {
        let tokens = Self.tokens(query.text)
        var result: [Int] = []
        for position in order[query.language] ?? [] {
            let exercise = exercises[position]
            guard Self.allows(exercise.bodyPart, query.bodyParts),
                  !applyingTargets || Self.allows(exercise.target, query.targets),
                  !applyingEquipment || Self.allows(exercise.equipment, query.equipment),
                  Self.matchesText(tokens, names: folded[position], language: query.language)
            else { continue }
            result.append(position)
        }
        return result
    }

    /// Lowercase, with diacritics removed, so "Café" and "cafe" compare equal. Applied to names and to queries alike.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Whitespace-separated words of the query. Every word must appear somewhere, so "incline press" finds
    /// "dumbbell incline press" whatever the word order.
    private static func tokens(_ text: String?) -> [String] {
        guard let text else { return [] }
        return fold(text).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Each word has to appear in the English name or in the name for the query's language.
    private static func matchesText(_ tokens: [String], names: [CatalogueLanguage: String]?, language: CatalogueLanguage) -> Bool {
        guard !tokens.isEmpty else { return true }
        let english = names?[.en] ?? ""
        let localized = names?[language] ?? ""
        return tokens.allSatisfy { english.contains($0) || localized.contains($0) }
    }

    /// An empty selection allows everything. Otherwise the value must be one of the selected ones; a nil value never is.
    private static func allows<Value: Hashable>(_ value: Value?, _ selected: Set<Value>) -> Bool {
        selected.isEmpty || value.map { selected.contains($0) } == true
    }
}
