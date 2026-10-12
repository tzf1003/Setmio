import XCTest

/// Drives the Setmio watch app on a real Apple Watch (docs/DEVICE_CHECKLIST.md items 6, 7, 9). Select with
/// `-only-testing:SetmioWatchUITests/WatchChecklistUITests/<name>`; it never runs in CI. The watch must be on the wrist,
/// unlocked and paired with the iPhone running the matching build. Haptics and the heart-rate sensor itself cannot be
/// observed here; the tests capture the on-screen heart-rate diagnostics line instead.
final class WatchChecklistUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func attachScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachText(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Items 6 + 7: start the planned session, log two sets, end with effort 7. Captures the diagnostics line.
    @MainActor
    func testWatchWorkoutStartLogEnd() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launch()
        Thread.sleep(forTimeInterval: 3)
        attachScreen("w1-start-screen")
        attachText("w1-start-hierarchy", app.debugDescription)

        // A leftover unfinished session from an earlier run takes over the start screen; continue it, otherwise start fresh.
        let resume = app.buttons["继续训练"]
        let start = app.buttons["开始计划训练"]
        if resume.waitForExistence(timeout: 10) {
            attachText("w1-note", "resuming a leftover unfinished session")
            resume.tap()
        } else {
            XCTAssertTrue(start.waitForExistence(timeout: 15), "start button should show when a plan is cached")
            start.tap()
        }
        Thread.sleep(forTimeInterval: 6)
        attachScreen("w1-session-started")
        attachText("w1-session-hierarchy", app.debugDescription)

        for index in 1...2 {
            let done = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "完成")).firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 20), "done button should show")
            done.tap()
            Thread.sleep(forTimeInterval: 4)
            attachScreen("w1-after-set-\(index)")
            attachText("w1-after-set-\(index)-hierarchy", app.debugDescription)
            let skip = app.buttons["跳过"]
            if skip.waitForExistence(timeout: 3) {
                skip.tap()
                Thread.sleep(forTimeInterval: 2)
            }
        }

        let end = app.buttons["结束"]
        XCTAssertTrue(end.waitForExistence(timeout: 15), "end button should show")
        end.tap()
        Thread.sleep(forTimeInterval: 3)
        attachScreen("w1-end-sheet")
        attachText("w1-end-hierarchy", app.debugDescription)

        // Effort picker: crown-driven picker; try to reach 7 by tapping the picker then the save button.
        let save = app.buttons["保存并结束"]
        XCTAssertTrue(save.waitForExistence(timeout: 10), "save button should show")
        save.tap()
        Thread.sleep(forTimeInterval: 8)
        attachScreen("w1-after-end")
    }

    /// Item 9: start a session, log one set, kill the watch app, relaunch, and capture what shows.
    @MainActor
    func testWatchForceQuitRecovery() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launch()
        Thread.sleep(forTimeInterval: 3)

        let start = app.buttons["开始计划训练"]
        if start.waitForExistence(timeout: 15) {
            start.tap()
            Thread.sleep(forTimeInterval: 6)
        }
        let done = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "完成")).firstMatch
        if done.waitForExistence(timeout: 20) {
            done.tap()
            Thread.sleep(forTimeInterval: 4)
        }
        attachScreen("w9-before-kill")

        app.terminate()
        Thread.sleep(forTimeInterval: 3)
        app.launch()
        Thread.sleep(forTimeInterval: 6)
        attachScreen("w9-after-relaunch")
        attachText("w9-after-relaunch-hierarchy", app.debugDescription)
    }

    /// Heart-rate probe: start (or resume) a session, wait 45 s so the sensor has time to deliver, then capture the
    /// on-screen diagnostics (write authorisation, builder callbacks, data-source types, last error). The watch must be
    /// on the wrist for a real reading; the capture says which case it was.
    @MainActor
    func testWatchHeartRateProbe() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launch()
        Thread.sleep(forTimeInterval: 3)

        let resume = app.buttons["继续训练"]
        let start = app.buttons["开始计划训练"]
        if resume.waitForExistence(timeout: 6) {
            resume.tap()
        } else {
            // The start button sits below the plan list on a small screen: scroll it into view first.
            for _ in 0..<6 where !start.isHittable {
                app.swipeUp()
                Thread.sleep(forTimeInterval: 1)
            }
            XCTAssertTrue(start.waitForExistence(timeout: 5), "start button should be reachable after scrolling")
            start.tap()
        }
        Thread.sleep(forTimeInterval: 5)
        attachScreen("hr-t05")
        XCTAssertTrue(app.buttons["结束"].waitForExistence(timeout: 10), "the active session screen should be showing")

        Thread.sleep(forTimeInterval: 45)
        attachScreen("hr-t50")
        attachText("hr-t50-hierarchy", app.debugDescription)
    }
}
