import Foundation

/// Reads the JSON tables under `Resources/`. Looks in the `Resources` subdirectory first, then at the bundle root,
/// because the layout differs between platforms. Same lookup order as SetmioCore.
enum CatalogueResources {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: name, withExtension: "json") else {
            throw CatalogueError.resourceMissing(name)
        }
        return try Data(contentsOf: url)
    }

    static func decode<Value: Decodable>(_ name: String) throws -> Value {
        try JSONDecoder().decode(Value.self, from: data(name))
    }
}
