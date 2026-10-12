import Foundation
import Testing
import SetmioCore
import SetmioHealth
@testable import Setmio

@Suite("今日页底部更新时间")
struct UpdateCaptionTests {
    let calendar = Calendar.setmioDefault
    let day = DayKey(year: 2026, month: 10, day: 12)

    private func report(finishedAtHour hour: Int, minute: Int, imported: Int) -> ImportReport {
        let finished = day.date(atHour: hour, minute: minute, calendar: calendar)
        return ImportReport(counts: [.hrvSDNN: imported], startedAt: finished, finishedAt: finished)
    }

    @Test("后台更新比上次完整导入更新时，主时间显示的是后台更新（真机上曾显示成旧的导入时间）")
    func backgroundUpdateWinsOverReport() {
        let synced = day.date(atHour: 17, minute: 21, calendar: calendar)
        let caption = TodayView.updateCaption(lastSyncedAt: synced, report: report(finishedAtHour: 17, minute: 19, imported: 0), calendar: calendar)
        let text = try! #require(caption)
        #expect(text.hasPrefix("上次更新 17:21"), "primary time is the last update, got \(text)")
        #expect(text.contains("完整导入 0 条（17:19）"))
    }

    @Test("只有上次同步、没有导入报告时只显示上次更新")
    func syncedWithoutReport() {
        let synced = day.date(atHour: 9, minute: 5, calendar: calendar)
        #expect(TodayView.updateCaption(lastSyncedAt: synced, report: nil, calendar: calendar) == "上次更新 09:05")
    }

    @Test("什么都没有时不显示")
    func nothing() {
        #expect(TodayView.updateCaption(lastSyncedAt: nil, report: nil, calendar: calendar) == nil)
    }
}
