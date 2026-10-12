import SwiftUI
import SetmioCatalogue
import SetmioUI

/// One exercise: name, what it trains, equipment, description and steps.
///
/// There is no animation or picture. The demonstrations in openGym belong to Gym visual and are not licensed for reuse
/// in this app, so the slot below says so instead of leaving a gap. Swap it for licensed or self-made media later.
struct ExerciseDetailView: View {
    let exercise: CatalogueExercise
    let language: CatalogueLanguage

    var body: some View {
        List {
            Section { mediaPlaceholder }
            Section("训练部位") {
                if let target = exercise.target { LabeledContent("主要肌群", value: target.nameZH) }
                if let bodyPart = exercise.bodyPart { LabeledContent("身体部位", value: bodyPart.nameZH) }
                if let equipment = exercise.equipment { LabeledContent("器械", value: equipment.nameZH) }
                if !exercise.secondaryMuscles.isEmpty {
                    LabeledContent("辅助肌群", value: exercise.secondaryMuscles.map { SecondaryMuscleNames.name($0, in: language) }.joined(separator: "、"))
                }
            }
            let description = exercise.localizedDescription(for: language)
            if !description.isEmpty {
                Section("说明") { Text(description) }
            }
            Section {
                ForEach(Array(exercise.localizedInstructions(for: language).enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: SetmioTokens.Spacing.sm) {
                        Text("\(index + 1)")
                            .font(SetmioTokens.Typography.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .trailing)
                        Text(step)
                    }
                }
            } header: {
                Text("动作要领")
            } footer: {
                if exercise.translations[language]?.instructions == nil {
                    Text("这个动作暂无中文步骤，显示英文原文。")
                }
            }
            Section {
                Text(sourceNote)
                    .font(SetmioTokens.Typography.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(exercise.localizedName(for: language).capitalizedFirst)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var mediaPlaceholder: some View {
        VStack(spacing: SetmioTokens.Spacing.sm) {
            Image(systemName: "figure.strengthtraining.traditional")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("暂无动作演示")
                .font(SetmioTokens.Typography.label)
            Text("原项目的动画由第三方授权，不能在本 App 中使用。")
                .font(SetmioTokens.Typography.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SetmioTokens.Spacing.lg)
    }

    private var sourceNote: String {
        switch exercise.source {
        case .exercisedb: "文字来源：ExerciseDB（MIT）经 hasaneyldrm/exercises-dataset，收入 openGym。"
        case .opengym: "文字来源：openGym 社区（AGPL-3.0）。"
        case .unknown: "文字来源：openGym。"
        }
    }
}
