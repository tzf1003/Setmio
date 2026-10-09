import Foundation

/// Small, dependency-free statistics helpers used by the engines.
public enum Stats {
    public static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Sample standard deviation (n − 1). Returns nil for fewer than 2 values.
    public static func standardDeviation(_ values: [Double]) -> Double? {
        guard values.count >= 2, let m = mean(values) else { return nil }
        let sumSq = values.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        return (sumSq / Double(values.count - 1)).squareRoot()
    }

    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// Linear-interpolated percentile, `p` in 0...100.
    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        if sorted.count == 1 { return sorted[0] }
        let rank = (p / 100) * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = rank - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    /// z-score with a floor on the standard deviation to avoid division blow-ups on flat baselines.
    public static func zScore(_ value: Double, mean: Double, sd: Double, sdFloor: Double) -> Double {
        (value - mean) / max(sd, sdFloor)
    }

    public static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    /// Exponential moving average. `alpha` is the weight of the newest value.
    public static func ema(_ values: [Double], alpha: Double, seed: Double? = nil) -> [Double] {
        guard !values.isEmpty else { return [] }
        var out: [Double] = []
        out.reserveCapacity(values.count)
        var current = seed ?? values[0]
        for (index, v) in values.enumerated() {
            if index == 0 && seed == nil {
                current = v
            } else {
                current += alpha * (v - current)
            }
            out.append(current)
        }
        return out
    }

    /// Least-squares slope of `y` against `x`. Returns nil with fewer than 2 points or zero x-variance.
    public static func linearSlope(x: [Double], y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 2, let mx = mean(x), let my = mean(y) else { return nil }
        var num = 0.0
        var den = 0.0
        for i in 0..<x.count {
            num += (x[i] - mx) * (y[i] - my)
            den += (x[i] - mx) * (x[i] - mx)
        }
        guard den > 0 else { return nil }
        return num / den
    }

    /// Rounds `value` to the nearest multiple of `step` (e.g. plate increments). Non-positive steps return `value`.
    public static func round(_ value: Double, toNearest step: Double) -> Double {
        guard step > 0 else { return value }
        return (value / step).rounded() * step
    }
}
