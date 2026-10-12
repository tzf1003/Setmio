import SwiftUI
import SetmioCore
import SetmioUI

/// 设置 → 测试数据. Deletes only the sessions tagged as test data, locally and in 「健康」, and can tag every
/// existing session once. Nothing here touches an untagged session.
struct TestDataSection: View {
    @Environment(AppEnvironment.self) private var env

    @State private var testMode = false
    @State private var preview: TestDataPreview?
    @State private var hasActiveWorkout = false
    @State private var history: HistorySummary?
    @State private var showDeleteConfirmation = false
    @State private var showMarkAllConfirmation = false
    @State private var reportToShow: TestDataDeletionReport?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var notice: String?

    var body: some View {
        Section {
            Toggle("测试模式（新训练自动标记为测试，不参与计划）", isOn: Binding(
                get: { testMode },
                set: { on in Task { await setTestMode(on) } }
            ))
            Text("测试训练：\(preview?.sessionCount ?? 0) 条 · \(preview?.setCount ?? 0) 组")
            if hasActiveWorkout {
                Text("有进行中的训练。结束后才能删除测试训练。")
                    .font(SetmioTokens.Typography.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("删除测试训练…", role: .destructive) {
                Task { await prepareDeletion() }
            }
            .disabled(hasActiveWorkout || isWorking || (preview?.sessionCount ?? 0) == 0)
            Button("把现有所有训练标记为测试…", role: .destructive) {
                Task { await prepareMarkAll() }
            }
            .disabled(isWorking)
            if let notice {
                Text(notice).font(SetmioTokens.Typography.footnote).foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).font(SetmioTokens.Typography.footnote).foregroundStyle(SetmioTokens.Colors.negative)
            }
        } header: {
            Text("测试数据")
        } footer: {
            Text("删除只作用于标记为测试的训练，不影响未标记的训练。「健康」中只删除 Setmio 写入的训练；系统拒绝删除的，需在「健康」App 中手动删除。")
        }
        .task { await refresh() }
        .onChange(of: env.testDataRevision) { _, _ in Task { await refresh() } }
        .onChange(of: env.isWatchMirroring) { _, _ in Task { await refresh() } }
        .confirmationDialog("删除测试训练？", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                Task { await deleteTestData() }
            }
        } message: {
            Text(deletionMessage)
        }
        .confirmationDialog("把现有所有训练标记为测试？", isPresented: $showMarkAllConfirmation, titleVisibility: .visible) {
            Button("全部标记为测试", role: .destructive) {
                Task { await markAllAsTest() }
            }
        } message: {
            Text(markAllMessage)
        }
        .alert("删除完成", isPresented: Binding(
            get: { reportToShow != nil },
            set: { if !$0 { reportToShow = nil } }
        ), presenting: reportToShow) { _ in
            Button("好") {}
        } message: { report in
            Text(Self.reportMessage(report))
        }
    }

    // MARK: Copy

    private var deletionMessage: String {
        let count = preview?.sessionCount ?? 0
        let sets = preview?.setCount ?? 0
        let health = preview?.healthWorkoutCount ?? 0
        return "将删除 \(count) 条测试训练、\(sets) 组，以及 Setmio 写入「健康」的对应训练（\(health) 条）。不影响未标记的训练。无法撤销。"
    }

    private var markAllMessage: String {
        guard let history, history.sessionCount > 0, let oldest = history.oldest, let newest = history.newest else {
            return "现有没有训练记录。"
        }
        let style = Date.FormatStyle.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))
        return "将把现有 \(history.sessionCount) 条训练（\(oldest.formatted(style)) 至 \(newest.formatted(style))）标记为测试。标记后它们不参与计划，并可用「删除测试训练」删除。这一步本身不删除任何数据。"
    }

    private static func reportMessage(_ report: TestDataDeletionReport) -> String {
        guard report.sessionsDeleted > 0 || report.healthDeleted > 0 || report.healthFailed > 0 else {
            return "没有需要删除的测试训练。"
        }
        var lines = ["已删除 \(report.sessionsDeleted) 条训练、\(report.setsDeleted) 组。"]
        if report.healthDeleted > 0 {
            lines.append("已从「健康」删除 \(report.healthDeleted) 条训练。")
        }
        if report.healthFailed > 0 {
            lines.append("有 \(report.healthFailed) 条「健康」训练没有删除成功（例如手表记录，系统不允许本 App 删除）。请打开「健康」App，手动删除这些训练。")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Actions

    private func refresh() async {
        testMode = await env.testData.testMode()
        do {
            preview = try await env.testDataCleaner.preview()
            hasActiveWorkout = try await env.testDataCleaner.hasActiveWorkout(watchMirroring: env.isWatchMirroring)
            errorMessage = nil
        } catch {
            errorMessage = "无法读取测试训练：\(error.localizedDescription)"
        }
    }

    private func setTestMode(_ on: Bool) async {
        do {
            try await env.testData.setTestMode(on)
            testMode = on
        } catch {
            errorMessage = "无法保存测试模式：\(error.localizedDescription)"
        }
    }

    private func prepareDeletion() async {
        await refresh()
        if (preview?.sessionCount ?? 0) > 0 {
            showDeleteConfirmation = true
        }
    }

    private func deleteTestData() async {
        isWorking = true
        defer { isWorking = false }
        do {
            reportToShow = try await env.testDataCleaner.deleteAll(watchMirroring: env.isWatchMirroring)
            errorMessage = nil
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
        }
        // Runs after a partial failure too, so the Training tab never shows sessions that were already removed.
        await env.testDataDidChange()
        await refresh()
    }

    private func prepareMarkAll() async {
        history = try? await env.testDataCleaner.history()
        guard let history, history.sessionCount > 0 else {
            notice = "现有没有训练记录。"
            return
        }
        notice = nil
        showMarkAllConfirmation = true
    }

    private func markAllAsTest() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let count = try await env.testDataCleaner.markAllExistingAsTest()
            notice = "已把 \(count) 条训练标记为测试。"
            errorMessage = nil
        } catch {
            errorMessage = "标记失败：\(error.localizedDescription)"
        }
        await env.testDataDidChange()
        await refresh()
    }
}
