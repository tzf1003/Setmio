import SwiftUI
import SetmioCore
import SetmioHealth
import SetmioAI
import SetmioUI
#if canImport(HealthKit)
import HealthKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Settings: HealthKit authorization, re-import, demo data, proxy registration, profile fields.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    /// Suppresses profile saves while the draft is being filled from the stored profile.
    @State private var isProfileLoaded = false
    @State private var authorizationNote = ""
    @State private var shareStatuses: [(kind: HealthMetricKind, status: String)] = []
    @State private var proxyURL = ""
    @State private var inviteCode = ""
    @State private var proxyMessage: String?
    @State private var isRegistering = false

    // Profile draft (saved on every change).
    @State private var sex: BiologicalSex = .male
    @State private var heightCm: Double = 170
    @State private var birthDate = Date(timeIntervalSince1970: 631_152_000) // 1990-01-01
    @State private var hasGoalWeight = false
    @State private var goalWeight: Double = 70
    @State private var proteinChoice: ProteinStandardChoice = .usAdvisory
    @State private var glp1Mode = false

    var body: some View {
        NavigationStack {
            Form {
                healthSection
                dataSection
                proxySection
                profileSection
                aboutSection
            }
            .navigationTitle("设置")
            .task { await loadState() }
        }
    }

    // MARK: HealthKit

    private var healthSection: some View {
        Section {
            #if canImport(HealthKit)
            LabeledContent("健康数据", value: HKHealthStore.isHealthDataAvailable() ? "可用" : "此设备不可用")
            #endif
            if !authorizationNote.isEmpty {
                Text(authorizationNote).font(SetmioTokens.Typography.footnote).foregroundStyle(.secondary)
            }
            ForEach(shareStatuses, id: \.kind) { row in
                LabeledContent(row.kind.nameZH, value: row.status)
            }
            Button("请求授权") {
                Task { await requestAuthorization() }
            }
        } header: {
            Text("HealthKit")
        } footer: {
            Text("iOS 不会透露读取权限是否被拒绝；若某项数据一直为空，请到「健康」App → 共享 → Setmio 检查。")
        }
    }

    private var dataSection: some View {
        Section("数据") {
            Toggle("使用演示数据（60 天）", isOn: Binding(
                get: { env.settings.demoDataEnabled },
                set: { enabled in Task { await env.useDemoData(enabled) } }
            ))
            Button("重新导入健康数据") {
                Task { await env.syncService.resetAndReimport(); await env.refreshTodayPlan() }
            }
            .disabled(env.syncService.isSyncing)
            if env.syncService.isSyncing, let progress = env.syncService.importProgress {
                ProgressView(value: progress.fractionOfKindsCompleted) {
                    Text("导入 \(progress.kind.nameZH)（\(progress.kindIndex + 1)/\(progress.kindCount)）· \(progress.importedSoFar) 条")
                        .font(SetmioTokens.Typography.footnote)
                }
            }
            if let report = env.syncService.lastReport {
                LabeledContent("上次导入", value: "\(report.totalImported) 条 · \(report.succeeded ? "成功" : "\(report.failedKinds.count) 类失败")")
            }
            if let at = env.syncService.lastSyncedAt {
                LabeledContent("上次同步", value: SetmioFormat.date(at, calendar: env.calendar) + " " + SetmioFormat.clock(at, calendar: env.calendar))
            }
            LabeledContent("手表 App", value: env.connectivityBridge.isWatchAppInstalled ? "已安装" : "未检测到")
        }
    }

    // MARK: Proxy

    private var proxySection: some View {
        Section {
            TextField("代理地址，如 https://setmio-proxy.example.workers.dev", text: $proxyURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .onSubmit { env.proxyBaseURLString = proxyURL }
            TextField("邀请码", text: $inviteCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                Task { await register() }
            } label: {
                if isRegistering { ProgressView() } else { Text("注册此设备") }
            }
            .disabled(isRegistering || inviteCode.isEmpty || proxyURL.isEmpty)
            LabeledContent("设备状态", value: env.proxyClient?.isRegistered == true ? "已注册" : "未注册")
            if let proxyMessage {
                Text(proxyMessage).font(SetmioTokens.Typography.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("AI 代理")
        } footer: {
            Text("设备令牌保存在钥匙串；App 不持有任何模型密钥。V1 的拍照识菜、周报与教练对话都经由代理。")
        }
    }

    // MARK: Profile

    private var profileSection: some View {
        Section("个人档案") {
            Picker("性别", selection: $sex) {
                ForEach(BiologicalSex.allCases, id: \.self) { Text($0.nameZH).tag($0) }
            }
            Stepper(value: $heightCm, in: 120...230, step: 1) {
                LabeledContent("身高", value: "\(Int(heightCm)) cm")
            }
            DatePicker("出生日期", selection: $birthDate, displayedComponents: .date)
            Toggle("设定目标体重", isOn: $hasGoalWeight)
            if hasGoalWeight {
                Stepper(value: $goalWeight, in: 30...200, step: 0.5) {
                    LabeledContent("目标体重", value: SetmioFormat.kg(goalWeight))
                }
            }
            Picker("蛋白质标准", selection: $proteinChoice) {
                ForEach(ProteinStandardChoice.allCases) { Text($0.nameZH).tag($0) }
            }
            Toggle("GLP-1 模式（保肌规则）", isOn: $glp1Mode)
        }
        .onChange(of: sex) { saveProfile() }
        .onChange(of: heightCm) { saveProfile() }
        .onChange(of: birthDate) { saveProfile() }
        .onChange(of: hasGoalWeight) { saveProfile() }
        .onChange(of: goalWeight) { saveProfile() }
        .onChange(of: proteinChoice) { saveProfile() }
        .onChange(of: glp1Mode) { saveProfile() }
    }

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            Text("健康衍生数据只保存在本机，不进入 iCloud。本 App 不提供医疗建议；用药相关内容请与医生讨论。")
                .font(SetmioTokens.Typography.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private func loadState() async {
        proxyURL = env.proxyBaseURLString
        if let profile = env.profile {
            sex = profile.sex
            heightCm = profile.heightCm
            birthDate = profile.birthDate.startOfDay(calendar: env.calendar)
            hasGoalWeight = profile.goalWeight != nil
            goalWeight = profile.goalWeight ?? goalWeight
            proteinChoice = ProteinStandardChoice(profile.proteinStandard)
            glp1Mode = profile.glp1Mode
        }
        isProfileLoaded = true
        await refreshAuthorization()
    }

    private func refreshAuthorization() async {
        #if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable() else {
            authorizationNote = "此设备没有健康数据。"
            return
        }
        let authorizer = HealthKitAuthorizer(store: env.healthStore)
        do {
            let status = try await authorizer.requestStatus(read: HealthTypes.mvpRead, share: HealthTypes.mvpShare)
            switch status {
            case .shouldRequest: authorizationNote = "尚未请求授权。"
            case .unnecessary: authorizationNote = "授权已处理（读取权限由系统保密）。"
            case .unknown: authorizationNote = "授权状态未知。"
            @unknown default: authorizationNote = "授权状态未知。"
            }
        } catch {
            authorizationNote = "无法查询授权状态：\(error.localizedDescription)"
        }
        shareStatuses = HealthTypes.mvpShareKinds.sorted { $0.rawValue < $1.rawValue }.map { kind in
            let status: String
            if let type = HealthTypes.objectType(for: kind) {
                switch authorizer.shareStatus(for: type) {
                case .sharingAuthorized: status = "写入：已允许"
                case .sharingDenied: status = "写入：已拒绝"
                case .notDetermined: status = "写入：未决定"
                @unknown default: status = "写入：未知"
                }
            } else {
                status = "—"
            }
            return (kind: kind, status: status)
        }
        #else
        authorizationNote = "此平台没有 HealthKit。"
        #endif
    }

    private func requestAuthorization() async {
        if let message = await env.requestHealthAuthorization() {
            authorizationNote = message
        }
        await refreshAuthorization()
    }

    private func register() async {
        env.proxyBaseURLString = proxyURL
        guard let client = env.proxyClient else {
            proxyMessage = "代理地址无效。"
            return
        }
        isRegistering = true
        defer { isRegistering = false }
        do {
            #if canImport(UIKit)
            let deviceName = UIDevice.current.name
            #else
            let deviceName = "iPhone"
            #endif
            let response = try await client.register(inviteCode: inviteCode, deviceName: deviceName, platform: "ios")
            proxyMessage = "注册成功，设备 ID \(response.deviceId)。"
            inviteCode = ""
        } catch let error as LLMError {
            proxyMessage = error.messageZH
        } catch {
            proxyMessage = "注册失败：\(error.localizedDescription)"
        }
    }

    private func saveProfile() {
        guard isProfileLoaded else { return }
        let profile = UserProfile(
            sex: sex,
            heightCm: heightCm,
            birthDate: DayKey(birthDate, calendar: env.calendar),
            goalWeight: hasGoalWeight ? goalWeight : nil,
            proteinStandard: proteinChoice.standard,
            activityFactor: env.profile?.activityFactor ?? 1.375,
            glp1Mode: glp1Mode
        )
        guard profile != env.profile else { return }
        Task { await env.saveProfile(profile) }
    }
}
