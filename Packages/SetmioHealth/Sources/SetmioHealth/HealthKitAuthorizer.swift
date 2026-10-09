#if canImport(HealthKit)
import Foundation
import HealthKit
import SetmioCore

/// Stateless wrapper around `HKHealthStore` authorization. HealthKit never reveals whether *read* access was
/// granted (denied reads just return nothing), so callers use `requestStatus` only to decide whether to show
/// the system sheet again.
public struct HealthKitAuthorizer: Sendable {
    // HKHealthStore is documented as thread-safe; see 方案.md §7.5 "并发模型".
    nonisolated(unsafe) let store: HKHealthStore

    public init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    public static var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    public func requestAuthorization(read: Set<HKObjectType>, share: Set<HKSampleType>) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthSourceError.healthDataUnavailable }
        try await store.requestAuthorization(toShare: share, read: read)
    }

    /// Convenience over the kind-based sets used by `HealthSampleSource`.
    public func requestAuthorization(readKinds: Set<HealthMetricKind>, shareKinds: Set<HealthMetricKind>) async throws {
        try await requestAuthorization(read: HealthTypes.readTypes(for: readKinds), share: HealthTypes.shareTypes(for: shareKinds))
    }

    /// Whether the system sheet would be shown for these types (`.shouldRequest`) or has been handled.
    public func requestStatus(read: Set<HKObjectType>, share: Set<HKSampleType>) async throws -> HKAuthorizationRequestStatus {
        try await store.statusForAuthorizationRequest(toShare: share, read: read)
    }

    /// Share status is the only one HealthKit reports per type.
    public func shareStatus(for type: HKObjectType) -> HKAuthorizationStatus {
        store.authorizationStatus(for: type)
    }
}
#endif
