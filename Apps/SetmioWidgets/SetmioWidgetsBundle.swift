import SwiftUI
import WidgetKit

/// Widget extension entry point. Only the rest-timer Live Activity ships in the MVP (方案.md §7.7: 骨架先建).
@main
struct SetmioWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RestTimerLiveActivity()
    }
}
