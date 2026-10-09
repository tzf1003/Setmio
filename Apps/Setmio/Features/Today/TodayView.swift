import SwiftUI
import SetmioCore
import SetmioUI

/// Today: readiness gauge with its components and flags (or the "数据不足" state), today's planned session with
/// the engine's explanations, and the manual sync button.
struct TodayView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var exerciseNames: [SetmioCore.ID<Exercise>: String] = [:]

    private var sync: HealthSyncService { env.syncService }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: SetmioTokens.Spacing.lg) {
                    readinessCard
                    metricsRow
                    planCard
                    syncButton
                    if let error = sync.lastError ?? env.lastError {
                        Text(error)
                            .font(SetmioTokens.Typography.footnote)
                            .foregroundStyle(SetmioTokens.Colors.negative)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, SetmioTokens.Spacing.gutter)
                .padding(.vertical, SetmioTokens.Spacing.md)
            }
            .background(SetmioTokens.Colors.groupedBackground)
            .navigationTitle(SetmioFormat.date(env.today, calendar: env.calendar))
            .refreshable { await env.syncNow() }
            .task(id: env.todayPlan?.id) { await loadNames() }
        }
    }

    // MARK: Readiness

    @ViewBuilder
    private var readinessCard: some View {
        VStack(alignment: .leading, spacing: SetmioTokens.Spacing.md) {
            Text("今日准备度")
                .font(SetmioTokens.Typography.title)

            switch sync.readiness {
            case .some(.score(let score)):
                HStack(alignment: .center, spacing: SetmioTokens.Spacing.lg) {
                    ReadinessGauge(score)
                        .frame(width: 140, height: 140)
                    VStack(alignment: .leading, spacing: SetmioTokens.Spacing.xs) {
                        ForEach(score.components, id: \.kind) { component in
                            componentRow(component)
                        }
                        Text("基线 \(score.baselineDays) 天 · 置信度 \(SetmioFormat.percent(score.confidence))")
                            .font(SetmioTokens.Typography.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(score.flags, id: \.self) { flag in
                    Label(flag.nameZH, systemImage: flag == .recoveryDayOverride ? "exclamationmark.triangle" : "info.circle")
                        .font(SetmioTokens.Typography.footnote)
                        .foregroundStyle(flag == .recoveryDayOverride ? SetmioTokens.Colors.warning : Color.secondary)
                }

            case .some(.insufficientData(let available, let required)):
                VStack(alignment: .leading, spacing: SetmioTokens.Spacing.xs) {
                    Text("数据不足 (\(available)/\(required) 天)")
                        .font(SetmioTokens.Typography.metricValue)
                    Text("需要至少 \(required) 天的夜间 HRV 基线才能评分。戴表睡觉，或在设置中打开演示数据。")
                        .font(SetmioTokens.Typography.footnote)
                        .foregroundStyle(.secondary)
                }

            case .none:
                if sync.isSyncing {
                    syncProgressView
                } else {
                    Text("尚未同步")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .setmioCard()
    }

    /// Determinate while importing (kind-by-kind), indeterminate while aggregating and scoring.
    @ViewBuilder
    private var syncProgressView: some View {
        if let progress = sync.importProgress {
            VStack(alignment: .leading, spacing: SetmioTokens.Spacing.xs) {
                ProgressView(value: progress.fractionOfKindsCompleted)
                Text("正在导入 \(progress.kind.nameZH)（\(progress.kindIndex + 1)/\(progress.kindCount)）· 已导入 \(progress.importedSoFar) 条")
                    .font(SetmioTokens.Typography.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            ProgressView("正在计算每日指标与评分…")
        }
    }

    private func componentRow(_ component: ReadinessComponent) -> some View {
        HStack {
            Text(component.kind.nameZH)
                .font(SetmioTokens.Typography.caption)
            Spacer()
            Text(String(format: "%+.2f", component.subScore))
                .font(SetmioTokens.Typography.caption.monospacedDigit())
                .foregroundStyle(component.subScore < -0.5 ? SetmioTokens.Colors.negative : (component.subScore > 0.25 ? SetmioTokens.Colors.positive : Color.secondary))
        }
    }

    @ViewBuilder
    private var metricsRow: some View {
        if let metrics = sync.todayMetrics {
            HStack(spacing: SetmioTokens.Spacing.md) {
                MetricTile(
                    title: "夜间 HRV",
                    value: (metrics.hrvRMSSD ?? metrics.hrvSDNN).map(SetmioFormat.milliseconds) ?? "—",
                    subtitle: metrics.hrvRMSSD != nil ? "RMSSD" : "SDNN"
                )
                MetricTile(title: "静息心率", value: metrics.restingHR.map(SetmioFormat.bpm) ?? "—")
                MetricTile(title: "睡眠", value: metrics.sleep.map { SetmioFormat.minutesAsHours($0.asleepMinutes) } ?? "—")
            }
        }
    }

    // MARK: Plan

    @ViewBuilder
    private var planCard: some View {
        VStack(alignment: .leading, spacing: SetmioTokens.Spacing.sm) {
            Text("今日训练")
                .font(SetmioTokens.Typography.title)

            if let plan = env.todayPlan {
                Text(plan.dayNameZH)
                    .font(SetmioTokens.Typography.label)
                if let adjustment = plan.readinessAdjustment {
                    Label(adjustment.noteZH, systemImage: "slider.horizontal.3")
                        .font(SetmioTokens.Typography.footnote)
                        .foregroundStyle(SetmioTokens.Colors.warning)
                }
                ForEach(plan.exercises, id: \.exerciseID) { exercise in
                    VStack(alignment: .leading, spacing: SetmioTokens.Spacing.xxs) {
                        HStack {
                            Text(exerciseNames[exercise.exerciseID] ?? "…")
                                .font(SetmioTokens.Typography.body.weight(.medium))
                            Spacer()
                            Text(exercise.decision.shortLabelZH)
                                .font(SetmioTokens.Typography.caption)
                                .padding(.horizontal, SetmioTokens.Spacing.sm)
                                .padding(.vertical, SetmioTokens.Spacing.xxs)
                                .background(SetmioTokens.Colors.accent.opacity(0.15), in: Capsule())
                        }
                        Text(Self.summary(of: exercise))
                            .font(SetmioTokens.Typography.caption)
                            .foregroundStyle(.secondary)
                        Text(exercise.decision.explanationZH)
                            .font(SetmioTokens.Typography.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, SetmioTokens.Spacing.xs)
                }
            } else {
                Text("没有进行中的训练周期。在「训练」中选择一个模板开始。")
                    .font(SetmioTokens.Typography.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .setmioCard()
    }

    static func summary(of exercise: PlannedExercise) -> String {
        guard let first = exercise.sets.first else { return "无组" }
        let load = first.targetLoad.map { SetmioFormat.compactKg($0) + " × " } ?? ""
        return "\(exercise.sets.count) 组 · \(load)\(SetmioFormat.repRange(first.targetReps)) · \(SetmioFormat.rir(first.targetRIR))"
    }

    // MARK: Sync

    private var syncButton: some View {
        VStack(spacing: SetmioTokens.Spacing.xs) {
            Button {
                Task { await env.syncNow() }
            } label: {
                if sync.isSyncing {
                    ProgressView().tint(.white)
                } else {
                    Label("同步健康数据", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .buttonStyle(.setmioPrimary)
            .disabled(sync.isSyncing)

            if let report = sync.lastReport {
                Text("上次导入 \(report.totalImported) 条样本 · \(SetmioFormat.clock(report.finishedAt, calendar: env.calendar))")
                    .font(SetmioTokens.Typography.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadNames() async {
        guard let plan = env.todayPlan else { return }
        exerciseNames = (try? await env.planner.exerciseNames(for: plan)) ?? [:]
    }
}
