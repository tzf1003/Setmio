#if canImport(HealthKit) && os(watchOS)
import Foundation
import HealthKit
import Observation
import SetmioCore

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

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor

        let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
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
            onSendFailure?("无法镜像到 iPhone：\(error.localizedDescription)")
        }

        let startDate = Date()
        session.startActivity(with: startDate)
        try await builder.beginCollection(at: startDate)
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
        try await builder.endCollection(at: Date())
        if !metadata.isEmpty {
            try await builder.addMetadata(metadata)
        }
        let workout: HKWorkout? = try await builder.finishWorkout()
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
        Task { @MainActor in self.mirroringConnected = false }
    }

    // MARK: HKLiveWorkoutBuilderDelegate

    nonisolated public func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let heartRateType = HKQuantityType(.heartRate)
        guard collectedTypes.contains(heartRateType) else { return }
        let bpm = workoutBuilder.statistics(for: heartRateType)?.mostRecentQuantity()?.doubleValue(for: HealthTypes.heartRateUnit)
        Task { @MainActor in self.heartRate = bpm }
    }

    nonisolated public func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    // MARK: Private

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
                if let builder = self.builder { self.elapsed = builder.elapsedTime(at: Date()) }
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
