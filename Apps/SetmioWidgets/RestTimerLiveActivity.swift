import SwiftUI
import WidgetKit
import ActivityKit
import SetmioCore
import SetmioUI

/// Lock Screen / Dynamic Island rendering of `RestTimerActivityAttributes` (declared in SetmioUI so the app and
/// this extension share one type). While running, `Text(timerInterval:countsDown:)` counts down on its own;
/// paused shows the frozen remainder. Buttons (pause / +30 s / skip) are AppIntents that go via the app to the watch.
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
                    VStack(spacing: SetmioTokens.Spacing.xs) {
                        if let next = context.state.nextTarget {
                            Text(next)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        RestControls(isPaused: context.state.isPaused)
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
            VStack(alignment: .trailing, spacing: SetmioTokens.Spacing.xs) {
                TimerText(state: context.state)
                    .font(SetmioTokens.Typography.largeNumber)
                    .foregroundStyle(SetmioTokens.Colors.accent)
                    .frame(minWidth: 96, alignment: .trailing)
                RestControls(isPaused: context.state.isPaused)
            }
        }
        .padding(SetmioTokens.Spacing.lg)
    }
}

/// Pause / resume, +30 s and skip. Each button is a `LiveActivityIntent` that runs in the app, which forwards the
/// command to the watch (the owner of the timer).
private struct RestControls: View {
    let isPaused: Bool

    var body: some View {
        HStack(spacing: SetmioTokens.Spacing.sm) {
            if isPaused {
                Button(intent: ResumeRestIntent()) { Label("继续", systemImage: "play.fill") }
            } else {
                Button(intent: PauseRestIntent()) { Label("暂停", systemImage: "pause.fill") }
            }
            Button(intent: AddThirtySecondsIntent()) { Label("+30s", systemImage: "plus") }
            Button(intent: SkipRestIntent()) { Label("跳过", systemImage: "forward.end.fill") }
        }
        .font(.caption)
        .buttonStyle(.bordered)
        .labelStyle(.titleAndIcon)
        .tint(SetmioTokens.Colors.accent)
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
