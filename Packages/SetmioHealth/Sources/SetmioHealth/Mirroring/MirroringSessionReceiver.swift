#if canImport(HealthKit) && os(iOS)
import Foundation
import HealthKit
import SetmioCore

/// iPhone side of workout mirroring. Must be created in `SetmioApp.init` (synchronously, before any UI) because
/// the system launches the app in the background and immediately calls `workoutSessionMirroringStartHandler`.
///
/// Decoded messages are delivered in arrival order through `messages`; `WorkoutMirroringHost` in the app
/// consumes them, upserts sets idempotently and answers with `send(.ack(ids:))`.
@MainActor
public final class MirroringSessionReceiver: NSObject, HKWorkoutSessionDelegate {
    public let messages: AsyncStream<MirroringMessage>
    nonisolated private let continuation: AsyncStream<MirroringMessage>.Continuation // VERIFY: `nonisolated let` on a Sendable stored property of a @MainActor class (SE-0434)

    public private(set) var activeSession: HKWorkoutSession?
    public private(set) var isConnected = false
    public private(set) var remoteState: HKWorkoutSessionState = .notStarted
    /// Set when the remote session ends or disconnects, so the host can finalise the local session.
    public var onSessionClosed: (@MainActor (HKWorkoutSession) -> Void)?

    private let store: HKHealthStore
    private var sequencer = MirroringSequencer()

    public init(store: HKHealthStore) {
        self.store = store
        let (stream, continuation) = AsyncStream<MirroringMessage>.makeStream(bufferingPolicy: .unbounded)
        self.messages = stream
        self.continuation = continuation
        super.init()
        store.workoutSessionMirroringStartHandler = { [weak self] session in
            let boxed = UncheckedSendable(session) // HKWorkoutSession is handed over once by HealthKit; VERIFY whether the SDK marks it Sendable
            Task { @MainActor in self?.attach(boxed.value) }
        }
    }

    deinit {
        continuation.finish()
    }

    /// Phone → watch. Throws `MirroringError.noActiveSession` when no watch session is mirrored.
    public func send(_ message: MirroringMessage) async throws {
        guard let session = activeSession else { throw MirroringError.noActiveSession }
        let data = try sequencer.next(message).encoded()
        try await session.sendToRemoteWorkoutSession(data: data)
    }

    public func ack(_ ids: [UUID]) async throws {
        try await send(.ack(ids: ids))
    }

    // MARK: Attach

    private func attach(_ session: HKWorkoutSession) {
        session.delegate = self
        activeSession = session
        isConnected = true
        remoteState = session.state
        sequencer = MirroringSequencer()
    }

    private func close(_ session: HKWorkoutSession) {
        guard activeSession === session else { return }
        isConnected = false
        activeSession = nil
        onSessionClosed?(session)
    }

    // MARK: HKWorkoutSessionDelegate (HealthKit queue → MainActor)

    nonisolated public func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        let boxed = UncheckedSendable(workoutSession)
        Task { @MainActor in
            self.remoteState = toState
            if toState == .ended { self.close(boxed.value) }
        }
    }

    nonisolated public func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {
        let boxed = UncheckedSendable(workoutSession)
        Task { @MainActor in self.close(boxed.value) }
    }

    nonisolated public func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        // Decode and yield here (not after a hop) so arrival order is preserved across callbacks.
        for payload in data {
            guard let envelope = try? MirroringEnvelope.decode(payload) else { continue }
            continuation.yield(envelope.message)
        }
    }

    nonisolated public func workoutSession(_ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: (any Error)?) {
        let boxed = UncheckedSendable(workoutSession)
        Task { @MainActor in self.close(boxed.value) }
    }
}
#endif
