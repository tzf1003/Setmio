import AppIntents
import Foundation

/// What a Live Activity button asks for. Mirrors `SetmioHealth.RestTimerCommand` (the widget extension does not
/// link SetmioHealth); the app maps one to the other.
enum RestTimerAction: String, Sendable, CaseIterable {
    case pause, resume, skip, add30
}

/// Hands button presses to the app. A `LiveActivityIntent` runs in the *app's* process (the system launches it in
/// the background if needed), so `AppEnvironment` installs the handler during `init`; in the widget extension the
/// handler is never set and never called.
@MainActor
enum RestTimerCommandCenter {
    static var handler: (@MainActor (RestTimerAction) async -> Void)?
}

struct PauseRestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "暂停休息"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await RestTimerCommandCenter.handler?(.pause)
        return .result()
    }
}

struct ResumeRestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "继续休息"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await RestTimerCommandCenter.handler?(.resume)
        return .result()
    }
}

struct SkipRestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "跳过休息"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await RestTimerCommandCenter.handler?(.skip)
        return .result()
    }
}

struct AddThirtySecondsIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "休息 +30 秒"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await RestTimerCommandCenter.handler?(.add30)
        return .result()
    }
}
