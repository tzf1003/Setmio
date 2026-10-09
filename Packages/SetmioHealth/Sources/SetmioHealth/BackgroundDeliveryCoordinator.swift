import Foundation
import Synchronization
import SetmioCore

/// Enables HealthKit background delivery for a set of kinds and keeps one observer per kind alive.
///
/// Observer callbacks arrive on an arbitrary HealthKit queue; each one spawns a task that imports the new
/// samples and then notifies `onImported`. The HealthKit completion handler is called from a `defer`, so it
/// runs exactly once whether the import succeeded, threw or was cancelled — HealthKit stops delivering
/// updates to apps that forget to call it.
///
/// Create this once at app launch (`SetmioApp.init`) and never deallocate it: background wake-ups have no UI.
public final class BackgroundDeliveryCoordinator: Sendable {
    private let source: any HealthSampleSource
    private let importer: HealthSampleImporter
    private let onImported: @Sendable (HealthMetricKind) async -> Void
    private let tokens = Mutex<[HealthMetricKind: ObservationToken]>([:])

    public init(
        source: any HealthSampleSource,
        importer: HealthSampleImporter,
        onImported: @escaping @Sendable (HealthMetricKind) async -> Void
    ) {
        self.source = source
        self.importer = importer
        self.onImported = onImported
    }

    /// Delivery cadence per kind: overnight vitals and body mass matter as soon as they land (the morning
    /// readiness score waits for them); activity totals and heart rate are high-volume and only feed load/TDEE.
    public static func frequency(for kind: HealthMetricKind) -> BackgroundFrequency {
        switch kind {
        case .hrvSDNN, .hrvRMSSD, .restingHeartRate, .sleep, .respiratoryRate, .wristTemperature,
             .bodyMass, .bodyFatPercentage, .leanBodyMass:
            .immediate
        case .steps, .activeEnergy, .basalEnergy, .heartRate, .workout, .workoutEffort:
            .hourly
        }
    }

    /// Enables background delivery and registers an observer for each kind. Kinds already observed are
    /// skipped, so calling this again is harmless. Returns the kinds whose background delivery could not be
    /// enabled (the observer is still registered for them so foreground updates keep working).
    @discardableResult
    public func start(kinds: [HealthMetricKind] = HealthMetricKind.mvp) async -> [HealthMetricKind: String] {
        var failures: [HealthMetricKind: String] = [:]
        for kind in kinds {
            let alreadyObserved = tokens.withLock { $0[kind] != nil }
            if alreadyObserved { continue }

            do {
                try await source.enableBackgroundDelivery(for: kind, frequency: Self.frequency(for: kind))
            } catch {
                failures[kind] = String(describing: error)
            }

            let importer = self.importer
            let onImported = self.onImported
            let token = source.observe(kind) { completion in
                Task {
                    defer { completion() }
                    _ = try? await importer.importNew(kind)
                    await onImported(kind)
                }
            }
            tokens.withLock { $0[kind] = token }
        }
        return failures
    }

    public var observedKinds: [HealthMetricKind] {
        tokens.withLock { Array($0.keys) }.sorted { $0.rawValue < $1.rawValue }
    }

    /// Cancels every observer. Background delivery itself stays enabled in HealthKit until the app disables it.
    public func stop() {
        let all = tokens.withLock { stored -> [ObservationToken] in
            let values = Array(stored.values)
            stored.removeAll()
            return values
        }
        for token in all { token.cancel() }
    }
}
