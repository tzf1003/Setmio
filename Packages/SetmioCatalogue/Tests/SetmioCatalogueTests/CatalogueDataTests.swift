import Foundation
import Testing
@testable import SetmioCatalogue

@Suite("Bundled catalogue data")
struct CatalogueDataTests {
    @Test("loads exactly 5,632 exercises")
    func count() throws {
        let catalogue = try Bundled.catalogue()
        #expect(catalogue.count == 5632)
        #expect(catalogue.all.count == 5632)
    }

    @Test("ids are unique, numeric, and sorted numerically")
    func ids() throws {
        let ids = try Bundled.catalogue().all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        #expect(ids == ids.sorted { (Int($0) ?? 0, $0) < (Int($1) ?? 0, $1) })
    }

    @Test("every exercise has a name, a description and at least one step")
    func nonEmptyText() throws {
        let blank = try Bundled.catalogue().all.filter { exercise in
            exercise.nameEN.trimmingCharacters(in: .whitespaces).isEmpty
                || exercise.descriptionEN.trimmingCharacters(in: .whitespaces).isEmpty
                || exercise.instructionsEN.isEmpty
                || exercise.instructionsEN.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        }.map(\.id)
        #expect(blank.isEmpty, "exercises with blank text: \(blank)")
    }

    @Test("every upstream word maps to a known vocabulary case")
    func vocabularyCoverage() throws {
        let rows = try RawData.rows.get()
        let unknownBodyParts = Set(rows.map(\.bodyPart)).filter { BodyPartCategory(rawValue: $0) == nil }
        let unknownEquipment = Set(rows.map(\.equipment)).filter { EquipmentKind(rawValue: $0) == nil }
        let unknownTargets = Set(rows.map(\.target)).filter { TargetMuscle(rawValue: $0) == nil }
        #expect(unknownBodyParts.isEmpty, "add these bodyPart values to BodyPartCategory: \(unknownBodyParts.sorted())")
        #expect(unknownEquipment.isEmpty, "add these equipment values to EquipmentKind: \(unknownEquipment.sorted())")
        #expect(unknownTargets.isEmpty, "add these target values to TargetMuscle: \(unknownTargets.sorted())")
        #expect(Set(rows.map(\.textSource)).isSubset(of: ["exercisedb", "opengym"]))
    }

    @Test("decoded enums agree with the raw upstream strings")
    func decodingAgreesWithRawData() throws {
        let rows = Dictionary(uniqueKeysWithValues: try RawData.rows.get().map { ($0.id, $0) })
        let mismatches = try Bundled.catalogue().all.filter { exercise in
            guard let row = rows[exercise.id] else { return true }
            return exercise.bodyPart?.rawValue != row.bodyPart
                || exercise.equipment?.rawValue != row.equipment
                || exercise.target?.rawValue != row.target
                || exercise.source.rawValue != row.textSource
        }.map(\.id)
        #expect(mismatches.isEmpty, "decoded values differ from the JSON for: \(mismatches)")
    }

    @Test("the ExerciseDB-origin count matches NOTICE.md (1,324), and every entry has a known source")
    func sourceCounts() throws {
        let all = try Bundled.catalogue().all
        #expect(all.filter { $0.source == .exercisedb }.count == 1324)
        #expect(all.filter { $0.source == .unknown }.isEmpty)
    }

    @Test("the bundled JSON references no media files and no URLs")
    func noMediaReferences() throws {
        let text = String(decoding: try CatalogueResources.data("exercises"), as: UTF8.self)
            + String(decoding: try CatalogueResources.data("zh"), as: UTF8.self)
        let lowered = text.lowercased()
        for needle in ["media/", ".webp", ".mp4", ".gif", "http://", "https://", "gymvisual"] {
            #expect(!lowered.contains(needle), "bundled data contains \(needle)")
        }
    }

    @Test("every exercise has a Chinese name")
    func chineseNames() throws {
        let missing = try Bundled.catalogue().all.filter { $0.translations[.zh]?.name?.isEmpty != false }.map(\.id)
        #expect(missing.isEmpty, "no Chinese name for: \(missing)")
    }

    @Test("a missing Chinese field falls back to English")
    func zhFallback() throws {
        let catalogue = try Bundled.catalogue()

        // 1006 has a Chinese name upstream but no Chinese steps or description.
        let row = try #require(catalogue.exercise(id: "1006"))
        #expect(row.localizedName(for: .zh) == "弹力带后三角肌划船")
        #expect(row.localizedName(for: .en) == row.nameEN)
        #expect(row.localizedDescription(for: .zh) == row.descriptionEN)
        #expect(row.localizedInstructions(for: .zh) == row.instructionsEN)

        // 0025 has Chinese steps as well, but still no Chinese description.
        let press = try #require(catalogue.exercise(id: "0025"))
        #expect(press.localizedName(for: .zh) == "杠铃卧推")
        #expect(press.localizedInstructions(for: .zh).first == "平躺在长凳上，双脚平放在地上，背部紧贴长凳。")
        #expect(press.localizedInstructions(for: .zh) != press.instructionsEN)
        #expect(press.localizedDescription(for: .zh) == press.descriptionEN)
    }

    @Test("Codable round-trips the English fields and keeps translations out of the JSON")
    func roundTrip() throws {
        let catalogue = try Bundled.catalogue()
        let original = try #require(catalogue.exercise(id: "0025"))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CatalogueExercise.self, from: data)
        var expected = original
        expected.translations = [:]
        #expect(decoded == expected)
        #expect(!String(decoding: data, as: UTF8.self).contains("translations"))
    }

    @Test("an unlisted upstream word decodes to nil and an unknown text source to .unknown")
    func lenientDecoding() throws {
        let json = """
        {"id":"9001","name":"moon jump","bodyPart":"moon","equipment":"laser","target":"abs",
         "secondaryMuscles":[],"category":"cardio","description":"Test.","instructions":["Jump."],"textSource":"mystery"}
        """
        let exercise = try JSONDecoder().decode(CatalogueExercise.self, from: Data(json.utf8))
        #expect(exercise.bodyPart == nil)
        #expect(exercise.equipment == nil)
        #expect(exercise.target == .abs)
        #expect(exercise.source == .unknown)
    }

    @Test("building a catalogue rejects duplicate ids and translations for unknown ids")
    func rejectsBadInput() throws {
        #expect(throws: CatalogueError.duplicateExerciseID("0001")) {
            try ExerciseCatalogue(exercises: [makeExercise("0001", "first"), makeExercise("0001", "second")])
        }
        #expect(throws: CatalogueError.translationForUnknownExercise(language: .zh, id: "9999")) {
            try ExerciseCatalogue(
                exercises: [makeExercise("0001", "first")],
                translations: [.zh: ["9999": CatalogueTranslation(name: "未知")]]
            )
        }
    }
}
