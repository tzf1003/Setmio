import Foundation
import Observation
import SetmioCore
import SetmioHealth
import SetmioData
import SetmioUI

#if canImport(HealthKit) && os(iOS)
/// Consumes watch messages (from the mirrored `HKWorkoutSession`, or from WatchConnectivity as the fallback),
/// upserts them idempotently into the store, answers with `.ack`, and keeps the rest-timer Live Activity in
/// step (one update per logged set — 方案.md §7.7).
@MainActor
@Observable
final class WorkoutMirroringHost {
    enum Channel: Sendable {
        case mirroring, connectivity
    }

    /// Supplies today's plan for `.hello` replies and for the Live Activity's "next set" line.
    var todayPlan: @MainActor () async -> PlannedSession? = { nil }
    /// Sends an envelope over WatchConnectivity (set by `AppEnvironment`).
    var connectivityReply: (@MainActor (MirroringEnvelope) -> Void)?

    private(set) var activeSessionID: SetmioCore.ID<LoggedSession>?
    private(set) var lastMessageAt: Date?
    private(set) var lastError: String?
    private(set) var setsReceived = 0
    /// True while a watch workout is mirrored to this phone (set on attach, cleared when the session closes).
    private(set) var isWatchMirroring = false

    private let receiver: MirroringSessionReceiver
    private let store: SetmioStore
    private let activity: RestTimerActivityController
    private var fallbackSequencer = MirroringSequencer()
    private var consumer: Task<Void, Never>?

    init(receiver: MirroringSessionReceiver, store: SetmioStore, activity: RestTimerActivityController) {
        self.receiver = receiver
        self.store = store
        self.activity = activity
        receiver.onAttach = { [weak self] _ in
            self?.isWatchMirroring = true
            self?.setsReceived = 0
        }
        receiver.onSessionClosed = { [weak self] _ in
            self?.isWatchMirroring = false
            Task { await self?.remoteSessionClosed() }
        }
    }

    /// Starts draining `receiver.messages`. Idempotent.
    func start() {
        guard consumer == nil else { return }
        consumer = Task { [weak self, receiver] in
            for await message in receiver.messages {
                guard let self else { break }
                await self.handle(message, via: .mirroring)
            }
        }
    }

    var isMirroring: Bool { receiver.isConnected }

    // MARK: Inbound

    func handle(_ message: MirroringMessage, via channel: Channel) async {
        lastMessageAt = Date()
        do {
            switch message {
            case .hello:
                if let plan = await todayPlan() {
                    try await reply(.planUpdated(plan), via: channel)
                }

            case .setLogged(let set, let restSeconds):
                try await store.upsertLoggedSets([set], into: set.sessionID)
                activeSessionID = set.sessionID
                setsReceived += 1
                try await reply(.ack(ids: [set.id.rawValue]), via: channel)
                await updateActivity(after: set, restSeconds: restSeconds)

            case .setDeleted(let id):
                try await store.deleteLoggedSets(ids: [id])
                try await reply(.ack(ids: [id.rawValue]), via: channel)

            case .sessionEnded(let session):
                // Default merge keeps sets the phone already has; the revision guard ignores stale re-sends.
                try await store.upsertLoggedSession(session)
                try await reply(.ack(ids: [session.id.rawValue] + session.sets.map(\.id.rawValue)), via: channel)
                await activity.end()
                activeSessionID = nil

            case .restTimerChanged(let timer):
                // The watch is the source of truth: it corrects whatever the phone showed optimistically.
                await activity.apply(timer)

            case .ack, .planUpdated, .restTimerCommand:
                // Phone → watch only; ignore if the watch echoes one back.
                break
            }
        } catch {
            lastError = "处理手表消息失败：\(String(describing: error))"
        }
    }

    // MARK: Outbound

    /// Pushes the plan over the mirrored session when a watch is connected; silently does nothing otherwise
    /// (WatchConnectivity's application context covers the offline case).
    func sendPlanIfConnected(_ plan: PlannedSession) async {
        guard receiver.isConnected else { return }
        try? await receiver.send(.planUpdated(plan))
    }

    /// Live Activity buttons (V2) route here; the watch stays the source of truth for the timer.
    func sendRestTimerCommand(_ command: RestTimerCommand) async {
        try? await reply(.restTimerCommand(command), via: .mirroring)
    }

    /// A Live Activity button was pressed. The phone updates the activity right away (the intent must feel instant)
    /// and tells the watch, whose `.restTimerChanged` reply then confirms or corrects the displayed state.
    func handleActivityAction(_ action: RestTimerAction) async {
        let now = Date()
        switch action {
        case .pause:
            if let timer = activity.currentTimer { await activity.apply(timer.paused(at: now)) }
            await sendRestTimerCommand(.pause)
        case .resume:
            if let timer = activity.currentTimer { await activity.apply(timer.resumed(at: now)) }
            await sendRestTimerCommand(.resume)
        case .add30:
            if let timer = activity.currentTimer { await activity.apply(timer.extended(by: 30, at: now)) }
            await sendRestTimerCommand(.add30)
        case .skip:
            await activity.apply(nil)
            await sendRestTimerCommand(.skip)
        }
    }

    // MARK: Private

    private func reply(_ message: MirroringMessage, via channel: Channel) async throws {
        switch channel {
        case .mirroring:
            do {
                try await receiver.send(message)
            } catch {
                guard let connectivityReply else { throw error }
                connectivityReply(fallbackSequencer.next(message))
            }
        case .connectivity:
            guard let connectivityReply else { throw MirroringError.noActiveSession }
            connectivityReply(fallbackSequencer.next(message))
        }
    }

    private func updateActivity(after set: LoggedSet, restSeconds: Int) async {
        guard restSeconds > 0 else { return }
        let exerciseName = (try? await store.exercise(id: set.exerciseID))?.nameZH ?? "训练"
        var nextTarget: String?
        if let plan = await todayPlan(),
           let planned = plan.exercises.first(where: { $0.exerciseID == set.exerciseID }),
           let next = planned.sets.first(where: { $0.index == set.index + 1 }) {
            let load = next.targetLoad.map { SetmioFormat.compactKg($0) + " × " } ?? ""
            nextTarget = "下一组 \(load)\(SetmioFormat.repRange(next.targetReps)) \(SetmioFormat.rir(next.targetRIR))"
        }
        let state = RestTimerActivityAttributes.ContentState(
            endDate: Date().addingTimeInterval(TimeInterval(restSeconds)),
            setLabel: "第 \(set.index + 1) 组 · \(SetmioFormat.set(load: set.load, reps: set.reps))",
            nextTarget: nextTarget
        )
        await activity.startOrUpdate(sessionID: set.sessionID.rawValue, exerciseName: exerciseName, state: state)
    }

    private func remoteSessionClosed() async {
        await activity.end()
    }
}
#endif
