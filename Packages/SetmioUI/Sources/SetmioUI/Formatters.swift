import Foundation
import SetmioCore

/// zh-CN display formatting shared by the iOS app, the watch app and the widgets.
///
/// Foundation-only on purpose (no `NumberFormatter`/`DateFormatter` locale lookups), so the output is byte-identical
/// on Linux, in tests and on device. Units follow ARCHITECTURE.md §2: kg, kcal, ms, bpm, minutes.
public enum SetmioFormat {
    // MARK: Numbers

    /// `62.5 kg` — always one decimal so columns of loads line up.
    public static func kg(_ value: Kilograms) -> String {
        "\(oneDecimal(value)) kg"
    }

    /// `+2.5 kg` / `−1.0 kg` / `0.0 kg` for deltas (uses a true minus sign).
    public static func kgDelta(_ value: Kilograms) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded > 0 { return "+\(oneDecimal(rounded)) kg" }
        if rounded < 0 { return "−\(oneDecimal(-rounded)) kg" }
        return "0.0 kg"
    }

    /// `2,350 kcal` — integer with thousands grouping.
    public static func kcal(_ value: Kilocalories) -> String {
        "\(grouped(Int(value.rounded()))) kcal"
    }

    /// `48 ms` — HRV values are shown as integers.
    public static func milliseconds(_ value: Milliseconds) -> String {
        "\(Int(value.rounded())) ms"
    }

    /// `55 bpm`.
    public static func bpm(_ value: BeatsPerMinute) -> String {
        "\(Int(value.rounded())) bpm"
    }

    /// `75%` from a 0…1 fraction (`decimals` controls precision: `percent(0.756, decimals: 1)` → `75.6%`).
    public static func percent(_ fraction: Double, decimals: Int = 0) -> String {
        let value = fraction * 100
        if decimals <= 0 { return "\(Int(value.rounded()))%" }
        return String(format: "%.\(decimals)f%%", value)
    }

    /// `RIR 2`.
    public static func rir(_ value: Int) -> String {
        "RIR \(value)"
    }

    /// `60 kg × 12` — a logged or planned set in one glance.
    public static func set(load: Kilograms, reps: Int) -> String {
        "\(compactKg(load)) × \(reps)"
    }

    /// Target reps for a planned set: `8–12` (or `10` when the range is a single value).
    public static func repRange(_ range: ClosedRange<Int>) -> String {
        range.lowerBound == range.upperBound ? "\(range.lowerBound)" : "\(range.lowerBound)–\(range.upperBound)"
    }

    // MARK: Time

    /// `mm:ss` for rest timers and session clocks (`90` → `01:30`; minutes keep counting past 59).
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// `7小时30分` for sleep and session lengths; `45分` under an hour.
    public static func minutesAsHours(_ minutes: Minutes) -> String {
        let total = max(0, Int(minutes.rounded()))
        let hours = total / 60
        let rest = total % 60
        if hours == 0 { return "\(rest)分" }
        if rest == 0 { return "\(hours)小时" }
        return "\(hours)小时\(rest)分"
    }

    /// `10月9日 周四`.
    public static func date(_ day: DayKey, calendar: Calendar = .setmioDefault) -> String {
        let weekday = calendar.component(.weekday, from: day.startOfDay(calendar: calendar))
        return "\(day.month)月\(day.day)日 \(weekdayName(weekday))"
    }

    /// `10月9日 周四` for an instant, bucketed into the calendar's local day.
    public static func date(_ instant: Date, calendar: Calendar = .setmioDefault) -> String {
        date(DayKey(instant, calendar: calendar), calendar: calendar)
    }

    /// `今天` / `昨天` / `明天`, otherwise the full `date(_:)` form.
    public static func relativeDay(_ day: DayKey, today: DayKey, calendar: Calendar = .setmioDefault) -> String {
        switch day.daysSince(today, calendar: calendar) {
        case 0: "今天"
        case -1: "昨天"
        case 1: "明天"
        default: date(day, calendar: calendar)
        }
    }

    /// `08:05` wall-clock time in the calendar's time zone.
    public static func clock(_ instant: Date, calendar: Calendar = .setmioDefault) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: instant)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// Foundation weekday number (1 = Sunday … 7 = Saturday) → `周日 … 周六`.
    public static func weekdayName(_ weekday: Int) -> String {
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        guard (1...7).contains(weekday) else { return "" }
        return names[weekday - 1]
    }

    // MARK: Readiness

    /// Short colour name: `绿` / `黄` / `红`.
    public static func bandName(_ band: ReadinessBand) -> String {
        switch band {
        case .green: "绿"
        case .yellow: "黄"
        case .red: "红"
        }
    }

    /// User-facing status: `状态好` / `一般` / `需要恢复`.
    public static func bandLabel(_ band: ReadinessBand) -> String {
        switch band {
        case .green: "状态好"
        case .yellow: "一般"
        case .red: "需要恢复"
        }
    }

    /// `72 · 状态好` — one line for widgets and the watch.
    public static func readinessSummary(_ score: ReadinessScore) -> String {
        "\(score.score) · \(bandLabel(score.band))"
    }

    // MARK: Helpers

    /// Integer with `,` thousands separators, e.g. `2350` → `2,350`.
    public static func grouped(_ value: Int) -> String {
        let digits = String(abs(value))
        var out = ""
        for (offset, ch) in digits.reversed().enumerated() {
            if offset > 0 && offset % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        let body = String(out.reversed())
        return value < 0 ? "-\(body)" : body
    }

    /// `62.5` / `60.0`.
    static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// `60 kg` when whole, `62.5 kg` otherwise — for dense set rows.
    public static func compactKg(_ value: Kilograms) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return "\(Int(rounded)) kg" }
        return "\(oneDecimal(rounded)) kg"
    }
}
