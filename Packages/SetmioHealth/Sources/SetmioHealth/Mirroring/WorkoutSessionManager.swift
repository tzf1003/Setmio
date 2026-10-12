#if canImport(HealthKit) && os(watchOS)
import Foundation
import HealthKit
import Observation
import os
import SetmioCore

/// Heart-rate and builder diagnostics (subsystem com.tzf1003.setmio, category hr). Read in Console.app or `log stream`.
private let heartRateLog = Logger(subsystem: "com.tzf1003.setmio", category: "hr")

/// Drives the watch workout session, the live builder and the mirroring channel to the iPhone.
///
/// Isolation: `@MainActor` so SwiftUI can observe it directly. HealthKit delegate callbacks arrive on
/// HealthKit's queue and are declared `nonisolated`, hopping back with `Task { @MainActor in … }`.
///
/// Flow (方案.md §7.5/7.7): `start(plan:)` → `HKWorkoutSession` + `startMirroringToCompanionDevice()` (the
/// system launches the iOS app in the background and calls its `workoutSessionMirroringStartHandler`) →
/// every logged set is first journaled locally by the watch app, then `send(.setLogged)` → `end(effort:)`
/// finishes the builder and writes the effort score.
@MainActor
@Observable
public final class WorkoutSessionManager: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    public enum State: Sendable, Equatable {
        case idle, preparing, running, paused, ending, ended
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var heartRate: BeatsPerMinute?
    public private(set) var elapsed: TimeInterval = 0
    public private(set) var mirroringConnected = false
    public private(set) var plan: PlannedSession?
    public private(set) var lastWorkout: HKWorkout?
    /// Messages from the phone (acks, plan updates, rest-timer commands).
    public var onRemoteMessage: (@MainActor (MirroringMessage) -> Void)?
    /// Called with a short Chinese description when a non-fatal send fails (the watch app falls back to WatchConnectivity).
    public var onSendFailure: (@MainActor (String) -> Void)?

    // MARK: Heart-rate diagnostics (read by the temporary readout in ActiveSessionView; reset by `start(plan:)`)

    /// Builder callbacks that carried a heart-rate sample since the start.
    public private(set) var heartRateDeliveries = 0
    /// Most recent HealthKit or mirroring error since the start, as "步骤：说明".
    public private(set) var lastErrorText: String?
    /// Whether the live data source the builder was given lists heart rate in `typesToCollect` (nil before the first start).
    /// If this is false the builder never collects heart rate, whatever the sensor does.
    public private(set) var heartRateInCollectedTypes: Bool?
    /// Whether the system would still ask for heart-rate read access (`.shouldRequest`) or has already handled the
    /// request (`.unnecessary`, granted or denied: HealthKit does not say which). nil before the first start.
    public private(set) var heartRateReadRequestStatus: HKAuthorizationRequestStatus?
    /// Whether this app can see ANY heart-rate sample from the last 24 hours. The watch records heart rate all day, so
    /// "no" means heart-rate READ access was not granted (HealthKit never says so directly). nil before the first check.
    public private(set) var canReadRecentHeartRate: Bool?
    /// The most recent heart rate the builder reports through `statistics(for:)`, polled once a second and independent
    /// of the delegate callbacks. If this has a value while `heartRateDeliveries` is 0, the delegate is the problem.
    public private(set) var polledHeartRate: BeatsPerMinute?
    /// Write (share) status for heart rate. HealthKit does not report read status: a denied read looks like no data.
    public var heartRateShareStatus: HKAuthorizationStatus {
        store.authorizationStatus(for: HKQuantityType(.heartRate))
    }

    @ObservationIgnored private let store: HKHealthStore
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private var sequencer = MirroringSequencer()
    @ObservationIgnored private var elapsedTicker: Task<Void, Never>?

    public init(store: HKHealthStore = HKHealthStore(), appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0") {
        self.store = store
        self.appVersion = appVersion
        super.init()
    }

    /// When the underlying `HKWorkoutSession` started (also after `recoverIfNeeded`).
    public var sessionStartDate: Date? { session?.startDate }

    public var isActive: Bool {
        switch state {
        case .preparing, .running, .paused, .ending: true
        case .idle, .ended, .failed: false
        }
    }

