import SwiftUI
import SetmioCatalogue
import SetmioUI
#if canImport(MuscleMap)
import MuscleMap
#endif

/// The exercise library: search, tap a muscle on the body map, filter by equipment, browse the results.
/// Reached from the 训练 tab. Reference only: it does not change plans or logged data.
struct ExerciseLibraryView: View {
    @State private var model = LibraryModel()

    var body: some View {
        List {
            Section {
                bodyMap
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if !model.selectedTargets.isEmpty {
                Section("肌群") { targetChips }
            }
            Section("器械") { equipmentChips }
            Section {
                if let error = model.loadError {
                    Text(error).foregroundStyle(SetmioTokens.Colors.negative)
                } else if model.catalogue == nil {
                    ProgressView("正在载入动作库…")
                } else if model.results.isEmpty {
                    Text("没有符合条件的动作。").foregroundStyle(.secondary)
                } else {
                    ForEach(model.results) { exercise in
                        NavigationLink {
                            ExerciseDetailView(exercise: exercise, language: model.language)
                        } label: {
                            ExerciseRow(exercise: exercise, language: model.language)
                        }
                    }
                }
            } header: {
                Text(resultsHeader)
            } footer: {
                Text("动作文字来自 openGym（AGPL-3.0）。中文名称覆盖全部动作，中文步骤只覆盖约四分之一，其余显示英文。详见「设置 → 开源许可」。")
            }
        }
        .navigationTitle("动作库")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.text, prompt: "搜索动作名称（中文或英文）")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("清除") { model.clearFilters() }
                    .disabled(!model.hasFilters)
            }
        }
        .task { await model.loadIfNeeded() }
    }

    private var resultsHeader: String {
        guard model.catalogue != nil else { return "动作" }
        return model.hasFilters ? "符合的动作 \(model.results.count) / \(model.totalCount)" : "全部动作 \(model.totalCount)"
    }

    // MARK: Body map

    @ViewBuilder
    private var bodyMap: some View {
        #if canImport(MuscleMap)
        MuscleBodyMapView(
            selected: LibraryMuscleMapping.muscles(for: model.selectedTargets),
            onSelect: { muscle in model.toggle(targets: LibraryMuscleMapping.targets(for: muscle)) }
        )
        #else
        EmptyView()
        #endif
    }

    // MARK: Chips

    private var targetChips: some View {
        ChipFlow {
            ForEach(TargetMuscle.allCases.filter { model.selectedTargets.contains($0) }, id: \.self) { target in
                FilterChip(title: target.nameZH, count: model.targetCounts[target], isOn: true) { model.toggle(target) }
            }
        }
    }

    private var equipmentChips: some View {
        // Chips with matching exercises first, largest counts first; empty ones stay reachable but dimmed.
        let kinds = EquipmentKind.allCases.sorted { lhs, rhs in
            let l = model.equipmentCounts[lhs] ?? 0, r = model.equipmentCounts[rhs] ?? 0
            return l != r ? l > r : lhs.nameZH < rhs.nameZH
        }
        return ChipFlow {
            ForEach(kinds, id: \.self) { kind in
                FilterChip(title: kind.nameZH, count: model.equipmentCounts[kind], isOn: model.selectedEquipment.contains(kind)) {
                    model.toggle(kind)
                }
            }
        }
    }
}

// MARK: - Rows and chips

private struct ExerciseRow: View {
    let exercise: CatalogueExercise
    let language: CatalogueLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: SetmioTokens.Spacing.xxs) {
            Text(exercise.localizedName(for: language).capitalizedFirst)
                .font(SetmioTokens.Typography.body.weight(.medium))
            Text([exercise.target?.nameZH, exercise.equipment?.nameZH].compactMap { $0 }.joined(separator: " · "))
                .font(SetmioTokens.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct FilterChip: View {
    let title: String
    let count: Int?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SetmioTokens.Spacing.xs) {
                Text(title)
                if let count { Text("\(count)").foregroundStyle(.secondary) }
            }
            .font(SetmioTokens.Typography.caption)
            .padding(.horizontal, SetmioTokens.Spacing.md)
            .padding(.vertical, SetmioTokens.Spacing.xs)
            .background(isOn ? SetmioTokens.Colors.accent.opacity(0.2) : SetmioTokens.Colors.surfaceElevated, in: Capsule())
            .overlay(Capsule().stroke(isOn ? SetmioTokens.Colors.accent : .clear, lineWidth: 1))
            .opacity(count == 0 && !isOn ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Wrapping row of chips.
private struct ChipFlow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        FlowLayout(spacing: SetmioTokens.Spacing.sm) { content }
            .padding(.vertical, SetmioTokens.Spacing.xs)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in layout.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxWidth = max(maxWidth, x - spacing)
        }
        return (CGSize(width: maxWidth, height: y + rowHeight), origins)
    }
}

extension String {
    /// "barbell bench press" -> "Barbell bench press". Chinese text has no case, so it passes through unchanged.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
