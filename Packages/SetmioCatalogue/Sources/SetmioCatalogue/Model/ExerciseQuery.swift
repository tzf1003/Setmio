import Foundation

/// A search and filter request. A nil or blank `text` and empty sets mean "no constraint".
///
/// Within one facet the selected values are OR-ed ("chest or back"). Facets, and the text, are AND-ed together.
/// `language` picks which translated name is matched and used for ordering. English names always match too,
/// so a Chinese query still finds an exercise whose English name contains the same word.
public struct ExerciseQuery: Sendable, Codable, Hashable {
    public var text: String?
    public var bodyParts: Set<BodyPartCategory>
    public var targets: Set<TargetMuscle>
    public var equipment: Set<EquipmentKind>
    public var language: CatalogueLanguage

    public init(
        text: String? = nil,
        bodyParts: Set<BodyPartCategory> = [],
        targets: Set<TargetMuscle> = [],
        equipment: Set<EquipmentKind> = [],
        language: CatalogueLanguage = .en
    ) {
        self.text = text
        self.bodyParts = bodyParts
        self.targets = targets
        self.equipment = equipment
        self.language = language
    }
}