    // MARK: Lifecycle

    public func start(plan: PlannedSession, planVersion: Int? = nil) async throws {
        guard !isActive else { return }
        self.plan = plan
        state = .preparing
        heartRateDeliveries = 0
        lastErrorText = nil

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor

        await ensureHeartRateAuthorization()

        let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
        let builder = session.associatedWorkoutBuilder()
        let dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
        builder.dataSource = dataSource
        heartRateInCollectedTypes = dataSource.typesToCollect.contains(HKQuantityType(.heartRate))
        heartRateLog.info("start: HR write status \(self.heartRateShareStatus.rawValue, privacy: .public), HR in typesToCollect \(self.heartRateInCollectedTypes ?? false, privacy: .public)")
        session.delegate = self
        builder.delegate = self
        self.session = session
        self.builder = builder

        do {
            try await session.startMirroringToCompanionDevice()
            mirroringConnected = true
        } catch {
            // Mirroring is best-effort: the session still records on the watch and WatchConnectivity takes over.
            mirroringConnected = false
            recordError("startMirroringToCompanionDevice", error.localizedDescription)
            onSendFailure?("无法镜像到 iPhone：\(error.localizedDescription)")
        }

        let startDate = Date()
        session.startActivity(with: startDate)
        try await tracked("beginCollection") { try await builder.beginCollection(at: startDate) }
        startElapsedTicker()

        if mirroringConnected {
            try? await send(.hello(watchAppVersion: appVersion, planVersion: planVersion))
        }
    }

    public func pause() {
        guard state == .running else { return }
        session?.pause()
    }

    public func resume() {
        guard state == .paused else { return }
        session?.resume()
    }

    /// Ends the session, finishes the workout and (optionally) writes the effort score. Returns the saved workout.
    /// `metadata` is attached to the `HKWorkout` (see `WorkoutWriter.metadata(for:)`), so the phone's importer can
    /// match it to the logged session by `com.setmio.sessionID` instead of by start time.
    public func end(effort: Int?, metadata: [String: Any] = [:]) async throws -> HKWorkout? {
        guard let session, let builder else { return nil }
        state = .ending
        stopElapsedTicker()
        session.end()
        try await tracked("endCollection") { try await builder.endCollection(at: Date()) }
        if !metadata.isEmpty {
            try await builder.addMetadata(metadata)
        }
        let workout: HKWorkout? = try await tracked("finishWorkout") { try await builder.finishWorkout() }
        if let workout, let effort {
            try await WorkoutWriter(store: store).writeEffort(effort, for: workout)
        }
        lastWorkout = workout
        state = .ended
        self.session = nil
        self.builder = nil
        return workout
    }

