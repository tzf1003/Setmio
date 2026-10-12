#if canImport(MuscleMap)
import MuscleMap
import SetmioUI
import SwiftUI

/// Front/back body map for the exercise library. Compiles to nothing until the MuscleMap package
/// (https://github.com/melihcolpan/MuscleMap, from 1.9.0) is linked into the Setmio target.
///
/// The view holds no filter state: the caller owns `selected` and toggles it in `onSelect`.
/// Sub-groups are shown so that every catalogue target has its own region (serratus, adductors).
/// A tap reports the most specific `Muscle` (e.g. `.upperChest`); the catalogue maps it back to a target.
struct MuscleBodyMapView: View {
    /// Muscles in the current filter, drawn with the accent colour.
    let selected: Set<Muscle>
    /// Called with the muscle under the finger.
    let onSelect: (Muscle) -> Void

    @State private var gender: BodyGender = .male
    @State private var side: BodySide = .front

    var body: some View {
        VStack(spacing: SetmioTokens.Spacing.md) {
            HStack(spacing: SetmioTokens.Spacing.sm) {
                Picker("", selection: $side) {
                    ForEach(BodySide.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("", selection: $gender) {
                    ForEach(BodyGender.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .labelsHidden()

            BodyView(gender: gender, side: side, style: Self.style)
                .showSubGroups()
                .highlight(Array(selected), color: SetmioTokens.Colors.accent, opacity: 0.85)
                .onMuscleSelected { muscle, _ in
                    onSelect(muscle)
                }
                .frame(maxWidth: .infinity, minHeight: 360, maxHeight: 480)
        }
        .setmioCard()
    }

    /// Neutral body on the app surface; the accent colour is reserved for the active filter.
    private static let style = BodyViewStyle(
        defaultFillColor: SetmioTokens.Colors.separator,
        strokeColor: SetmioTokens.Colors.background,
        strokeWidth: 0.5,
        headColor: SetmioTokens.Colors.separator,
        hairColor: .secondary
    )
}
#endif
