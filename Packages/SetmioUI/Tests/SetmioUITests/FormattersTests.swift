import Foundation
import SetmioCore
import Testing
@testable import SetmioUI

@Suite("SetmioFormat")
struct FormattersTests {
    @Test func kilograms() {
        #expect(SetmioFormat.kg(62.5) == "62.5 kg")
        #expect(SetmioFormat.kg(60) == "60.0 kg")
        #expect(SetmioFormat.kg(62.449) == "62.4 kg")
        #expect(SetmioFormat.compactKg(60) == "60 kg")
        #expect(SetmioFormat.compactKg(62.5) == "62.5 kg")
        #expect(SetmioFormat.kgDelta(2.5) == "+2.5 kg")
        #expect(SetmioFormat.kgDelta(-0.4) == "−0.4 kg")
        #expect(SetmioFormat.kgDelta(0.01) == "0.0 kg")
    }

    @Test func kilocaloriesGrouping() {
        #expect(SetmioFormat.kcal(2350) == "2,350 kcal")
        #expect(SetmioFormat.kcal(980.4) == "980 kcal")
        #expect(SetmioFormat.kcal(1_234_567) == "1,234,567 kcal")
        #expect(SetmioFormat.grouped(0) == "0")
        #expect(SetmioFormat.grouped(-1500) == "-1,500")
    }

    @Test func smallUnits() {
        #expect(SetmioFormat.milliseconds(48.4) == "48 ms")
        #expect(SetmioFormat.bpm(55.6) == "56 bpm")
        #expect(SetmioFormat.percent(0.75) == "75%")
        #expect(SetmioFormat.percent(0.756, decimals: 1) == "75.6%")
        #expect(SetmioFormat.rir(2) == "RIR 2")
        #expect(SetmioFormat.set(load: 60, reps: 12) == "60 kg × 12")
        #expect(SetmioFormat.repRange(8...12) == "8–12")
        #expect(SetmioFormat.repRange(10...10) == "10")
    }

    @Test func durations() {
        #expect(SetmioFormat.duration(90) == "01:30")
        #expect(SetmioFormat.duration(0) == "00:00")
        #expect(SetmioFormat.duration(-5) == "00:00")
        #expect(SetmioFormat.duration(3725) == "62:05")
        #expect(SetmioFormat.minutesAsHours(450) == "7小时30分")
        #expect(SetmioFormat.minutesAsHours(45) == "45分")
        #expect(SetmioFormat.minutesAsHours(120) == "2小时")
    }

    @Test func chineseDate() {
        // 2025-10-09 is a Thursday.
        let day = DayKey(year: 2025, month: 10, day: 9)
        #expect(SetmioFormat.date(day) == "10月9日 周四")
        #expect(SetmioFormat.date(DayKey(year: 2026, month: 1, day: 4)) == "1月4日 周日")
        #expect(SetmioFormat.relativeDay(day, today: day) == "今天")
        #expect(SetmioFormat.relativeDay(day.adding(days: -1), today: day) == "昨天")
        #expect(SetmioFormat.relativeDay(day.adding(days: 1), today: day) == "明天")
        #expect(SetmioFormat.relativeDay(day.adding(days: -3), today: day) == "10月6日 周一")
        #expect(SetmioFormat.weekdayName(0) == "")
    }

    @Test func clockUsesCalendarTimeZone() {
        let shanghai = DayKey(year: 2025, month: 10, day: 9).date(atHour: 8, minute: 5)
        #expect(SetmioFormat.clock(shanghai) == "08:05")
        #expect(SetmioFormat.clock(shanghai, calendar: .setmio(timeZoneIdentifier: "UTC")) == "00:05")
    }

    @Test func readinessBands() {
        #expect(SetmioFormat.bandName(.green) == "绿")
        #expect(SetmioFormat.bandName(.yellow) == "黄")
        #expect(SetmioFormat.bandName(.red) == "红")
        #expect(SetmioFormat.bandLabel(.green) == "状态好")
        #expect(SetmioFormat.bandLabel(.yellow) == "一般")
        #expect(SetmioFormat.bandLabel(.red) == "需要恢复")

        let score = ReadinessScore(day: DayKey(year: 2025, month: 10, day: 9), score: 72, band: .green, confidence: 0.8,
                                   components: [], flags: [], baselineDays: 40, computedAt: Date(timeIntervalSince1970: 0))
        #expect(SetmioFormat.readinessSummary(score) == "72 · 状态好")
    }
}
