import Testing
@testable import SetmioCatalogue

@Suite("SecondaryMuscleNames")
struct SecondaryMuscleNamesTests {
    @Test("every secondary-muscle word in the bundled library has a Chinese name")
    func coversBundledData() throws {
        let catalogue = try ExerciseCatalogue.loadBundled()
        let words = Set(catalogue.all.flatMap(\.secondaryMuscles))
        let missing = words.filter { SecondaryMuscleNames.zh[$0] == nil }.sorted()
        #expect(missing.isEmpty, "add Chinese names for: \(missing)")
    }

    @Test("unknown words and other languages fall back to the upstream word")
    func fallback() {
        #expect(SecondaryMuscleNames.name("triceps", in: .zh) == "肱三头肌")
        #expect(SecondaryMuscleNames.name("triceps", in: .en) == "triceps")
        #expect(SecondaryMuscleNames.name("made-up muscle", in: .zh) == "made-up muscle")
    }
}
