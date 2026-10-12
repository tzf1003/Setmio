import Foundation

/// Languages the catalogue carries exercise text in. `en` is the source text and has no table of its own.
///
/// Adding a language is one case here (raw value = its tag) plus `Resources/<tag>.json` in the upstream
/// `{ "<id>": { "name", "description", "instructions" } }` shape. `ExerciseCatalogue.loadBundled()` throws if a
/// non-English table is missing, so a half-added language fails at load time rather than showing English silently.
public enum CatalogueLanguage: String, Sendable, Codable, CaseIterable, Hashable {
    case en
    case zh

    /// Resource name (without extension) of this language's translation table, or nil for the source language.
    var translationResource: String? {
        self == .en ? nil : rawValue
    }
}
