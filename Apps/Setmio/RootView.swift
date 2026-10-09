import SwiftUI

/// Five tabs per 方案.md §7.2: 今日 / 训练 / 营养 / 用药 / 设置. 营养 and 用药 are V1 placeholders.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        TabView {
            Tab("今日", systemImage: "sun.max") {
                TodayView()
            }
            Tab("训练", systemImage: "dumbbell") {
                TrainingView()
            }
            Tab("营养", systemImage: "fork.knife") {
                NutritionView()
            }
            Tab("用药", systemImage: "syringe") {
                MedicationView()
            }
            Tab("设置", systemImage: "gearshape") {
                SettingsView()
            }
        }
        .overlay(alignment: .top) {
            if let error = env.startupError {
                Text(error)
                    .font(.footnote)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.red.opacity(0.85), in: Rectangle())
                    .foregroundStyle(.white)
            }
        }
    }
}
