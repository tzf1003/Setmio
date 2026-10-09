import SwiftUI

/// Independent watch app. On launch it recovers a session HealthKit kept alive across a crash
/// (`WorkoutSessionManager.recoverIfNeeded`) and replays the unacked journal (方案.md §7.7).
@main
struct SetmioWatchApp: App {
    @State private var environment = WatchEnvironment()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(environment)
                .task { await environment.launch() }
        }
    }
}

/// Start screen until a session is active, then the live session.
struct WatchRootView: View {
    @Environment(WatchEnvironment.self) private var env

    var body: some View {
        if env.isSessionActive {
            ActiveSessionView()
        } else {
            StartSessionView()
        }
    }
}
