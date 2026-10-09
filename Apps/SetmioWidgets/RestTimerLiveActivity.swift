import SwiftUI
import WidgetKit
import ActivityKit
import SetmioCore
import SetmioUI

/// Lock Screen / Dynamic Island rendering of `RestTimerActivityAttributes` (declared in SetmioUI so the app and
/// this extension share one type). While running, `Text(timerInterval:countsDown:)` counts down on its own;
/// paused shows the frozen remainder. Buttons (pause / skip via AppIntent → mirroring) are V2.
struct RestTimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RestTimerActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(SetmioTokens.Colors.surface)
                .activitySystemActionForegroundColor(SetmioTokens.Colors.accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: SetmioTokens.Spacing.xxs) {
                        Text(context.attributes.exerciseName)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.state.setLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimerText(state: context.state)
                        .font(SetmioTokens.Typography.metricValue)
                        .frame(minWidth: 72, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let next = context.state.nextTarget {
                        Text(next)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: "timer")
                    .foregroundStyle(SetmioTokens.Colors.accent)
            } compactTrailing: {
                TimerText(state: context.state)
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: 48)
            } minimal: {
                Image(systemName: "timer")
                    .foregroundStyle(SetmioTokens.Colors.accent)
            }
            .keylineTint(SetmioTokens.Colors.accent)
        }
    }
}

// MARK: - Views

private struct LockScreenView: View {
    let context: ActivityViewContext<RestTimerActivityAttributes>

    var body: some View {
        HStack(alignment: .center, spacing: SetmioTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: SetmioTokens.Spacing.xxs) {
                Text(context.state.isPaused ? "休息（已暂停）" : "休息中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(context.attributes.exerciseName)
                    .font(.headline)
                    .lineLimit(1)
                Text(context.state.setLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let next = context.state.nextTarget {
                    Text(next)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: SetmioTokens.Spacing.sm)
            TimerText(state: context.state)
                .font(SetmioTokens.Typography.largeNumber)
                .foregroundStyle(SetmioTokens.Colors.accent)
                .frame(minWidth: 96, alignment: .trailing)
        }
        .padding(SetmioTokens.Spacing.lg)
    }
}

/// Live countdown while running; a static remaining string when paused.
private struct TimerText: View {
    let state: RestTimerActivityAttributes.ContentState

    var body: some View {
        if state.isPaused {
            Text(SetmioFormat.duration(state.remaining()))
                .monospacedDigit()
        } else {
            Text(timerInterval: state.timerRange(), countsDown: true, showsHours: false)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
    }
}
