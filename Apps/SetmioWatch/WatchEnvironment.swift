import Foundation
import Observation
import SetmioCore
import SetmioHealth
#if canImport(HealthKit)
import HealthKit
#endif

/// Watch composition root. The watch never links SetmioData: the in-progress session lives here (and in the
/// journal file), the iPhone is the source of truth once it acks (方案.md §7.7).
@MainActor
@Observable
final class WatchEnvironment {
    struct RestTimer: Equatable, Sendable {
        var state: RestTimerState
        var exerciseName: String

        var endDate: Date { state.endDate }
        var totalSeconds: TimeInterval { state.totalSeconds }
        var isPaused: Bool { state.isPaused }

        func remaining(at now: Date = Date()) -> TimeInterval {
            state.remaining(at: now)
        }
    }

    nonisolated static let freeTrainingName = "自由训练"
    nonisolated static let warningLeadSeconds: TimeInterval = 10

    #if canImport(HealthKit)
    let sessionManager: WorkoutSessionManager
    #endif
    let journal = WatchSessionJournal()
    let connectivity = WatchConnectivityBridge()
    let haptics = HapticsController()
    let restPolicy = RestTimerPolicy()

    /// Today's plan from the phone (application context → file cache), or the built-in free session.
    private(set) var plan: PlannedSession
    private(set) var planVersion: Int?
    /// Seed exercise library (the watch has no store; custom phone-side exercises show as "动作").
    private(set) var exercises: [SetmioCore.ID<Exercise>: Exercise] = [:]

    private(set) var activeSession: LoggedSession?
    /// Index into `plan.exercises` for a planned session.
    private(set) var currentExerciseIndex = 0
    /// Exercise chosen by hand (free training, or after the plan is exhausted).
    private(set) var selectedExerciseID: SetmioCore.ID<Exercise>?
    private(set) var restTimer: RestTimer?
    private(set) var unackedCount = 0
    private(set) var lastError: String?
    /// A session the journal shows as started but never ended, when no HealthKit workout carries it (the app was
    /// killed and the workout ended with it). Offered on the start screen; see `resumeUnfinishedSession`.
    private(set) var unfinishedSession: RecoveredSession?

    private var sequencer = MirroringSequencer()
    private var restTask: Task<Void, Never>?

    // MARK: Init

