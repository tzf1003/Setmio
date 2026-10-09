import SwiftUI
import SetmioUI

/// Full-screen rest countdown. `TimelineView` redraws every second; the haptics at T−10 s and 0 are scheduled by
/// `WatchEnvironment` so they fire even when this view is not on screen.
struct RestTimerView: View {
    @Environment(WatchEnvironment.self) private var env

    var body: some View {
        if let timer = env.restTimer {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = timer.remaining(at: context.date)
                let fraction = timer.totalSeconds > 0 ? remaining / timer.totalSeconds : 0
                VStack(spacing: SetmioTokens.Spacing.sm) {
                    Text("休息")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ZStack {
                        Circle()
                            .stroke(SetmioTokens.Colors.accent.opacity(0.2), lineWidth: SetmioTokens.Stroke.gaugeCompact)
                        Circle()
                            .trim(from: 0, to: fraction)
                            .stroke(SetmioTokens.Colors.accent, style: StrokeStyle(lineWidth: SetmioTokens.Stroke.gaugeCompact, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text(SetmioFormat.duration(remaining))
                            .font(SetmioTokens.Typography.timer)
                            .minimumScaleFactor(0.5)
                            .foregroundStyle(remaining <= WatchEnvironment.warningLeadSeconds ? SetmioTokens.Colors.warning : .primary)
                    }
                    .frame(maxWidth: 110, maxHeight: 110)
                    Text("下一组 · \(timer.exerciseName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: SetmioTokens.Spacing.sm) {
                        Button("+30s") { env.extendRest(by: 30) }
                            .buttonStyle(.bordered)
                        Button("跳过") { env.skipRest() }
                            .buttonStyle(.borderedProminent)
                    }
                    .font(.footnote)
                }
                .padding(.horizontal, SetmioTokens.Spacing.gutter)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SetmioTokens.Colors.background)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("休息计时"))
        }
    }
}
