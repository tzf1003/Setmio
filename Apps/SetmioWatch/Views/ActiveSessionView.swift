import SwiftUI
import SetmioCore
import SetmioUI

/// Live session: heart rate, elapsed time, the current exercise/set with the plan's targets prefilled,
/// Digital Crown load adjustment, one-tap "完成", and "结束训练" → effort rating.
struct ActiveSessionView: View {
    @Environment(WatchEnvironment.self) private var env

    @State private var load: Double = 20
    @State private var reps: Int = 10
    @State private var rir: Int = 2
    @State private var showEndSheet = false
    @State private var isLogging = false

    var body: some View {
        NavigationStack {
            Group {
                if env.currentExerciseID == nil {
                    ExercisePickerView()
                } else {
                    loggingScreen
                }
            }
            .navigationTitle(env.plan.dayNameZH)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("结束", role: .destructive) { showEndSheet = true }
                }
            }
            .sheet(isPresented: $showEndSheet) {
                EffortRatingSheet { effort in
                    await env.endSession(effort: effort)
                }
            }
            .overlay {
                if env.restTimer != nil {
                    RestTimerView()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: env.restTimer != nil)
        }
    }

    // MARK: Logging screen

    private var loggingScreen: some View {
        ScrollView {
            VStack(spacing: SetmioTokens.Spacing.sm) {
                statusRow
                Text(env.currentExerciseName)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(targetLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(SetmioFormat.kg(load))
                    .font(SetmioTokens.Typography.timer)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .focusable(true)
                    .digitalCrownRotation($load, from: 0, through: 500, by: 2.5, sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)

                HStack(spacing: SetmioTokens.Spacing.sm) {
                    counter(title: "次数", value: $reps, range: 1...50)
                    counter(title: "余力", value: $rir, range: 0...6)
                }

                Button {
                    logSet()
                } label: {
                    Text("完成 · 第 \(env.completedSetsForCurrentExercise + 1) 组")
                }
                .buttonStyle(.setmioPrimary)
                .disabled(isLogging)

                Button("下一动作") { env.advanceExercise() }
                    .font(.footnote)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, SetmioTokens.Spacing.gutter)
        }
        .task(id: prefillKey) { prefill() }
    }

    private var statusRow: some View {
        HStack {
            Label(env.sessionManagerHeartRateText, systemImage: "heart.fill")
                .foregroundStyle(.red)
            Spacer()
            Text(env.elapsedText)
                .monospacedDigit()
        }
        .font(.caption2)
    }

    private var targetLine: String {
        if let planned = env.currentPlannedSet {
            let loadText = planned.targetLoad.map { SetmioFormat.compactKg($0) + " × " } ?? ""
            return "目标 \(loadText)\(SetmioFormat.repRange(planned.targetReps)) · \(SetmioFormat.rir(planned.targetRIR))"
        }
        return "自由记录"
    }

    private func counter(title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(spacing: SetmioTokens.Spacing.xxs) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: SetmioTokens.Spacing.xs) {
                Button { value.wrappedValue = max(range.lowerBound, value.wrappedValue - 1) } label: { Image(systemName: "minus") }
                    .buttonStyle(.bordered)
                Text("\(value.wrappedValue)")
                    .font(SetmioTokens.Typography.setValue)
                    .frame(minWidth: 28)
                Button { value.wrappedValue = min(range.upperBound, value.wrappedValue + 1) } label: { Image(systemName: "plus") }
                    .buttonStyle(.bordered)
            }
        }
    }

    /// Changes whenever the exercise or the upcoming set changes, so the prefill runs again.
    private var prefillKey: String {
        "\(env.currentExerciseID?.description ?? "-")#\(env.completedSetsForCurrentExercise)"
    }

    private func prefill() {
        if let planned = env.currentPlannedSet {
            if let target = planned.targetLoad { load = target }
            reps = planned.targetReps.lowerBound
            rir = planned.targetRIR
        } else if let last = env.activeSession?.sets.last(where: { $0.exerciseID == env.currentExerciseID }) {
            load = last.load
            reps = last.reps
            rir = last.rir
        }
    }

    private func logSet() {
        isLogging = true
        Task {
            await env.logSet(load: load, reps: reps, rir: rir)
            isLogging = false
        }
    }
}

// MARK: - Exercise picker (free training)

private struct ExercisePickerView: View {
    @Environment(WatchEnvironment.self) private var env

    var body: some View {
        List(env.sortedExercises) { exercise in
            Button {
                env.selectExercise(exercise.id)
            } label: {
                VStack(alignment: .leading) {
                    Text(exercise.nameZH)
                    Text(exercise.primary.map(\.nameZH).joined(separator: "·"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Effort rating

private struct EffortRatingSheet: View {
    let onEnd: (Int?) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var effort = 6
    @State private var isEnding = false

    var body: some View {
        VStack(spacing: SetmioTokens.Spacing.sm) {
            Text("训练强度").font(.headline)
            Picker("强度", selection: $effort) {
                ForEach(1...10, id: \.self) { value in
                    Text("\(value)").tag(value)
                }
            }
            .labelsHidden()
            .frame(height: 60)
            Text(effortLabel).font(.caption2).foregroundStyle(.secondary)
            Button("保存并结束") { end(effort) }
                .buttonStyle(.setmioPrimary)
                .disabled(isEnding)
            Button("不评分结束") { end(nil) }
                .font(.footnote)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(isEnding)
        }
        .padding(.horizontal, SetmioTokens.Spacing.gutter)
    }

    private var effortLabel: String {
        switch effort {
        case 1...3: "轻松"
        case 4...6: "中等"
        case 7...8: "困难"
        default: "极限"
        }
    }

    private func end(_ value: Int?) {
        isEnding = true
        Task {
            await onEnd(value)
            isEnding = false
            dismiss()
        }
    }
}

// MARK: - Small display helpers

extension WatchEnvironment {
    var sessionManagerHeartRateText: String {
        #if canImport(HealthKit)
        return sessionManager.heartRate.map { SetmioFormat.bpm($0) } ?? "-- bpm"
        #else
        return "-- bpm"
        #endif
    }

    var elapsedText: String {
        #if canImport(HealthKit)
        return SetmioFormat.duration(sessionManager.elapsed)
        #else
        return SetmioFormat.duration(activeSession.map { Date().timeIntervalSince($0.start) } ?? 0)
        #endif
    }
}
