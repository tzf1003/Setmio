import SwiftUI
import SetmioUI

/// Open-source notices for the exercise library and the body map. The full texts ship in the repository:
/// Packages/SetmioCatalogue/NOTICE.md and Packages/SetmioCatalogue/LICENSE (AGPL-3.0).
struct LicensesView: View {
    /// Where the corresponding source of the AGPL-licensed data can be obtained.
    static let sourceURL = "https://github.com/tzf1003/Setmio"

    var body: some View {
        List {
            Section("动作库数据") {
                Text("动作的名称、肌群、说明和步骤来自 openGym（github.com/DuarteSantos8/openGym），版权 © 2026 Duarte Santos，采用 GNU AGPL-3.0 许可。其中 1,324 条最早来自 ExerciseDB v1（AscendAPI），经 hasaneyldrm/exercises-dataset 以 MIT 许可提供。")
                Text("这部分数据在 Setmio 中同样按 AGPL-3.0 提供，完整对应源代码见：\n\(Self.sourceURL)")
                    .textSelection(.enabled)
            }
            Section("中文翻译") {
                Text("中文名称覆盖全部动作，中文步骤只覆盖约 1,324 条，其余显示英文。上游没有说明中文是如何产生的，这些中文文字未经人工审校，可能有不准确之处。")
            }
            Section("人体图") {
                Text("人体肌肉图使用 MuscleMap（github.com/melihcolpan/MuscleMap），版权 © 2026 Melih Colpan，MIT 许可。")
            }
            Section("没有包含的内容") {
                Text("动作的图片和动画属于 Gym visual（gymvisual.com），未获得在本 App 中使用的授权，因此没有包含。")
            }
        }
        .navigationTitle("开源许可")
        .navigationBarTitleDisplayMode(.inline)
    }
}
