// Foundation-only tests: run on Linux and macOS (`swift test --package-path Packages/SetmioData`).
import Foundation
import Testing
import SetmioCore
@testable import SetmioData

@Suite("JSONBlob 信封与枚举映射")
struct JSONBlobTests {
    @Test("信封带 schemaVersion，payload 原样往返")
    func envelopeRoundTrip() throws {
        let days = [
            ProgramDay(nameZH: "推", prescriptions: [
                ExercisePrescription(exerciseID: ID(), sets: 4, repRange: 6...10, progression: .doubleProgression),
                ExercisePrescription(exerciseID: ID(), sets: 3, repRange: 8...12, progression: .rtsPercent(targetPercentOfE1RM: 0.75), restPolicyOverrideSeconds: 120),
            ]),
        ]
        let data = try JSONBlob.encode(days)
        #expect(JSONBlob.schemaVersion(of: data) == JSONBlob.currentSchemaVersion)
        #expect(try JSONBlob.decode([ProgramDay].self, from: data) == days)

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["payload"] != nil)
    }

    @Test("带关联值的枚举（DosageForm / ProteinStandard / ProgressionDecision）往返")
    func payloadEnumsRoundTrip() throws {
        let forms: [DosageForm] = [.penFixedDose, .penMultiDose(inUseDays: 30), .tablet, .vial]
        for form in forms {
            #expect(try JSONBlob.decode(DosageForm.self, from: JSONBlob.encode(form)) == form)
        }
        let standards: [ProteinStandard] = [.usAdvisory, .chinaDraft, .perKgLeanMass(gPerKg: 2.2), .fixedGrams(110)]
        for standard in standards {
            #expect(try JSONBlob.decode(ProteinStandard.self, from: JSONBlob.encode(standard)) == standard)
        }
        let decisions: [ProgressionDecision] = [.hold(reason: "首次训练"), .increaseLoad(by: 2.5), .addSet, .deload(.e1rmDrop)]
        for decision in decisions {
            #expect(try JSONBlob.decode(ProgressionDecision.self, from: JSONBlob.encode(decision)) == decision)
        }
    }

    @Test("Settings（枚举键字典）、SleepWindow（Date）与 Readiness 分量往返")
    func coreStructsRoundTrip() throws {
        var settings = Settings.default
        settings.defaultRestSeconds = [.compound: 150, .isolation: 75]
        settings.readinessWeights = ReadinessWeights(hrv: 0.4, hrvAcute: 0.1, rhr: 0.1, sleep: 0.2, load: 0.1, subjective: 0.1)
        #expect(try JSONBlob.decode(Settings.self, from: JSONBlob.encode(settings)) == settings)

        let start = Date(timeIntervalSince1970: 1_791_000_000.123456)
        let window = SleepWindow(start: start, end: start.addingTimeInterval(7 * 3600), asleepMinutes: 400, deepMinutes: 60, remMinutes: 90, coreMinutes: 250, awakeMinutes: 20)
        #expect(try JSONBlob.decodeOptional(SleepWindow.self, from: JSONBlob.encodeOptional(window)) == window)
        #expect(try JSONBlob.decodeOptional(SleepWindow.self, from: nil) == nil)
        #expect(try JSONBlob.encodeOptional(Optional<SleepWindow>.none) == nil)

        let components = [ReadinessComponent(kind: .hrv, z: -1.2, subScore: -1.2, weight: 0.35), ReadinessComponent(kind: .sleep, z: nil, subScore: -0.3, weight: 0.2)]
        #expect(try JSONBlob.decode([ReadinessComponent].self, from: JSONBlob.encode(components)) == components)
        let flags: [ReadinessFlag] = [.recoveryDayOverride, .lowConfidence]
        #expect(try JSONBlob.decode([ReadinessFlag].self, from: JSONBlob.encode(flags)) == flags)
    }

    @Test("损坏的 blob 抛 decodingFailed 而不是静默回退")
    func corruptBlobThrows() {
        let garbage = Data("not json".utf8)
        #expect(JSONBlob.schemaVersion(of: garbage) == nil)
        #expect(throws: SetmioDataError.self) {
            _ = try JSONBlob.decode([ProgramDay].self, from: garbage)
        }
        let bareArray = Data("[]".utf8)   // valid JSON but no envelope
        #expect(throws: SetmioDataError.self) {
            _ = try JSONBlob.decode([ProgramDay].self, from: bareArray)
        }
    }

    @Test("未知枚举 rawValue 抛 corruptRecord")
    func unknownRawValueThrows() throws {
        #expect(try RawMap.decode("watch", as: SessionOrigin.self, entity: "LoggedSessionEntity", field: "originRaw") == .watch)
        #expect(try RawMap.decodeOptional(nil, as: InjectionSite.self, entity: "DoseLogEntity", field: "siteRaw") == nil)
        #expect(throws: SetmioDataError.corruptRecord(entity: "MedicationEntity", field: "drugRaw", detail: "未知枚举值 ozempic")) {
            _ = try RawMap.decode("ozempic", as: DrugID.self, entity: "MedicationEntity", field: "drugRaw")
        }
    }

    @Test("ReconcileOutcome 可比较")
    func reconcileOutcomeEquality() {
        let id = ID<LoggedSession>()
        #expect(ReconcileOutcome.linkedToSession(id) == .linkedToSession(id))
        #expect(ReconcileOutcome.linkedToSession(id) != .createdPlaceholder(id))
        #expect(ReconcileOutcome.alreadyKnown == .alreadyKnown)
    }
}
