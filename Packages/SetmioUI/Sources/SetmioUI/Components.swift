#if canImport(SwiftUI)
import SwiftUI
import SetmioCore

// MARK: - MetricTile

/// A small card showing one number: HRV, resting HR, sleep, weight, kcal.
public struct MetricTile: View {
    public var title: String
    public var value: String
    public var subtitle: String?
    public var tint: Color

    public init(title: String, value: String, subtitle: String? = nil, tint: Color = .primary) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.tint = tint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SetmioTokens.Spacing.xs) {
            Text(title)
                .font(SetmioTokens.Typography.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(SetmioTokens.Typography.metricValue)
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let subtitle {
                Text(subtitle)
                    .font(SetmioTokens.Typography.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .setmioCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        var text = "\(title) \(value)"
        if let subtitle { text += "，\(subtitle)" }
        return text
    }
}

// MARK: - ReadinessGauge

/// 270° arc gauge for the daily readiness score (0–100), coloured by band, score in the middle.
public struct ReadinessGauge: View {
    public var score: Int
    public var band: ReadinessBand
    public var lineWidth: CGFloat
    public var showsLabel: Bool

    /// Fraction of the full circle the arc covers (open at the bottom).
    private let sweep = 0.75

    public init(score: Int, band: ReadinessBand, lineWidth: CGFloat = SetmioTokens.Stroke.gauge, showsLabel: Bool = true) {
        self.score = max(0, min(100, score))
        self.band = band
        self.lineWidth = lineWidth
        self.showsLabel = showsLabel
    }

    public init(_ readiness: ReadinessScore, lineWidth: CGFloat = SetmioTokens.Stroke.gauge, showsLabel: Bool = true) {
        self.init(score: readiness.score, band: readiness.band, lineWidth: lineWidth, showsLabel: showsLabel)
    }

    private var color: Color { SetmioTokens.Colors.readiness(band) }
    private var fraction: Double { Double(score) / 100 }

    public var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(color.opacity(0.18), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: sweep * fraction)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .animation(.easeOut(duration: 0.6), value: score)
        }
        // trim(0…) starts at 3 o'clock; rotating the arcs by 135° puts the gap at the bottom.
        .rotationEffect(.degrees(135), anchor: .center)
        .overlay {
            // The label sits in an overlay so it is not rotated with the arcs.
            VStack(spacing: SetmioTokens.Spacing.xxs) {
                Text("\(score)")
                    .font(SetmioTokens.Typography.largeNumber)
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                if showsLabel {
                    Text(SetmioFormat.bandLabel(band))
                        .font(SetmioTokens.Typography.label)
                        .foregroundStyle(color)
                }
            }
            .minimumScaleFactor(0.5)
            .padding(lineWidth * 1.5)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("准备度 \(score) 分，\(SetmioFormat.bandLabel(band))"))
        .accessibilityValue(Text("\(score)"))
    }
}

// MARK: - SetRow

/// One set in a session list: number, load × reps, RIR, completion tick.
public struct SetRow: View {
    /// 0-based set index as stored in Core (`LoggedSet.index` / `PlannedSet.index`); displayed as `index + 1`.
    public var index: Int
    public var load: Kilograms
    public var reps: Int
    public var rir: Int
    public var isCompleted: Bool
    public var isWarmup: Bool

    public init(index: Int, load: Kilograms, reps: Int, rir: Int, isCompleted: Bool, isWarmup: Bool = false) {
        self.index = index
        self.load = load
        self.reps = reps
        self.rir = rir
        self.isCompleted = isCompleted
        self.isWarmup = isWarmup
    }

    public init(_ set: LoggedSet) {
        self.init(index: set.index, load: set.load, reps: set.reps, rir: set.rir, isCompleted: true, isWarmup: set.isWarmup)
    }

