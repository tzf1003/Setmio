import SwiftUI
import SetmioCore
import SetmioUI
#if canImport(HealthKit)
import HealthKit
import SetmioHealth
#endif

/// Training tab: program templates → start a mesocycle; today's planned session; a phone-only "记一组" flow
/// (sets go straight into the store, the finished session is saved to HealthKit); session history.
struct TrainingView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var programs: [ProgramTemplate] = []
    @State private var mesocycle: Mesocycle?
    @State private var sessions: [LoggedSession] = []
    @State private var exercises: [Exercise] = []
    @State private var phoneSession: LoggedSession?
    @State private var showLogSheet = false
    @State private var showEndSheet = false
    @State private var error: String?

    private var exerciseNames: [SetmioCore.ID<Exercise>: String] {
        Dictionary(exercises.map { ($0.id, $0.nameZH) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        NavigationStack {
            List {
                mesocycleSection
                todaySection
                phoneLoggingSection
                historySection
                if let error {
                    Section { Text(error).foregroundStyle(SetmioTokens.Colors.negative) }
                }
            }
            .navigationTitle("训练")
            .task { await load() }
            .refreshable { await load() }
            .sheet(isPresented: $showLogSheet) {
                if let session = phoneSession {
                    LogSetSheet(exercises: exercises, nextIndex: session.sets.count, plan: env.todayPlan) { set in
                        await log(set, into: session)
                    }
                }
            }
            .sheet(isPresented: $showEndSheet) {
                EndSessionSheet { effort in
                    await endPhoneSession(effort: effort)
                }
            }
        }
    }

    // MARK: Sections

    private var mesocycleSection: some View {
        Section("训练周期") {
            if let mesocycle, let program = programs.first(where: { $0.id == mesocycle.templateID }) {
                VStack(alignment: .leading, spacing: SetmioTokens.Spacing.xxs) {
                    Text(program.nameZH).font(SetmioTokens.Typography.label)
                    let week = mesocycle.currentWeek
                    Text("第 \(mesocycle.currentWeekIndex + 1)/\(mesocycle.weeks.count) 周 · 目标 \(SetmioFormat.rir(week?.targetRIR ?? 2))\(week?.isDeload == true ? " · 减载周" : "") · 始于 \(SetmioFormat.date(mesocycle.startDay, calendar: env.calendar))")
                        .font(SetmioTokens.Typography.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("还没有开始周期。选择一个模板：")
                    .font(SetmioTokens.Typography.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(programs) { program in
                Button {
                    Task { await start(program) }
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(program.nameZH)
                            Text("每周 \(program.daysPerWeek) 天 · \(program.mesocycleWeeks) 周（含减载）")
                                .font(SetmioTokens.Typography.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: mesocycle?.templateID == program.id ? "checkmark.circle.fill" : "play.circle")
                            .foregroundStyle(SetmioTokens.Colors.accent)
                    }
                }
                .tint(.primary)
            }
        }
    }

    @ViewBuilder
    private var todaySection: some View {
        Section("今日计划") {
            if let plan = env.todayPlan {
                Text(plan.dayNameZH).font(SetmioTokens.Typography.label)
                ForEach(plan.exercises, id: \.exerciseID) { exercise in
                    DisclosureGroup {
                        ForEach(exercise.sets) { set in
                            HStack {
                                Text(set.isWarmup ? "热身" : "第 \(set.index + 1) 组")
                                Spacer()
                                Text("\(set.targetLoad.map { SetmioFormat.compactKg($0) + " × " } ?? "")\(SetmioFormat.repRange(set.targetReps)) · \(SetmioFormat.rir(set.targetRIR))")
                                    .font(SetmioTokens.Typography.setValue)
                            }
                        }
                        Text(exercise.decision.explanationZH)
                            .font(SetmioTokens.Typography.footnote)
                            .foregroundStyle(.secondary)
                    } label: {
                        HStack {
                            Text(exerciseNames[exercise.exerciseID] ?? "未知动作")
                            Spacer()
                            Text(TodayView.summary(of: exercise))
                                .font(SetmioTokens.Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("开始一个周期后，这里会显示由渐进规则生成的今日计划。")
                    .font(SetmioTokens.Typography.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var phoneLoggingSection: some View {
        Section("手机记录（无手表时）") {
            if let session = phoneSession {
                Text("进行中 · 始于 \(SetmioFormat.clock(session.start, calendar: env.calendar)) · 已记 \(session.sets.count) 组")
                    .font(SetmioTokens.Typography.footnote)
                    .foregroundStyle(.secondary)
                ForEach(session.sets.sorted { $0.index < $1.index }) { set in
                    HStack {
                        Text(exerciseNames[set.exerciseID] ?? "")
                            .font(SetmioTokens.Typography.caption)
                            .frame(width: 80, alignment: .leading)
                            .lineLimit(1)
                        SetRow(set)
                    }
                }
                Button("记一组") { showLogSheet = true }
                    .buttonStyle(.setmioPrimary)
                Button("结束训练", role: .destructive) { showEndSheet = true }
            } else {
                Button("开始手机记录") {
                    phoneSession = LoggedSession(plannedSessionID: env.todayPlan?.id, start: Date(), origin: .phone)
                }
            }
        }
    }

    private var historySection: some View {
        Section("历史") {
            if sessions.isEmpty {
                Text("还没有训练记录。").foregroundStyle(.secondary)
            }
            ForEach(sessions) { session in
                VStack(alignment: .leading, spacing: SetmioTokens.Spacing.xxs) {
                    HStack {
                        Text(SetmioFormat.date(session.start, calendar: env.calendar))
                        Spacer()
                        Text(session.origin.nameZH)
                            .font(SetmioTokens.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(session.sets.filter { !$0.isWarmup }.count) 组 · 总量 \(SetmioFormat.compactKg(session.totalVolume))\(session.durationMinutes.map { " · \(Int($0)) 分钟" } ?? "")\(session.effortScore.map { " · 强度 \($0)/10" } ?? "")")
                        .font(SetmioTokens.Typography.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Actions

    private func load() async {
        do {
            programs = try await env.store.programs()
            mesocycle = try await env.store.activeMesocycle()
            exercises = try await env.store.exercises()
            sessions = try await env.store.loggedSessions(limit: 30)
            error = nil
        } catch {
            self.error = "加载失败：\(error.localizedDescription)"
        }
    }

    private func start(_ program: ProgramTemplate) async {
        do {
            mesocycle = try await env.planner.startMesocycle(program: program, startDay: env.today)
            await env.refreshTodayPlan()
            await load()
        } catch {
            self.error = "无法开始周期：\(error.localizedDescription)"
        }
    }

    private func log(_ set: LoggedSet, into session: LoggedSession) async {
        var session = session
        var set = set
        set.sessionID = session.id
        session.sets.append(set)
        phoneSession = session
        do {
            try await env.store.upsertLoggedSession(session)
            try await env.store.upsertLoggedSets([set], into: session.id)
        } catch {
            self.error = "保存失败：\(error.localizedDescription)"
        }
    }

    private func endPhoneSession(effort: Int?) async {
        guard var session = phoneSession else { return }
        session.end = Date()
        session.effortScore = effort
        session.revision += 1
        #if canImport(HealthKit)
        if HKHealthStore.isHealthDataAvailable(), !session.sets.isEmpty {
            do {
                let workout = try await WorkoutWriter(store: env.healthStore).writePhoneOnlyWorkout(session: session)
                session.hkWorkoutUUID = workout.uuid
            } catch {
                self.error = "已保存本地记录，但写入「健康」失败：\(error.localizedDescription)"
            }
        }
        #endif
        do {
            try await env.store.upsertLoggedSession(session, replacingSets: true)
        } catch {
            self.error = "保存失败：\(error.localizedDescription)"
        }
        phoneSession = nil
        await env.refreshTodayPlan()
        await load()
    }
}

// MARK: - Sheets

private struct LogSetSheet: View {
    let exercises: [Exercise]
    let nextIndex: Int
    /// Today's plan: the picker starts on its first exercise and the fields are prefilled from its first set.
    let plan: PlannedSession?
    let onSave: (LoggedSet) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var exerciseID: SetmioCore.ID<Exercise>?
    @State private var load: Double = 20
    @State private var reps: Int = 10
    @State private var rir: Int = 2
    @State private var isWarmup = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("动作", selection: $exerciseID) {
                    ForEach(exercises) { exercise in
                        Text(exercise.nameZH).tag(Optional(exercise.id))
                    }
                }
                Stepper(value: $load, in: 0...500, step: 2.5) {
                    LabeledContent("重量", value: SetmioFormat.kg(load))
                }
                Stepper(value: $reps, in: 1...50) {
                    LabeledContent("次数", value: "\(reps)")
                }
                Stepper(value: $rir, in: 0...6) {
                    LabeledContent("余力", value: SetmioFormat.rir(rir))
                }
                Toggle("热身组", isOn: $isWarmup)
            }
            .navigationTitle("记一组")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let exerciseID else { return }
                        let set = LoggedSet(
                            sessionID: SetmioCore.ID(),   // replaced by the caller
                            exerciseID: exerciseID,
                            index: nextIndex,
                            load: load,
                            reps: reps,
                            rir: rir,
                            completedAt: Date(),
                            isWarmup: isWarmup
                        )
                        Task {
                            await onSave(set)
                            dismiss()
                        }
                    }
                    .disabled(exerciseID == nil)
                }
            }
            .onAppear {
                if exerciseID == nil { exerciseID = plan?.exercises.first?.exerciseID ?? exercises.first?.id }
                prefill()
            }
            .onChange(of: exerciseID) { prefill() }
        }
    }
}

private extension LogSetSheet {
    /// Fills the steppers from the plan's first set for the selected exercise (the user edits what they actually did).
    func prefill() {
        guard let target = plan?.exercises.first(where: { $0.exerciseID == exerciseID })?.sets.first(where: { !$0.isWarmup }) else { return }
        if let planned = target.targetLoad { load = planned }
        reps = target.targetReps.lowerBound
        rir = target.targetRIR
    }
}

private struct EndSessionSheet: View {
    let onEnd: (Int?) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var effort = 6
    @State private var rated = true

    var body: some View {
        NavigationStack {
            Form {
                Toggle("评价训练强度", isOn: $rated)
                if rated {
                    Stepper(value: $effort, in: 1...10) {
                        LabeledContent("强度（1 轻松 … 10 极限）", value: "\(effort)")
                    }
                }
                Text("强度评分会与训练一起写入「健康」，用于 Apple 的训练负荷。")
                    .font(SetmioTokens.Typography.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("结束训练")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("结束") {
                        Task {
                            await onEnd(rated ? effort : nil)
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
