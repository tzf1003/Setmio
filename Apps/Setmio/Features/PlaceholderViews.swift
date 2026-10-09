import SwiftUI
import SetmioUI

/// V1 placeholders (方案.md §8 阶段 2): nutrition logging and GLP-1 tracking arrive after the MVP.

struct NutritionView: View {
    var body: some View {
        NavigationStack {
            EmptyState(
                text: "营养记录即将推出",
                systemImage: "fork.knife",
                detail: "V1 将加入自适应 TDEE、体重趋势、手输与拍照识别饮食记录。"
            )
            .navigationTitle("营养")
        }
    }
}

struct MedicationView: View {
    var body: some View {
        NavigationStack {
            EmptyState(
                text: "用药记录即将推出",
                systemImage: "syringe",
                detail: "V1 将加入减重针剂记录、库存与提醒，并按说明书阶梯校验剂量。任何剂量调整请与医生讨论。"
            )
            .navigationTitle("用药")
        }
    }
}
