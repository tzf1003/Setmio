import SwiftUI
import SwiftData

/// Composition root. `AppEnvironment` is built synchronously in `init` because the mirroring start handler
/// (`MirroringSessionReceiver`) must be registered before the system hands us a watch session — the app may be
/// launched in the background for exactly that purpose, with no UI at all (方案.md §7.7).
@main
struct SetmioApp: App {
    @State private var environment: AppEnvironment

    init() {
        let env = AppEnvironment()
        _environment = State(initialValue: env)
        // Background delivery observers are registered once per process; the task also seeds the library,
        // loads settings/profile and runs the first sync.
        Task { await env.bootstrap() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .environment(environment)
        .modelContainer(environment.container)
    }
}
