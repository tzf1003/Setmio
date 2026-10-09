#if canImport(SwiftUI)
import SwiftUI
import SetmioCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Design tokens shared by the iOS app, the watch app and the widgets.
///
/// Colours are system semantic colours wherever one exists, so light/dark, increased contrast and the watch's
/// always-black canvas come for free. Numbers are points.
public enum SetmioTokens {
    // MARK: - Colours

    public enum Colors {
        /// Readiness bands. The three system colours adapt to light/dark and accessibility settings.
        public static let readinessGreen = Color.green
        public static let readinessYellow = Color.yellow
        public static let readinessRed = Color.red

        /// The app accent (asset catalogue `AccentColor`); falls back to the system blue in previews without assets.
        public static let accent = Color.accentColor

        /// Positive / negative deltas (weight trend, e1RM change) and warnings (kcal floor hit, pen expiry).
        public static let positive = Color.green
        public static let negative = Color.red
        public static let warning = Color.orange

        #if os(iOS) || os(visionOS)
        public static let background = Color(uiColor: .systemBackground)
        public static let groupedBackground = Color(uiColor: .systemGroupedBackground)
        public static let surface = Color(uiColor: .secondarySystemBackground)
        public static let surfaceElevated = Color(uiColor: .tertiarySystemBackground)
        public static let separator = Color(uiColor: .separator)
        #elseif os(macOS)
        public static let background = Color(nsColor: .windowBackgroundColor)
        public static let groupedBackground = Color(nsColor: .underPageBackgroundColor)
        public static let surface = Color(nsColor: .controlBackgroundColor)
        public static let surfaceElevated = Color(nsColor: .textBackgroundColor)
        public static let separator = Color(nsColor: .separatorColor)
        #else
        // watchOS has no UIColor.systemBackground; the canvas is always black.
        public static let background = Color.black
        public static let groupedBackground = Color.black
        public static let surface = Color(white: 0.13)
        public static let surfaceElevated = Color(white: 0.20)
        public static let separator = Color(white: 0.32)
        #endif

        /// Colour for a readiness band.
        public static func readiness(_ band: ReadinessBand) -> Color {
            switch band {
            case .green: readinessGreen
            case .yellow: readinessYellow
            case .red: readinessRed
            }
        }

        /// Colour for a readiness band, or a neutral grey when no score exists yet (insufficient baseline).
        public static func readiness(_ band: ReadinessBand?) -> Color {
            band.map(readiness) ?? Color.gray
        }
    }

    // MARK: - Spacing (4-pt grid)

    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32

        /// Default horizontal page gutter.
        #if os(watchOS)
        public static let gutter: CGFloat = 8
        #else
        public static let gutter: CGFloat = 16
        #endif
    }

    // MARK: - Corner radius

    public enum Radius {
        public static let small: CGFloat = 8
        public static let medium: CGFloat = 12
        public static let large: CGFloat = 16
        public static let xl: CGFloat = 24
        /// For pills and circular buttons.
        public static let pill: CGFloat = 999

        /// The shape used by cards and tiles.
        public static func card(_ radius: CGFloat = medium) -> RoundedRectangle {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
        }
    }

    // MARK: - Typography

    /// Numbers use the rounded design with monospaced digits so timers and loads do not jitter.
    public enum Typography {
        public static let largeNumber = Font.system(.largeTitle, design: .rounded, weight: .bold).monospacedDigit()
        public static let metricValue = Font.system(.title2, design: .rounded, weight: .semibold).monospacedDigit()
        public static let setValue = Font.system(.body, design: .rounded, weight: .medium).monospacedDigit()
        public static let timer = Font.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit()

        public static let title = Font.title3.weight(.semibold)
        public static let body = Font.body
        public static let caption = Font.caption
        public static let footnote = Font.footnote
        public static let label = Font.subheadline.weight(.medium)
    }

    // MARK: - Stroke widths

    public enum Stroke {
        public static let gauge: CGFloat = 12
        #if os(watchOS)
        public static let gaugeCompact: CGFloat = 6
        #else
        public static let gaugeCompact: CGFloat = 8
        #endif
        public static let hairline: CGFloat = 1
    }
}

// MARK: - Convenience modifiers

public extension View {
    /// Card chrome: surface colour, continuous corners, standard padding.
    func setmioCard(padding: CGFloat = SetmioTokens.Spacing.md, radius: CGFloat = SetmioTokens.Radius.medium) -> some View {
        self
            .padding(padding)
            .background(SetmioTokens.Colors.surface, in: SetmioTokens.Radius.card(radius))
    }
}

public extension ShapeStyle where Self == Color {
    static func readiness(_ band: ReadinessBand) -> Color {
        SetmioTokens.Colors.readiness(band)
    }
}
#endif