    public var body: some View {
        HStack(spacing: SetmioTokens.Spacing.md) {
            Text(isWarmup ? "热" : "\(index + 1)")
                .font(SetmioTokens.Typography.caption.weight(.semibold))
                .frame(width: 24, height: 24)
                .background(isWarmup ? Color.secondary.opacity(0.15) : SetmioTokens.Colors.accent.opacity(0.15), in: Circle())
                .foregroundStyle(isWarmup ? Color.secondary : SetmioTokens.Colors.accent)

            Text(SetmioFormat.set(load: load, reps: reps))
                .font(SetmioTokens.Typography.setValue)
                .lineLimit(1)

            Spacer(minLength: SetmioTokens.Spacing.sm)

            Text(SetmioFormat.rir(rir))
                .font(SetmioTokens.Typography.caption)
                .foregroundStyle(.secondary)

            Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isCompleted ? SetmioTokens.Colors.positive : Color.secondary)
                .imageScale(.large)
                .accessibilityHidden(true)
        }
        .padding(.vertical, SetmioTokens.Spacing.xs)
        .opacity(isCompleted ? 1 : 0.85)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("第 \(index + 1) 组，\(SetmioFormat.compactKg(load)) \(reps) 次，\(SetmioFormat.rir(rir))\(isCompleted ? "，已完成" : "")"))
    }
}

// MARK: - PrimaryButton style

/// Filled accent button, full width, 44 pt minimum height (watchOS: 40 pt).
public struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: Self.minHeight)
            .padding(.horizontal, SetmioTokens.Spacing.lg)
            .background(
                SetmioTokens.Colors.accent.opacity(configuration.isPressed ? 0.75 : 1),
                in: SetmioTokens.Radius.card(SetmioTokens.Radius.large)
            )
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }

    #if os(watchOS)
    private static let minHeight: CGFloat = 40
    #else
    private static let minHeight: CGFloat = 50
    #endif
}

public extension ButtonStyle where Self == PrimaryButtonStyle {
    static var setmioPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

// MARK: - EmptyState

/// Centered placeholder for lists and dashboards with nothing to show yet.
public struct EmptyState: View {
    public var text: String
    public var systemImage: String
    public var detail: String?

    public init(text: String, systemImage: String = "tray", detail: String? = nil) {
        self.text = text
        self.systemImage = systemImage
        self.detail = detail
    }

    public var body: some View {
        ContentUnavailableView {
            Label(text, systemImage: systemImage)
        } description: {
            if let detail { Text(detail) }
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("MetricTile") {
    VStack(spacing: SetmioTokens.Spacing.md) {
        HStack(spacing: SetmioTokens.Spacing.md) {
            MetricTile(title: "HRV", value: SetmioFormat.milliseconds(48), subtitle: "基线 52 ms", tint: SetmioTokens.Colors.readinessYellow)
            MetricTile(title: "静息心率", value: SetmioFormat.bpm(55), subtitle: "基线 54 bpm")
        }
        HStack(spacing: SetmioTokens.Spacing.md) {
            MetricTile(title: "睡眠", value: SetmioFormat.minutesAsHours(452), subtitle: "需要 7小时30分")
            MetricTile(title: "体重", value: SetmioFormat.kg(62.5), subtitle: SetmioFormat.kgDelta(-0.4) + " / 周", tint: SetmioTokens.Colors.positive)
        }
    }
    .padding()
    .background(SetmioTokens.Colors.groupedBackground)
}

#Preview("ReadinessGauge") {
    HStack(spacing: SetmioTokens.Spacing.lg) {
        ReadinessGauge(score: 78, band: .green).frame(width: 120)
        ReadinessGauge(score: 52, band: .yellow).frame(width: 120)
        ReadinessGauge(score: 31, band: .red, lineWidth: SetmioTokens.Stroke.gaugeCompact, showsLabel: false).frame(width: 60)
    }
    .padding()
}

#Preview("SetRow") {
    let session = SetmioCore.ID<LoggedSession>()
    let exercise = SetmioCore.ID<Exercise>()
    List {
        SetRow(index: 0, load: 40, reps: 10, rir: 4, isCompleted: true, isWarmup: true)
        SetRow(LoggedSet(sessionID: session, exerciseID: exercise, index: 1, load: 60, reps: 12, rir: 2, completedAt: Date()))
        SetRow(index: 2, load: 62.5, reps: 10, rir: 2, isCompleted: false)
    }
}

#Preview("PrimaryButton + EmptyState") {
    VStack(spacing: SetmioTokens.Spacing.xl) {
        Button("开始训练") {}
            .buttonStyle(.setmioPrimary)
        Button("已禁用") {}
            .buttonStyle(.setmioPrimary)
            .disabled(true)
        EmptyState(text: "还没有训练记录", systemImage: "dumbbell", detail: "在手表上开始一次训练，记录会自动同步到这里。")
    }
    .padding()
}
#endif
#endif