    init() {
        #if canImport(HealthKit)
        sessionManager = WorkoutSessionManager(store: HKHealthStore())
        #endif
        let today = DayKey(Date())
        plan = WatchConnectivityBridge.loadCachedPlan().flatMap { $0.day == today ? $0 : nil } ?? Self.freePlan(day: today)
        if let seed = try? SeedData.exercises() {
            exercises = Dictionary(seed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        wireCallbacks()
    }

    static func freePlan(day: DayKey) -> PlannedSession {
        PlannedSession(mesocycleID: nil, day: day, dayNameZH: freeTrainingName, exercises: [])
    }

    /// Call once from the app's root `.task`: crash recovery, journal replay, connectivity, notifications.
    func launch() async {
        #if canImport(HealthKit)
        await sessionManager.recoverIfNeeded()
        if sessionManager.isActive, activeSession == nil {
            await restoreActiveSession()
        }
        #endif
        if activeSession == nil {
            await loadUnfinishedSession()
        }
        connectivity.activate()
        await haptics.requestNotificationAuthorization()
        await replayJournal()
    }

    /// Reads the journal for a started-but-unended session. A session that workout recovery already restored is
    /// the active one, so nothing is offered in that case.
    private func loadUnfinishedSession() async {
        let messages = (try? await journal.allMessages()) ?? []
        unfinishedSession = SessionRecovery.unfinishedSession(from: messages)
    }

    /// Continues `unfinishedSession` under its original id: the logged sets stay, and a new HealthKit workout covers
    /// the rest. The interrupted workout is whatever HealthKit saved when the process ended.
    func resumeUnfinishedSession() async {
        guard !isSessionActive, let recovered = unfinishedSession else { return }
        unfinishedSession = nil
        var session = LoggedSession(
            id: recovered.sessionID,
            plannedSessionID: plan.id,
            start: recovered.sets.first?.completedAt ?? Date(),
            origin: .watch
        )
        session.sets = recovered.sets
        adopt(session)
        #if canImport(HealthKit)
        do {
            try await sessionManager.start(plan: plan, planVersion: planVersion)
        } catch {
            lastError = "无法继续训练：\(error.localizedDescription)"
        }
        #endif
    }

    /// Makes `session` the active one and points the plan at the first exercise that still has sets to do.
    private func adopt(_ session: LoggedSession) {
        activeSession = session
        selectedExerciseID = nil
        currentExerciseIndex = plan.exercises.firstIndex { planned in
            session.sets.filter { $0.exerciseID == planned.exerciseID }.count < planned.sets.count
        } ?? plan.exercises.count
    }

    #if canImport(HealthKit)
    /// After a crash with a live `HKWorkoutSession`: rebuild the session (same id, sets) from the journal so
    /// later sets and `.sessionEnded` stay attached to what the phone already has.
    private func restoreActiveSession() async {
        let messages = (try? await journal.allMessages()) ?? []
        let recovered = SessionRecovery.unfinishedSession(from: messages)
        var session = LoggedSession(
            id: recovered?.sessionID ?? SetmioCore.ID(),
            plannedSessionID: plan.id,
            start: sessionManager.sessionStartDate ?? Date(),
            origin: .watch
        )
        session.sets = recovered?.sets ?? []
        adopt(session)
    }
    #endif

    // MARK: Derived state

    var sortedExercises: [Exercise] {
        exercises.values.sorted { $0.nameZH < $1.nameZH }
    }

    var currentPlannedExercise: PlannedExercise? {
        plan.exercises.indices.contains(currentExerciseIndex) ? plan.exercises[currentExerciseIndex] : nil
    }

    var currentExerciseID: SetmioCore.ID<Exercise>? {
        selectedExerciseID ?? currentPlannedExercise?.exerciseID
    }

    var currentExercise: Exercise? {
        currentExerciseID.flatMap { exercises[$0] }
    }

    var currentExerciseName: String {
        currentExercise?.nameZH ?? (currentExerciseID == nil ? "选择动作" : "动作")
    }

    /// Sets already logged for the current exercise in this session (= the next `LoggedSet.index`).
    var completedSetsForCurrentExercise: Int {
        guard let id = currentExerciseID else { return 0 }
        return activeSession?.sets.filter { $0.exerciseID == id }.count ?? 0
    }

    /// The planned set the user is about to do (nil in free training or past the plan).
    var currentPlannedSet: PlannedSet? {
        guard selectedExerciseID == nil, let planned = currentPlannedExercise else { return nil }
        return planned.sets.first { $0.index == completedSetsForCurrentExercise }
    }

    var isSessionActive: Bool {
        #if canImport(HealthKit)
        return activeSession != nil || sessionManager.isActive
        #else
        return activeSession != nil
        #endif
    }

    // MARK: Session lifecycle

    func startSession(free: Bool) async {
        guard !isSessionActive else { return }
        let today = DayKey(Date())
        let sessionPlan = free ? Self.freePlan(day: today) : plan
        if free { plan = sessionPlan }
        currentExerciseIndex = 0
        selectedExerciseID = nil
        activeSession = LoggedSession(plannedSessionID: free ? nil : sessionPlan.id, start: Date(), origin: .watch)
        #if canImport(HealthKit)
        do {
            try await sessionManager.start(plan: sessionPlan, planVersion: planVersion)
        } catch {
            lastError = "无法开始训练：\(error.localizedDescription)"
            activeSession = nil
        }
        #endif
    }

    func selectExercise(_ id: SetmioCore.ID<Exercise>) {
        selectedExerciseID = id
    }

    /// Moves to the next planned exercise (or back into manual selection after the last one).
    func advanceExercise() {
        selectedExerciseID = nil
        if currentExerciseIndex + 1 < plan.exercises.count {
            currentExerciseIndex += 1
        } else {
            currentExerciseIndex = plan.exercises.count
        }
    }

    /// One-tap "完成": journal first, then mirror, then start the rest timer.
    func logSet(load: Kilograms, reps: Int, rir: Int, isWarmup: Bool = false) async {
        guard var session = activeSession, let exerciseID = currentExerciseID else { return }
        let set = LoggedSet(
            sessionID: session.id,
            exerciseID: exerciseID,
            index: completedSetsForCurrentExercise,
            load: load,
            reps: reps,
            rir: rir,
            completedAt: Date(),
            isWarmup: isWarmup
        )
        session.sets.append(set)
        activeSession = session

        let exercise = currentExercise ?? Exercise(nameZH: "动作", primary: [], category: .compound, equipment: .barbell)
        let next = currentPlannedExercise?.sets.first { $0.index == set.index + 1 }
        // The plan is already readiness-modulated by the phone, so no score is passed here.
        let rest = restPolicy.duration(after: set, exercise: exercise, next: next, readiness: nil, overrideSeconds: currentPlannedExercise?.restSecondsOverride)

        haptics.play(.setLogged)
        await journalAndSend(.setLogged(set, restSeconds: Int(rest)))
        startRest(seconds: rest)

        // Planned sets exhausted → move on automatically.
        if selectedExerciseID == nil, let planned = currentPlannedExercise, set.index + 1 >= planned.sets.count {
            advanceExercise()
        }
    }

    func endSession(effort: Int?) async {
        guard var session = activeSession else { return }
        skipRest()
        #if canImport(HealthKit)
        do {
            let workout = try await sessionManager.end(effort: effort, metadata: WorkoutWriter.metadata(for: session))
            session.hkWorkoutUUID = workout?.uuid
        } catch {
            lastError = "结束训练时出错：\(error.localizedDescription)"
        }
        #endif
        session.end = Date()
        session.effortScore = effort
        activeSession = nil
        await journalAndSend(.sessionEnded(session))
    }

    // MARK: Rest timer

    func startRest(seconds: TimeInterval) {
        guard seconds > 0 else { return }
        restTimer = RestTimer(state: RestTimerState(startingAt: Date(), seconds: seconds), exerciseName: currentExerciseName)
        scheduleRestCues()
    }

    func extendRest(by seconds: TimeInterval = 30) {
        guard var timer = restTimer else { return }
        timer.state = timer.state.extended(by: seconds, at: Date())
        restTimer = timer
        scheduleRestCues()
        reportRestTimer()
    }

    func pauseRest() {
        guard var timer = restTimer, !timer.isPaused else { return }
        timer.state = timer.state.paused(at: Date())
        restTimer = timer
        scheduleRestCues()   // cancels the pending cues while paused
        reportRestTimer()
    }

    func resumeRest() {
        guard var timer = restTimer, timer.isPaused else { return }
        timer.state = timer.state.resumed(at: Date())
        restTimer = timer
        scheduleRestCues()
        reportRestTimer()
    }

    func skipRest() {
        let hadTimer = restTimer != nil
        restTask?.cancel()
        restTask = nil
        restTimer = nil
        haptics.cancelScheduledNotifications()
        if hadTimer { reportRestTimer() }
    }

    /// Tells the phone's Live Activity what the timer looks like now (`nil` = no rest). Best effort: the phone
    /// started its own countdown from `.setLogged`, this only corrects it after pause / resume / +30 s / skip.
    private func reportRestTimer() {
        #if canImport(HealthKit)
        guard sessionManager.mirroringConnected else { return }
        let state = restTimer?.state
        Task { try? await sessionManager.send(.restTimerChanged(state)) }
        #endif
    }

    private func scheduleRestCues() {
        restTask?.cancel()
        restTask = nil
        haptics.cancelScheduledNotifications()
        guard let timer = restTimer, !timer.isPaused else { return }
        haptics.scheduleRestOverNotification(at: timer.endDate, exerciseName: timer.exerciseName)
        restTask = Task { [weak self] in
            let warnAt = timer.endDate.addingTimeInterval(-Self.warningLeadSeconds)
            let warnDelay = warnAt.timeIntervalSinceNow
            if warnDelay > 0 {
                try? await Task.sleep(for: .seconds(warnDelay))
                guard !Task.isCancelled, let self else { return }
                self.haptics.play(.warning)
            }
            let remaining = timer.endDate.timeIntervalSinceNow
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            guard !Task.isCancelled, let self else { return }
            self.haptics.play(.finished)
            self.restTimer = nil
            self.restTask = nil
            self.reportRestTimer()
        }
    }

    // MARK: Mirroring / fallback

    private func journalAndSend(_ message: MirroringMessage) async {
        let envelope = sequencer.next(message)
        do {
            try await journal.append(envelope)
            unackedCount = try await journal.replay().count
        } catch {
            lastError = "无法写入本地日志：\(error.localizedDescription)"
        }
        await deliver(envelope)
    }

    private func deliver(_ envelope: MirroringEnvelope) async {
        #if canImport(HealthKit)
        if sessionManager.mirroringConnected {
            do {
                try await sessionManager.send(envelope.message)
                return
            } catch {
                lastError = "镜像发送失败，改用 iPhone 兜底通道"
            }
        }
        #endif
        connectivity.transfer(envelope)
    }

    /// Re-sends everything the phone has not acked (after a crash, or after an offline session).
    func replayJournal() async {
        do {
            let pending = try await journal.replay()
            unackedCount = pending.count
            for entry in pending {
                await deliver(entry.envelope)
            }
        } catch {
            lastError = "无法回放本地日志：\(error.localizedDescription)"
        }
    }

    private func handleRemote(_ message: MirroringMessage) async {
        switch message {
        case .ack(let ids):
            do {
                try await journal.markAcked(ids: ids)
                let pending = try await journal.replay()
                unackedCount = pending.count
                if pending.isEmpty, activeSession == nil {
                    try await journal.purgeAcked()
                }
            } catch {
                lastError = "无法记录确认：\(error.localizedDescription)"
            }

        case .planUpdated(let newPlan):
            applyPlan(newPlan, version: nil)

        case .restTimerCommand(let command):
            switch command {
            case .skip: skipRest()
            case .add30: extendRest(by: 30)
            case .pause: pauseRest()
            case .resume: resumeRest()
            }

        case .hello, .setLogged, .setDeleted, .sessionEnded, .restTimerChanged:
            break // watch → phone only
        }
    }

    private func applyPlan(_ newPlan: PlannedSession, version: Int?) {
        // Never swap the plan under a running session.
        guard activeSession == nil else { return }
        plan = newPlan
        planVersion = version
        currentExerciseIndex = 0
        WatchConnectivityBridge.cache(newPlan)
    }

    private func wireCallbacks() {
        #if canImport(HealthKit)
        sessionManager.onRemoteMessage = { [weak self] message in
            Task { await self?.handleRemote(message) }
        }
        sessionManager.onSendFailure = { [weak self] text in
            self?.lastError = text
        }
        #endif
        connectivity.onPlan = { [weak self] newPlan, version in
            self?.applyPlan(newPlan, version: version)
        }
        connectivity.onEnvelope = { [weak self] envelope in
            await self?.handleRemote(envelope.message)
        }
    }
}
