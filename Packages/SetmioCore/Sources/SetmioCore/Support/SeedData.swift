import Foundation

/// Bundled seed content (exercise library, program templates). Loaded once at first launch and persisted.
public enum SeedData {
    public enum LoadError: Error, Sendable { case resourceMissing(String) }

    public static func exercises() throws -> [Exercise] {
        try load("exercises_seed")
    }

    public static func programs() throws -> [ProgramTemplate] {
        try load("programs_seed")
    }

    private static func load<T: Decodable>(_ name: String) throws -> T {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: name, withExtension: "json") else {
            throw LoadError.resourceMissing(name)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
