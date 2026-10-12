import Foundation
import Testing
@testable import SetmioCatalogue

/// The display-order key the search promises: folded name, then id. Mirrors `SearchIndex`, written out independently.
private func foldedName(_ exercise: CatalogueExercise, _ language: CatalogueLanguage) -> String {
    exercise.localizedName(for: language).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
}

@Suite("Search")
struct SearchTests {
    @Test("finds an exercise by its Chinese name")
    func chineseName() throws {
        let results = try Bundled.catalogue().search(ExerciseQuery(text: "杠铃卧推", language: .zh))
        #expect(results.contains { $0.id == "0025" })
        #expect(results.allSatisfy { $0.localizedName(for: .zh).contains("杠铃卧推") })
    }

    @Test("finds an exercise by its English name, whatever the query language")
    func englishName() throws {
        let catalogue = try Bundled.catalogue()
        #expect(catalogue.search(ExerciseQuery(text: "barbell bench press")).contains { $0.id == "0025" })
        #expect(catalogue.search(ExerciseQuery(text: "Barbell Bench Press", language: .zh)).contains { $0.id == "0025" })
    }

    @Test("every word of the query must match, in any order")
    func everyWordMatches() throws {
        let catalogue = try ExerciseCatalogue(exercises: [
            makeExercise("0001", "dumbbell incline press"),
            makeExercise("0002", "barbell bench press"),
            makeExercise("0003", "dumbbell curl"),
        ])
        #expect(catalogue.search(ExerciseQuery(text: "press incline")).map(\.id) == ["0001"])
        #expect(catalogue.search(ExerciseQuery(text: "press")).map(\.id) == ["0002", "0001"])
        #expect(catalogue.search(ExerciseQuery(text: "  dumbbell  ")).map(\.id) == ["0003", "0001"])
    }

    @Test("matching ignores case and diacritics")
    func foldsCaseAndDiacritics() throws {
        let catalogue = try ExerciseCatalogue(exercises: [makeExercise("0001", "Crème brûlée row")])
        #expect(catalogue.search(ExerciseQuery(text: "CREME")).count == 1)
        #expect(catalogue.search(ExerciseQuery(text: "brulee")).count == 1)
        #expect(catalogue.search(ExerciseQuery(text: "crème")).count == 1)
        #expect(catalogue.search(ExerciseQuery(text: "crepe")).isEmpty)
    }

    @Test("a Chinese name is searched in the Chinese query language, and only there")
    func languageScopesLocalisedNames() throws {
        let catalogue = try ExerciseCatalogue(exercises: [makeExercise("0001", "bench row", zh: "哑铃划船")])
        #expect(catalogue.search(ExerciseQuery(text: "哑铃", language: .zh)).count == 1)
        #expect(catalogue.search(ExerciseQuery(text: "哑铃", language: .en)).isEmpty)
    }

    @Test("body-part filter matches the raw upstream count")
    func bodyPartFilter() throws {
        let catalogue = try Bundled.catalogue()
        let expected = try RawData.rows.get().filter { $0.bodyPart == "chest" }.map(\.id)
        let results = catalogue.search(ExerciseQuery(bodyParts: [.chest]))
        #expect(results.count == expected.count)
        #expect(Set(results.map(\.id)) == Set(expected))
        #expect(results.allSatisfy { $0.bodyPart == .chest })
    }

    @Test("equipment filter is OR-ed within the facet")
    func equipmentFilter() throws {
        let catalogue = try Bundled.catalogue()
        let expected = try RawData.rows.get().filter { ["dumbbell", "kettlebell"].contains($0.equipment) }.map(\.id)
        let results = catalogue.search(ExerciseQuery(equipment: [.dumbbell, .kettlebell]))
        #expect(results.count == expected.count)
        #expect(Set(results.map(\.id)) == Set(expected))
    }

    @Test("combined filters agree with a brute-force filter over the whole library")
    func combinedFilters() throws {
        let catalogue = try Bundled.catalogue()
        let query = ExerciseQuery(
            text: "squat",
            bodyParts: [.upperLegs, .lowerLegs],
            equipment: [.barbell, .dumbbell, .bodyWeight],
            language: .zh
        )
        let matching = catalogue.all.enumerated().filter { _, exercise in
            guard let bodyPart = exercise.bodyPart, let equipment = exercise.equipment else { return false }
            let named = exercise.nameEN.contains("squat") || exercise.localizedName(for: .zh).contains("squat")
            return query.bodyParts.contains(bodyPart) && query.equipment.contains(equipment) && named
        }
        let expected = matching.sorted { lhs, rhs in
            let left = foldedName(lhs.element, .zh), right = foldedName(rhs.element, .zh)
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element.id)
        #expect(!expected.isEmpty)
        #expect(catalogue.search(query).map(\.id) == expected)
    }

