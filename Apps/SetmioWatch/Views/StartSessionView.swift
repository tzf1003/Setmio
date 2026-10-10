import SwiftUI
import SetmioCore
import SetmioHealth
import SetmioUI
#if canImport(HealthKit)
import HealthKit
#endif

/// Today's plan (from the phone) with a start button, plus 自由训练 for offline / unplanned days.
struct StartSessionView: View {
    @Environment(WatchEnvironment.self) private var env
    @State private var isStarting = false
    @State private var authorizationRequested = false

    var body: some View {
        NavigationStack {
            List {
                if let pending = env.unfinishedSession {
                    Section {
                        Text("上次的训练没有结束，已记 \(pending.sets.count) 组。")
                            .font(.footnote)
                        Button("继续训练") { resume() }
                            .buttonStyle(.setmioPrimary)
                            .disabled(isStarting)
                    } header: {
                        Text("未结束的训练")
                    }
                }
                Section(env.plan.dayNameZH == WatchEnvironment.freeTrainingName ? "没有今日计划" : "今日计划") {
                    if env.plan.exercises.isEmpty {
                        Text("在 iPhone 上开始一个训练周期后，计划会同步到这里。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(env.plan.exercises, id: \.exerciseID) { exercise in
                        VStack(alignment: .leading, spacing: SetmioTokens.Spacing.xxs) {
                            Text(env.exercises[exercise.exerciseID]?.nameZH ?? "动作")
                                .font(.headline)
                            if let first = exercise.sets.first {
                                Text("\(exercise.sets.count) 组 · \(first.targetLoad.map { SetmioFormat.compactKg($0) + " × " } ?? "")\(SetmioFormat.repRange(first.targetReps)) · \(SetmioFormat.rir(first.targetRIR))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let note = env.plan.readinessAdjustment?.noteZH {
                        Text(note).font(.caption2).foregroundStyle(.orange)
                    }
                    if !env.plan.exercises.isEmpty {
                        Button("开始计划训练") { start(free: false) }
                            .buttonStyle(.setmioPrimary)
                            .disabled(isStarting)
                    }
                }
                Section {
                    Button(WatchEnvironment.freeTrainingName) { start(free: true) }
                        .buttonStyle(.setmioPrimary)
                        .disabled(isStarting)
                } footer: {
                    if env.unackedCount > 0 {
                        Text("有 \(env.unackedCount) 条记录尚未同步到 iPhone。")
                    }
                    if let error = env.lastError {
                        Text(error)
                    }
                }
            }
            .navigationTitle("Setmio")
            .task { await requestAuthorizationIfNeeded() }
        }
    }

    private func resume() {
        isStarting = true
        Task {
            await env.resumeUnfinishedSession()
            isStarting = false
        }
    }

    private func start(free: Bool) {
        isStarting = true
        Task {
            await env.startSession(free: free)
            isStarting = false
        }
    }

    private func requestAuthorizationIfNeeded() async {
        #if canImport(HealthKit)
        guard !authorizationRequested, HKHealthStore.isHealthDataAvailable() else { return }
        authorizationRequested = true
        let authorizer = HealthKitAuthorizer(store: HKHealthStore())
        try? await authorizer.requestAuthorization(readKinds: [.heartRate, .activeEnergy], shareKinds: HealthTypes.mvpShareKinds)
        #endif
    }
}