    /// Re-attaches to a session HealthKit kept alive across a crash. Call once at watch app launch.
    public func recoverIfNeeded() async {
        guard !isActive else { return }
        do {
            let recovered: HKWorkoutSession? = try await store.recoverActiveWorkoutSession()
            guard let session = recovered else { return }
            let builder = session.associatedWorkoutBuilder()
            // start(plan:) attaches a live data source; the recovered builder needs one too, or nothing is collected
            // automatically (HKLiveWorkoutDataSource.h: "to be used with an HKWorkoutBuilder to automatically collect samples").
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: session.workoutConfiguration)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            apply(sessionState: session.state)
            startElapsedTicker()
            // The old mirroring channel died with the process; best-effort re-establish (WatchConnectivity covers the gap).
            do {
                try await session.startMirroringToCompanionDevice()
                mirroringConnected = true
            } catch {
                mirroringConnected = false
            }
        } catch {
            recordError("recoverActiveWorkoutSession", error.localizedDescription)
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: Mirroring

    public func send(_ message: MirroringMessage) async throws {
        guard let session else { throw MirroringError.noActiveSession }
        let envelope = sequencer.next(message)
        let data = try envelope.encoded()
        do {
            try await session.sendToRemoteWorkoutSession(data: data)
        } catch {
            mirroringConnected = false
            throw error
        }
    }

    // MARK: HKWorkoutSessionDelegate (HealthKit queue → MainActor)

    nonisolated public func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in self.apply(sessionState: toState) }
    }

    nonisolated public func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.stopElapsedTicker()
            self.state = .failed(message)
            self.recordError("HKWorkoutSession", message)
        }
    }

    nonisolated public func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        Task { @MainActor in
            for payload in data {
                guard let envelope = try? MirroringEnvelope.decode(payload) else { continue }
                self.onRemoteMessage?(envelope.message)
            }
        }
    }

    nonisolated public func workoutSession(_ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: (any Error)?) {
        let message = error?.localizedDescription
        Task { @MainActor in
            self.mirroringConnected = false
            if let message { self.recordError("mirroring disconnect", message) }
        }
    }

    // MARK: HKLiveWorkoutBuilderDelegate

    nonisolated public func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let heartRateType = HKQuantityType(.heartRate)
        guard collectedTypes.contains(heartRateType) else { return }
        let bpm = workoutBuilder.statistics(for: heartRateType)?.mostRecentQuantity()?.doubleValue(for: HealthTypes.heartRateUnit)
        Task { @MainActor in
            self.heartRate = bpm
            self.heartRateDeliveries += 1
            if let bpm {
                heartRateLog.info("HR sample #\(self.heartRateDeliveries, privacy: .public): \(bpm, privacy: .private) bpm")
            } else {
                heartRateLog.error("HR collected but builder returned no most-recent quantity (callback #\(self.heartRateDeliveries, privacy: .public))")
            }
        }
    }

    nonisolated public func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    // MARK: Private

    /// Asks for heart-rate read and write access again if the system has not handled the request. A watch workout
    /// only gets heart-rate statistics from the builder when read access was granted, and HealthKit never reports a
    /// denied read, so the request status is the only signal available (`.shouldRequest` = never answered).
    private func ensureHeartRateAuthorization() async {
        let heartRate = HKQuantityType(.heartRate)
        do {
            var status = try await store.statusForAuthorizationRequest(toShare: [heartRate], read: [heartRate])
            if status == .shouldRequest {
                try await store.requestAuthorization(toShare: [heartRate], read: [heartRate])
                status = try await store.statusForAuthorizationRequest(toShare: [heartRate], read: [heartRate])
            }
            heartRateReadRequestStatus = status
        } catch {
            recordError("heartRateAuthorization", error.localizedDescription)
        }
        await probeHeartRateReadAccess()
    }

    /// Looks for one heart-rate sample from the last 24 hours. A read-authorized app sees the watch's all-day samples;
    /// an app whose read access was declined sees none, so the result tells the two cases apart.
    private func probeHeartRateReadAccess() async {
        let heartRate = HKQuantityType(.heartRate)
        let since = Date().addingTimeInterval(-24 * 3600)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: heartRate, predicate: HKQuery.predicateForSamples(withStart: since, end: nil))],
            sortDescriptors: [],
            limit: 1
        )
        do {
            canReadRecentHeartRate = try await descriptor.result(for: store).isEmpty == false
        } catch {
            canReadRecentHeartRate = nil
            recordError("heartRateReadProbe", error.localizedDescription)
        }
    }

    private func recordError(_ step: String, _ message: String) {
        lastErrorText = "\(step)：\(message)"
        heartRateLog.error("\(step, privacy: .public) error: \(message, privacy: .public)")
    }

    /// Runs one builder or session step, records its error for the diagnostics readout, then rethrows.
    private func tracked<T>(_ step: String, _ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            recordError(step, error.localizedDescription)
            throw error
        }
    }

    private func apply(sessionState: HKWorkoutSessionState) {
        switch sessionState {
        case .notStarted, .prepared: state = .preparing
        case .running: state = .running
        case .paused: state = .paused
        case .stopped: state = .ending
        case .ended: if state != .ended { state = .ending }
        @unknown default: break
        }
    }

    private func startElapsedTicker() {
        stopElapsedTicker()
        elapsedTicker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let builder = self.builder {
                    self.elapsed = builder.elapsedTime(at: Date())
                    let heartRateType = HKQuantityType(.heartRate)
                    self.polledHeartRate = builder.statistics(for: heartRateType)?.mostRecentQuantity()?.doubleValue(for: HealthTypes.heartRateUnit)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopElapsedTicker() {
        elapsedTicker?.cancel()
        elapsedTicker = nil
    }
}
#endif
