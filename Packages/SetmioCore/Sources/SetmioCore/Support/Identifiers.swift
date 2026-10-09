import Foundation

/// Phantom-typed identifier: an `ID<Exercise>` cannot be passed where an `ID<LoggedSet>` is expected.
/// Encodes as a bare UUID string.
///
/// Pitfall: inside any type that conforms to `Identifiable` (or SwiftData's `PersistentModel`), the unqualified name
/// `ID` resolves to `Self.ID`, so a property like `var exerciseID: ID<Exercise>` fails to compile. Write
/// `SetmioCore.ID<Exercise>` there (Core's own models do this), or store the `rawValue` UUID.
public struct ID<Tag>: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = uuid
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue.uuidString }
}

// MARK: - Units (documentation-only aliases; all values are plain Doubles)

public typealias Kilograms = Double
public typealias Kilocalories = Double
public typealias Milliseconds = Double
public typealias Milligrams = Double
public typealias Grams = Double
public typealias Minutes = Double
public typealias BeatsPerMinute = Double
