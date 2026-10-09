import Foundation
import SetmioCore

// MARK: - Value types (Foundation-only so the app's medication module can consume them on every platform)

/// A medication the user added to the Health app (iOS 26 Medications API).
public struct UserMedicationSummary: Sendable, Codable, Hashable, Identifiable {
    /// Stable HealthKit medication concept identifier; stored in `Medication.hkMedicationConceptID`.
    public var conceptIdentifier: String
    public var displayName: String
    public var isArchived: Bool
    /// Free-text strength as shown in Health ("2.5 mg"), when available.
    public var strengthDescription: String?

    public var id: String { conceptIdentifier }

    public init(conceptIdentifier: String, displayName: String, isArchived: Bool = false, strengthDescription: String? = nil) {
        self.conceptIdentifier = conceptIdentifier
        self.displayName = displayName
        self.isArchived = isArchived
        self.strengthDescription = strengthDescription
    }
}

/// One logged dose event from Health. Mirrors `HKMedicationDoseEvent`; `status` keeps the raw log-status value.
public struct MedicationDoseEventSummary: Sendable, Codable, Hashable, Identifiable {
    public enum Status: Int, Sendable, Codable, Hashable {
        case unknown = 0, taken = 1, skipped = 2, snoozed = 3 // VERIFY: HKMedicationDoseEvent.LogStatus raw values
    }

    public var hkUUID: UUID
    public var conceptIdentifier: String
    public var scheduledDate: Date?
    public var logDate: Date
    public var status: Status
    public var doseQuantity: Double?
    public var unit: String?

    public var id: UUID { hkUUID }

    public init(hkUUID: UUID, conceptIdentifier: String, scheduledDate: Date? = nil, logDate: Date, status: Status, doseQuantity: Double? = nil, unit: String? = nil) {
        self.hkUUID = hkUUID
        self.conceptIdentifier = conceptIdentifier
        self.scheduledDate = scheduledDate
        self.logDate = logDate
        self.status = status
        self.doseQuantity = doseQuantity
        self.unit = unit
    }

    /// Maps a taken dose onto a Setmio `DoseLog` for a medication the user linked by concept identifier.
    public func doseLog(for medication: Medication, doseMg: Milligrams) -> DoseLog? {
        guard status == .taken else { return nil }
        return DoseLog(medicationID: medication.id, takenAt: logDate, doseMg: doseMg, hkDoseEventUUID: hkUUID)
    }
}

// MARK: - iOS 26 reader (skeleton)

#if canImport(HealthKit) && os(iOS)
import HealthKit

/// Reads the user's medication list and dose events from Health (iOS 26 Medications API).
///
/// Skeleton: the query descriptors are stubbed to return `[]` until the exact API surface is verified on a
/// Mac against WWDC25 "Meet the HealthKit Medications API". Linking a `Medication` to a Health concept and
/// de-duplicating by `hkDoseEventUUID` already works end to end once these return real data.
@available(iOS 26, *)
public struct MedicationReader: Sendable {
    nonisolated(unsafe) let store: HKHealthStore

    public init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    /// Medications use per-object read authorization: the system sheet lets the user pick which ones to share.
    public func requestAccess() async throws {
        // VERIFY: try await store.requestPerObjectReadAuthorization(for: HKObjectType.userAnnotatedMedicationType(), predicate: nil)
        // VERIFY: dose events additionally need `requestAuthorization(toShare: [], read: [HKObjectType.medicationDoseEventType()])`
    }

    public func userMedications() async throws -> [UserMedicationSummary] {
        // VERIFY: let descriptor = HKUserAnnotatedMedicationQueryDescriptor(predicate: nil, limit: nil)
        //         let results = try await descriptor.result(for: store)  // [HKUserAnnotatedMedication]
        //         map: $0.medication.identifier (concept id), $0.nickname ?? $0.medication.generalConcept.displayText, $0.isArchived
        return []
    }

    public func doseEvents(since: Date) async throws -> [MedicationDoseEventSummary] {
        // VERIFY: let predicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: [.strictStartDate])
        //         let descriptor = HKSampleQueryDescriptor(predicates: [.medicationDoseEvent(predicate)], sortDescriptors: [SortDescriptor(\.startDate)])
        //         let events = try await descriptor.result(for: store)  // [HKMedicationDoseEvent]
        //         map: $0.uuid, $0.medicationConceptIdentifier, $0.scheduledDate, $0.logOrigin/logStatus, $0.doseQuantity?.doubleValue(for:)
        _ = since
        return []
    }
}
#endif
