import Foundation
import Observation
import SetmioCatalogue

/// State behind the exercise library: the loaded catalogue, the active filters, and the result list.
///
/// Loading decodes about 4 MB of JSON, so it runs off the main actor; searching afterwards is a sub-millisecond scan
/// (measured by the package), so it runs on the main actor on every change.
@MainActor
@Observable
final class LibraryModel {
    private(set) var catalogue: ExerciseCatalogue?
    private(set) var loadError: String?
    private(set) var results: [CatalogueExercise] = []
    private(set) var targetCounts: [TargetMuscle: Int] = [:]
    private(set) var equipmentCounts: [EquipmentKind: Int] = [:]

    var text = "" { didSet { refresh() } }
    var selectedTargets: Set<TargetMuscle> = [] { didSet { refresh() } }
    var selectedEquipment: Set<EquipmentKind> = [] { didSet { refresh() } }

    /// Chinese first; every field falls back to English where the Chinese table has nothing (see the data NOTICE).
    let language: CatalogueLanguage = .zh

    var hasFilters: Bool { !text.isEmpty || !selectedTargets.isEmpty || !selectedEquipment.isEmpty }
    var totalCount: Int { catalogue?.count ?? 0 }

    func loadIfNeeded() async {
        guard catalogue == nil else { return }
        do {
            catalogue = try await Self.loadOffMain()
            loadError = nil
            refresh()
        } catch {
            loadError = "无法载入动作库：\(error.localizedDescription)"
        }
    }

    func clearFilters() {
        text = ""
        selectedTargets = []
        selectedEquipment = []
    }

    func toggle(_ target: TargetMuscle) {
        if selectedTargets.contains(target) { selectedTargets.remove(target) } else { selectedTargets.insert(target) }
    }

    func toggle(_ equipment: EquipmentKind) {
        if selectedEquipment.contains(equipment) { selectedEquipment.remove(equipment) } else { selectedEquipment.insert(equipment) }
    }

    /// Applies a tap on the body map: toggles every target of the tapped region together (all selected -> clear them).
    func toggle(targets: Set<TargetMuscle>) {
        guard !targets.isEmpty else { return }
        if targets.isSubset(of: selectedTargets) {
            selectedTargets.subtract(targets)
        } else {
            selectedTargets.formUnion(targets)
        }
    }

    private var query: ExerciseQuery {
        ExerciseQuery(
            text: text.isEmpty ? nil : text,
            targets: selectedTargets,
            equipment: selectedEquipment,
            language: language
        )
    }

    private func refresh() {
        guard let catalogue else { return }
        let query = query
        results = catalogue.search(query)
        let facets = catalogue.facetCounts(for: query)
        targetCounts = facets.targets
        equipmentCounts = facets.equipment
    }

    @concurrent
    private static func loadOffMain() async throws -> ExerciseCatalogue {
        try ExerciseCatalogue.loadBundled()
    }
}
