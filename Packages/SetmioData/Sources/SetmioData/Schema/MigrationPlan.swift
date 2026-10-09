#if canImport(SwiftData)
import Foundation
import SwiftData

/// Ordered list of schema versions and the stages between them.
///
/// V1 has no predecessor, so `stages` is empty. When V2 arrives: append `SetmioSchemaV2.self` to `schemas`,
/// add `MigrationStage.lightweight(fromVersion: SetmioSchemaV1.self, toVersion: SetmioSchemaV2.self)` (or a
/// `.custom` stage with `willMigrate`/`didMigrate` closures for data fixes), and switch
/// `SetmioCurrentSchema` to V2.
public enum SetmioMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [SetmioSchemaV1.self]
    }

    public static var stages: [MigrationStage] {
        []
    }
}
#endif