    @Test("results follow the query language's order: folded name, then id", arguments: CatalogueLanguage.allCases)
    func ordering(language: CatalogueLanguage) throws {
        let results = try Bundled.catalogue().search(ExerciseQuery(language: language))
        #expect(results.count == 5632)
        let keys = results.map { (foldedName($0, language), Int($0.id) ?? -1) }
        #expect(zip(keys, keys.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test("an empty or blank query returns the whole library")
    func emptyQuery() throws {
        let catalogue = try Bundled.catalogue()
        #expect(catalogue.search(ExerciseQuery()).count == 5632)
        #expect(catalogue.search(ExerciseQuery(text: "   ")).count == 5632)
    }

    @Test("lookup by id returns the exercise from the list")
    func lookup() throws {
        let catalogue = try Bundled.catalogue()
        #expect(catalogue.exercise(id: "0025")?.nameEN == "barbell bench press")
        #expect(catalogue.exercise(id: "9999999") == nil)
    }
}

@Suite("Facet counts")
struct FacetTests {
    private let library = [
        makeExercise("0001", "bench press", bodyPart: .chest, equipment: .barbell, target: .pectorals),
        makeExercise("0002", "dumbbell press", bodyPart: .chest, equipment: .dumbbell, target: .pectorals),
        makeExercise("0003", "lat pulldown", bodyPart: .back, equipment: .barbell, target: .lats),
    ]

    @Test("with no facet selected, the counts sum to the number of results")
    func sumsToResults() throws {
        let catalogue = try Bundled.catalogue()
        let query = ExerciseQuery(bodyParts: [.upperLegs])
        let total = catalogue.search(query).count
        let counts = catalogue.facetCounts(for: query)
        #expect(total > 0)
        #expect(counts.targets.values.reduce(0, +) == total)
        #expect(counts.equipment.values.reduce(0, +) == total)
    }

    @Test("each facet ignores its own selection and applies the others")
    func ownFacetIgnored() throws {
        let catalogue = try Bundled.catalogue()
        let query = ExerciseQuery(text: "press", bodyParts: [.chest, .shoulders], targets: [.pectorals], equipment: [.barbell, .dumbbell])
        let counts = catalogue.facetCounts(for: query)

        var withoutTargets = query
        withoutTargets.targets = []
        #expect(counts.targets.values.reduce(0, +) == catalogue.search(withoutTargets).count)

        var withoutEquipment = query
        withoutEquipment.equipment = []
        #expect(counts.equipment.values.reduce(0, +) == catalogue.search(withoutEquipment).count)

        // A single selected target's count equals the results for that selection.
        #expect(counts.targets[.pectorals, default: -1] == catalogue.search(query).count)
    }

    @Test("every target and equipment appears, with zeros for absent values")
    func zerosIncluded() throws {
        let catalogue = try ExerciseCatalogue(exercises: library)
        let counts = catalogue.facetCounts(for: ExerciseQuery(bodyParts: [.chest]))
        #expect(counts.targets.count == TargetMuscle.allCases.count)
        #expect(counts.equipment.count == EquipmentKind.allCases.count)
        #expect(counts.targets[.pectorals] == 2)
        #expect(counts.targets[.lats] == 0)
        #expect(counts.equipment[.barbell] == 1)
        #expect(counts.equipment[.dumbbell] == 1)
    }

    @Test("choosing one target keeps the other target counts, as the chips need")
    func disjunctiveTargets() throws {
        let catalogue = try ExerciseCatalogue(exercises: library)
        let counts = catalogue.facetCounts(for: ExerciseQuery(targets: [.lats]))
        #expect(counts.targets[.pectorals] == 2)
        #expect(counts.targets[.lats] == 1)
        #expect(counts.equipment[.barbell] == 1)
        #expect(counts.equipment[.dumbbell] == 0)
    }
}
