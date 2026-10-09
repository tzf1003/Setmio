import SwiftUI
import SetmioCore

@main
struct SetmioApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var plans: [WorkoutPlan] = []

    var body: some View {
        NavigationStack {
            List(plans) { plan in
                Text(plan.name)
            }
            .overlay { if plans.isEmpty { Text("还没有训练计划") .foregroundStyle(.secondary) } }
            .navigationTitle("Setmio")
            .toolbar {
                Button("新建", systemImage: "plus") {
                    plans.append(WorkoutPlan(name: "计划 \(plans.count + 1)"))
                }
            }
        }
    }
}
