import SwiftUI
import SetmioCore
import SetmioHealth
import SetmioUI

/// First-launch flow: profile (sex / height / birthday / goal weight) → program template → start the mesocycle.
/// Shown as a full-screen cover until a profile exists; the mesocycle is created by the last step.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env

    private enum Step { case profile, health, program }

    @State private var step: Step = .profile
    @State private var sex: BiologicalSex = .male
    @State private var heightCm: Double = 175
    @State private var birthDate = Date(timeIntervalSince1970: 631_152_000) // 1990-01-01
    @State private var hasGoalWeight = false
    @State private var goalWeight: Double = 70
    @State private var programs: [ProgramTemplate] = []
    @State private var selectedProgramID: SetmioCore.ID<ProgramTemplate>?
    @State private var isWorking = false
    @State private var healthNote: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .profile: profileForm
                case .health: healthForm
                case .program: programForm
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .task { await loadPrograms() }
        }
        .interactiveDismissDisabled()
    }

    // MARK: Step 1 — profile

    private var profileForm: some View {
        Form {
            Section {
                Picker("性别", selection: $sex) {
                    ForEach(BiologicalSex.allCases, id: \.self) { Text($0.nameZH).tag($0) }
                }
                Stepper(value: $heightCm, in: 120...230, step: 1) {
                    LabeledContent("身高", value: "\(Int(heightCm)) cm")
                }
                DatePicker("出生日期", selection: $birthDate, in: ...Date(), displayedComponents: .date)
                Toggle("设定目标体重", isOn: $hasGoalWeight)
                if hasGoalWeight {
                    Stepper(value: $goalWeight, in: 30...200, step: 0.5) {
                        LabeledContent("目标体重", value: SetmioFormat.kg(goalWeight))
                    }
                }
            } header: {
                Text("基本档案")
            } footer: {
                Text("这些信息只保存在本机，用于估算能量消耗和个性化基线，不会上传。")
            }
            Section {
                Button("下一步") { step = .health }
                    .buttonStyle(.setmioPrimary)
            }
        }
    }

    private var title: String {
        switch step {
        case .profile: "欢迎使用 Setmio"
        case .health: "连接「健康」"
        case .program: "选择训练模板"
        }
    }

    // MARK: Step 2 — HealthKit

    private var healthForm: some View {
        Form {
            Section {
                LabeledContent("读取", value: kindNames(HealthTypes.mvpReadKinds))
                LabeledContent("写入", value: kindNames(HealthTypes.mvpShareKinds))
            } header: {
                Text("Setmio 会访问")
            } footer: {
                Text("读取用于计算每日准备度；写入只包含你在 Setmio 里完成的力量训练和强度评分。数据只留在本机。以后可在「健康」App → 共享 → App 中修改。")
            }
            if let healthNote {
                Section { Text(healthNote).font(SetmioTokens.Typography.footnote).foregroundStyle(.secondary) }
            }
            Section {
                Button {
                    Task {
                        isWorking = true
                        healthNote = await env.requestHealthAuthorization()
                        isWorking = false
                        if healthNote == nil { step = .program }
                    }
                } label: {
                    if isWorking { ProgressView().tint(.white) } else { Text("授权访问「健康」") }
                }
                .buttonStyle(.setmioPrimary)
                .disabled(isWorking)
                Button("稍后在设置中授权") { step = .program }
                    .disabled(isWorking)
            }
        }
    }

    private func kindNames(_ kinds: Set<HealthMetricKind>) -> String {
        kinds.sorted { $0.rawValue < $1.rawValue }.map(\.nameZH).joined(separator: "、")
    }

    // MARK: Step 3 — program

    private var programForm: some View {
        Form {
            Section {
                ForEach(programs) { program in
                    Button {
                        selectedProgramID = program.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: SetmioTokens.Spacing.xxs) {
                                Text(program.nameZH)
                                Text("每周 \(program.daysPerWeek) 天 · \(program.mesocycleWeeks) 周（含减载周）")
                                    .font(SetmioTokens.Typography.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: selectedProgramID == program.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(SetmioTokens.Colors.accent)
                        }
                    }
                    .tint(.primary)
                }
            } header: {
                Text("训练模板")
            } footer: {
                Text("第一次训练时请按感觉选重量；之后每个动作的重量和次数由渐进规则根据你的记录自动调整。")
            }
            if let error {
                Section { Text(error).foregroundStyle(SetmioTokens.Colors.negative) }
            }
            Section {
                Button {
                    Task { await finish() }
                } label: {
                    if isWorking { ProgressView().tint(.white) } else { Text("生成训练周期") }
                }
                .buttonStyle(.setmioPrimary)
                .disabled(selectedProgramID == nil || isWorking)
                Button("返回上一步") { step = .health }
                    .disabled(isWorking)
            }
        }
    }

    // MARK: Actions

    private func loadPrograms() async {
        guard programs.isEmpty else { return }
        // The library is seeded in bootstrap(); this view can appear a moment before it finishes.
        for _ in 0..<20 {
            if let loaded = try? await env.store.programs(), !loaded.isEmpty {
                programs = loaded
                selectedProgramID = selectedProgramID ?? loaded.first?.id
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        error = "没有找到训练模板。"
    }

    private func finish() async {
        guard let program = programs.first(where: { $0.id == selectedProgramID }) else { return }
        isWorking = true
        defer { isWorking = false }
        let profile = UserProfile(
            sex: sex,
            heightCm: heightCm,
            birthDate: DayKey(birthDate, calendar: env.calendar),
            goalWeight: hasGoalWeight ? goalWeight : nil
        )
        if let message = await env.completeOnboarding(profile: profile, program: program) {
            error = message
        }
    }
}
