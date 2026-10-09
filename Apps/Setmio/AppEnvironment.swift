import Foundation
import Observation
import SwiftData
import SetmioCore
import SetmioData
import SetmioHealth
import SetmioHealthTesting
import SetmioAI
import SetmioUI
#if canImport(HealthKit)
import HealthKit
#endif

/// The iOS composition root: owns the store, the HealthKit adapters, the engines, the watch channels and the
/// LLM provider. Everything SwiftUI needs is reachable from here through `@Environment(AppEnvironment.self)`.
///
/// Isolation: `@MainActor`. Heavy work is delegated to actors (`SetmioStore`, `HealthSampleImporter`, the
/// sink inside `HealthSyncService`); this class only coordinates and caches small values for the UI.
@MainActor
@Observable
final class AppEnvironment {
    // MARK: UserDefaults keys (UI preferences only — 方案.md §7.4 "不进 SwiftData")

    nonisolated static let proxyBaseURLKey = "proxyBaseURL"
    nonisolated static let planVersionKey = "planVersion"
    nonisolated static let clientHeader = "ios/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")"

    // MARK: Persistence

    let container: ModelContainer
    let store: SetmioStore
    /// Non-nil when the on-disk container could not be opened and the app fell back to an in-memory one.
    private(set) var startupError: String?

    // MARK: Health

    #if canImport(HealthKit)
    nonisolated(unsafe) let healthStore: HKHealthStore // HKHealthStore is documented thread-safe
    let realSource: HKHealthSampleSource
    let receiver: MirroringSessionReceiver
    #endif
    /// The source feeding `syncService`: the real HealthKit store, or the fake when `settings.demoDataEnabled`.
    private(set) var healthSource: any HealthSampleSource
    private(set) var syncService: HealthSyncService
    /// Bound to the *real* source for the whole process lifetime (background wake-ups have no UI).
    let coordinator: BackgroundDeliveryCoordinator
    private let realSyncService: HealthSyncService

    var importer: HealthSampleImporter { syncService.importer }
    var dailyMetricsSource: DailyMetricsSource { syncService.metricsSource }

    // MARK: Engines (pure, Sendable)

    let readinessCalculator = ReadinessCalculator()
    let progressionEngine = ProgressionEngine()
    let readinessModulator = ReadinessModulator()
    let restTimerPolicy = RestTimerPolicy()
    let planner: TrainingPlanner

    // MARK: Watch channels

    let activityController = RestTimerActivityController()
    #if canImport(HealthKit)
    let mirroringHost: WorkoutMirroringHost
    #endif
    let connectivityBridge = PhoneConnectivityBridge()

    // MARK: AI

    private(set) var proxyClient: ProxyClient?
    private(set) var llmProvider: (any LLMProvider)?
    var proxyBaseURLString: String {
        get { UserDefaults.standard.string(forKey: Self.proxyBaseURLKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.proxyBaseURLKey)
            reconfigureProxy()
        }
    }

    // MARK: Cached singletons

    private(set) var settings: Settings = .default
    private(set) var profile: UserProfile?
    private(set) var isBootstrapped = false
    private(set) var todayPlan: PlannedSession?
    private(set) var lastError: String?

    var calendar: Calendar { settings.calendar }
    var today: DayKey { DayKey(Date(), calendar: calendar) }

    // MARK: - Init

    init() {
        var startupError: String?
        let container: ModelContainer
        do {
            container = try ModelContainerFactory.make()
        } catch {
            startupError = "无法打开本地数据库，已改用临时内存库：\(error.localizedDescription)"
            // A second failure here is unrecoverable; crashing early is better than running without storage.
            container = try! ModelContainerFactory.make(inMemory: true) // swiftlint:disable:this force_try
        }
        self.container = container
        self.startupError = startupError
        // VERIFY: on iOS 17 a @ModelActor created from the main actor ran on the main thread; confirm on iOS 26
        // that SetmioStore's executor is a background one (SetmioData notes). If not, create it in a detached task.
        let store = SetmioStore(modelContainer: container)
        self.store = store

        #if canImport(HealthKit)
        let healthStore = HKHealthStore()
        self.healthStore = healthStore
        let realSource = HKHealthSampleSource(store: healthStore)
        self.realSource = realSource
        // Must exist before the first run loop turn: the system calls workoutSessionMirroringStartHandler right
        // after a background launch triggered by the watch.
        self.receiver = MirroringSessionReceiver(store: healthStore)
        let source: any HealthSampleSource = realSource
        #else
        let source: any HealthSampleSource = FakeHealthSampleSource.demo(endingOn: DayKey(Date()))
        #endif
        self.healthSource = source

        let realService = HealthSyncService(store: store, source: source, anchors: AnchorStore(), calculator: readinessCalculator)
        self.realSyncService = realService
        self.syncService = realService
        self.coordinator = BackgroundDeliveryCoordinator(source: source, importer: realService.importer) { kind in
            await realService.recomputeAfterBackgroundImport(kind)
        }

        self.planner = TrainingPlanner(store: store, engine: progressionEngine, modulator: readinessModulator)

        #if canImport(HealthKit)
        let host = WorkoutMirroringHost(receiver: receiver, store: store, activity: activityController)
        self.mirroringHost = host
        #endif

        wireWatchChannels()
        reconfigureProxy()
    }

    // MARK: - Lifecycle

    /// Called once from `SetmioApp.init` inside a Task: registers observers, seeds the library, loads settings.
    func bootstrap() async {
        guard !isBootstrapped else { return }
        #if canImport(HealthKit)
        mirroringHost.start()
        #endif
        connectivityBridge.activate()
        do {
            try await store.seedExercisesIfNeeded(from: SeedData.exercises())
            try await store.seedProgramsIfNeeded(from: SeedData.programs())
            settings = try await store.settings()
            profile = try await store.profile()
        } catch {
            lastError = "初始化失败：\(error.localizedDescription)"
        }
        isBootstrapped = true

        if settings.demoDataEnabled {
            await useDemoData(true)
        } else {
            // Background delivery is only meaningful on the real store; it is idempotent.
            _ = await coordinator.start(kinds: HealthMetricKind.mvp)
            await syncService.syncToday()
        }
        await refreshTodayPlan()
    }

    /// Full sync followed by a plan refresh (the "同步健康数据" button and pull-to-refresh).
    func syncNow() async {
        await syncService.syncToday()
        await refreshTodayPlan()
    }

    /// Recomputes today's plan from the active mesocycle and pushes it to the watch.
    func refreshTodayPlan() async {
        do {
            todayPlan = try await planner.plan(for: today, now: Date(), calendar: calendar)
        } catch {
            lastError = "无法生成今日计划：\(error.localizedDescription)"
        }
        await publishTodayPlan()
    }

    private func publishTodayPlan() async {
        guard let todayPlan else { return }
        let version = UserDefaults.standard.integer(forKey: Self.planVersionKey) + 1
        UserDefaults.standard.set(version, forKey: Self.planVersionKey)
        do {
            try connectivityBridge.pushPlan(todayPlan, version: version)
        } catch {
            lastError = "无法推送计划到手表：\(error.localizedDescription)"
        }
        #if canImport(HealthKit)
        await mirroringHost.sendPlanIfConnected(todayPlan)
        #endif
    }

    // MARK: - Settings / profile

    func saveSettings(_ new: Settings) async {
        let demoChanged = new.demoDataEnabled != settings.demoDataEnabled
        settings = new
        do {
            try await store.saveSettings(new)
        } catch {
            lastError = "保存设置失败：\(error.localizedDescription)"
        }
        if demoChanged { await useDemoData(new.demoDataEnabled) }
    }

    /// Finishes first-launch onboarding: stores the profile and starts a mesocycle from `program`.
    /// Returns an error message (profile is kept only when both steps succeed), nil on success.
    func completeOnboarding(profile new: UserProfile, program: ProgramTemplate) async -> String? {
        do {
            try await planner.startMesocycle(program: program, startDay: today)
            try await store.saveProfile(new)
        } catch {
            return "无法完成初始化：\(error.localizedDescription)"
        }
        profile = new
        await refreshTodayPlan()
        return nil
    }

    func saveProfile(_ new: UserProfile) async {
        profile = new
        do {
            try await store.saveProfile(new)
        } catch {
            lastError = "保存档案失败：\(error.localizedDescription)"
        }
    }

    /// Swaps the health source between HealthKit and 60 days of seeded demo data, then re-syncs.
    /// Demo rows are tagged with `DemoHealthData.scaleSource`; switching demo off removes them.
    func useDemoData(_ enabled: Bool) async {
        if settings.demoDataEnabled != enabled {
            settings.demoDataEnabled = enabled
            try? await store.saveSettings(settings)
        }
        if enabled {
            let fake = FakeHealthSampleSource.demo(endingOn: today, calendar: calendar)
            healthSource = fake
            // A throw-away anchor file: the fake is rebuilt on every switch, so old anchors would skip its data.
            let anchorURL = FileManager.default.temporaryDirectory
                .appending(path: "demo-anchors-\(UUID().uuidString).json", directoryHint: .notDirectory)
            syncService = HealthSyncService(store: store, source: fake, anchors: AnchorStore(fileURL: anchorURL), calculator: readinessCalculator)
        } else {
            #if canImport(HealthKit)
            healthSource = realSource
            #endif
            syncService = realSyncService
            try? await store.deleteBodyMeasurements(source: DemoHealthData.scaleSource)
            _ = await coordinator.start(kinds: HealthMetricKind.mvp)
        }
        await syncService.syncToday()
        await refreshTodayPlan()
    }

    // MARK: - AI

    private func reconfigureProxy() {
        let trimmed = proxyBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else {
            proxyClient = nil
            llmProvider = nil
            return
        }
        let client = ProxyClient(baseURL: url, credentials: KeychainCredentialStore(), clientHeader: Self.clientHeader)
        proxyClient = client
        llmProvider = ClaudeProxyProvider(client: client)
    }

    // MARK: - Private

    private func wireWatchChannels() {
        #if canImport(HealthKit)
        let host = mirroringHost
        host.todayPlan = { [weak self] in self?.todayPlan }
        // Fallback transport: envelopes that arrive over WatchConnectivity are handled by the same host, and
        // replies go back the same way.
        connectivityBridge.onEnvelope = { [weak host] envelope in
            await host?.handle(envelope.message, via: .connectivity)
        }
        host.connectivityReply = { [weak self] envelope in
            self?.connectivityBridge.transfer(envelope)
        }
        #endif
    }
}
