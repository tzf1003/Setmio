import Foundation
import Testing
@testable import SetmioCatalogue

@Suite("Vocabulary")
struct VocabularyTests {
    @Test("closed vocabularies have the upstream sizes: 11 body parts, 19 targets, 33 equipment")
    func sizes() {
        #expect(BodyPartCategory.allCases.count == 11)
        #expect(TargetMuscle.allCases.count == 19)
        #expect(EquipmentKind.allCases.count == 33)
    }

    @Test("raw values are the upstream strings")
    func rawValues() {
        #expect(BodyPartCategory.upperLegs.rawValue == "upper legs")
        #expect(TargetMuscle.cardiovascularSystem.rawValue == "cardiovascular system")
        #expect(EquipmentKind.ezBarbell.rawValue == "ez barbell")
    }

    @Test("every case has a distinct Chinese label within its enum")
    func chineseLabels() {
        #expect(Set(BodyPartCategory.allCases.map(\.nameZH)).count == BodyPartCategory.allCases.count)
        #expect(Set(TargetMuscle.allCases.map(\.nameZH)).count == TargetMuscle.allCases.count)
        #expect(Set(EquipmentKind.allCases.map(\.nameZH)).count == EquipmentKind.allCases.count)
        #expect(Set(MuscleRegion.allCases.map(\.nameZH)).count == MuscleRegion.allCases.count)
        #expect(BodyPartCategory.allCases.allSatisfy { !$0.nameZH.isEmpty })
        #expect(TargetMuscle.allCases.allSatisfy { !$0.nameZH.isEmpty })
        #expect(EquipmentKind.allCases.allSatisfy { !$0.nameZH.isEmpty })
    }

    @Test("words that are not listed are nil, not a crash")
    func unknownWords() {
        #expect(BodyPartCategory(rawValue: "moon") == nil)
        #expect(TargetMuscle(rawValue: "") == nil)
        #expect(EquipmentKind(rawValue: "laser") == nil)
    }
}
