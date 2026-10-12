import XCTest

/// Real-device checklist driver (docs/DEVICE_CHECKLIST.md). Runs only on the physical iPhone, selected with
/// `-only-testing:SetmioUITests/DeviceChecklistUITests`, so the simulator walk-through never runs here. Nothing in
/// this file toggles demo data: the device must use the real HealthKit store.
final class DeviceChecklistUITests: XCTestCase {
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

    /// Item 1: on a fresh install, the HealthKit sheet opens from onboarding and lists only the MVP types.
    /// The test records what it sees; the comparison with docs/DEVICE_CHECKLIST.md is done from the attachments.
    @MainActor
    func testItem1HealthSheetShowsMVPTypes() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["基本档案"].waitForExistence(timeout: 30), "onboarding should show on a fresh install")
        app.buttons["下一步"].tap()

        let authorize = app.buttons["授权访问「健康」"]
        XCTAssertTrue(authorize.waitForExistence(timeout: 10), "health step should show the authorize button")
        attachScreen("item1-before-authorize")
        authorize.tap()

        // The HealthKit sheet is presented out of process; give it time to appear before capturing.
        Thread.sleep(forTimeInterval: 4)
        attachScreen("item1-health-sheet")
        attachText("item1-app-hierarchy", app.debugDescription)

        // Scroll the sheet so every category is captured. Drags start away from the switches (x = 0.5).
        for index in 2...6 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            start.press(forDuration: 0.1, thenDragTo: end)
            Thread.sleep(forTimeInterval: 1)
            attachScreen("item1-health-sheet-\(index)")
        }
    }

    /// Item 2: deny every type on the sheet, then turn them back on in the Health app and sync again.
    /// Captures each step; the outcome is judged from the screenshots.
    @MainActor
    func testItem2DenyThenAllowInHealthApp() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["基本档案"].waitForExistence(timeout: 30), "onboarding should show")
        app.buttons["下一步"].tap()
        let authorize = app.buttons["授权访问「健康」"]
        XCTAssertTrue(authorize.waitForExistence(timeout: 10))
        authorize.tap()
        Thread.sleep(forTimeInterval: 4)

        // Scroll the sheet to its bottom, where 不允许 lives.
        for _ in 0..<8 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
            Thread.sleep(forTimeInterval: 0.5)
        }
        Thread.sleep(forTimeInterval: 1)
        attachScreen("item2-sheet-bottom")

        let deny = app.buttons["不允许"]
        if deny.waitForExistence(timeout: 2) {
            deny.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.86)).tap()
        }
        Thread.sleep(forTimeInterval: 3)
        attachScreen("item2-after-deny")

        // Health app: 共享 → Setmio → turn every switch on.
        let health = XCUIApplication(bundleIdentifier: "com.apple.Health")
        health.launch()
        Thread.sleep(forTimeInterval: 3)
        attachScreen("item2-health-home")

        let sharing = health.tabBars.buttons["共享"]
        if sharing.waitForExistence(timeout: 10) {
            sharing.tap()
        }
        Thread.sleep(forTimeInterval: 2)
        attachScreen("item2-health-sharing")

        let setmioRow = health.staticTexts["Setmio"].firstMatch
        if setmioRow.waitForExistence(timeout: 10) {
            setmioRow.tap()
        }
        Thread.sleep(forTimeInterval: 2)
        attachScreen("item2-health-setmio")

        for toggle in health.switches.allElementsBoundByIndex where (toggle.value as? String) == "0" {
            toggle.tap()
        }
        Thread.sleep(forTimeInterval: 2)
        attachScreen("item2-health-all-on")

        // Back to Setmio: request again, then refresh the Today screen.
        app.activate()
        Thread.sleep(forTimeInterval: 3)
        attachScreen("item2-setmio-after-allow")
    }

    /// Exploration for item 2: find where the Health app keeps app sharing on this iOS version.
    /// Terminates Setmio first (clears any leftover HealthKit sheet), then lists the Health app's buttons.
    @MainActor
    func testItem2ExploreHealthAppSharing() throws {
        XCUIApplication().terminate()
        Thread.sleep(forTimeInterval: 1)

        let health = XCUIApplication(bundleIdentifier: "com.apple.Health")
        health.launch()
        Thread.sleep(forTimeInterval: 3)
        attachScreen("item2x-health-home")

        let buttons = health.buttons.allElementsBoundByIndex.map { element in
            "label=\(element.label) | id=\(element.identifier) | frame=\(element.frame)"
        }
        attachText("item2x-health-buttons", buttons.joined(separator: "\n"))
    }

    /// Exploration for item 2, second step: Summary tab, then the profile button at the top right.
    @MainActor
    func testItem2ExploreHealthAvatar() throws {
        XCUIApplication().terminate()
        let health = XCUIApplication(bundleIdentifier: "com.apple.Health")
        health.launch()
        Thread.sleep(forTimeInterval: 2)

        health.buttons.matching(identifier: "UIA.Health.Tab.Summary").firstMatch.tap()
        Thread.sleep(forTimeInterval: 2)
        attachScreen("item2y-summary")

        health.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.06)).tap()
        Thread.sleep(forTimeInterval: 2)
        attachScreen("item2y-after-avatar-tap")

        let buttons = health.buttons.allElementsBoundByIndex.map { element in
            "label=\(element.label) | id=\(element.identifier) | frame=\(element.frame)"
        }
        attachText("item2y-buttons", buttons.joined(separator: "\n"))
    }

    /// Exploration for item 2, third step: the 资料 (profile) button, then list what the profile page offers.
    @MainActor
    func testItem2ExploreHealthProfile() throws {
        XCUIApplication().terminate()
        let health = XCUIApplication(bundleIdentifier: "com.apple.Health")
        health.launch()
        Thread.sleep(forTimeInterval: 2)

        health.buttons.matching(identifier: "UIA.Health.Tab.Summary").firstMatch.tap()
        Thread.sleep(forTimeInterval: 2)
        health.buttons["资料"].tap()
        Thread.sleep(forTimeInterval: 2)
        attachScreen("item2z-profile")

        let buttons = health.buttons.allElementsBoundByIndex.map { element in
            "label=\(element.label) | id=\(element.identifier) | frame=\(element.frame)"
        }
        attachText("item2z-buttons", buttons.joined(separator: "\n"))
        let cells = health.cells.allElementsBoundByIndex.map { "cell label=\($0.label)" }
        attachText("item2z-cells", cells.joined(separator: "\n"))
    }

    /// Item 2, allow half: turn every Setmio switch on in the Health app (资料 → App → Setmio), then go back to
    /// Setmio, pass onboarding again and sync on Today. Each step is captured for review.
    @MainActor
    func testItem2AllowInHealthAppThenSync() throws {
        XCUIApplication().terminate()
        let health = XCUIApplication(bundleIdentifier: "com.apple.Health")
        health.launch()
        Thread.sleep(forTimeInterval: 2)
        health.buttons.matching(identifier: "UIA.Health.Tab.Summary").firstMatch.tap()
        Thread.sleep(forTimeInterval: 1)
        health.buttons["资料"].tap()
        Thread.sleep(forTimeInterval: 2)
        health.staticTexts["App"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 2)
        attachScreen("item2-app-list")
        // The list is alphabetical; Setmio sits below the first screen, so scroll until it appears.
        var setmioRow = health.staticTexts["Setmio"].firstMatch
        for _ in 0..<10 where !setmioRow.exists {
            health.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.1, thenDragTo: health.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
            Thread.sleep(forTimeInterval: 0.6)
            setmioRow = health.staticTexts["Setmio"].firstMatch
        }
        attachScreen("item2-app-list-scrolled")
        XCTAssertTrue(setmioRow.waitForExistence(timeout: 5), "Setmio should be in the Health app's App list")
        setmioRow.tap()
        Thread.sleep(forTimeInterval: 2)
        attachScreen("item2-setmio-sharing")

        for toggle in health.switches.allElementsBoundByIndex where (toggle.value as? String) == "0" {
            toggle.tap()
            Thread.sleep(forTimeInterval: 0.3)
        }
        Thread.sleep(forTimeInterval: 2)
        attachScreen("item2-setmio-all-on")

        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["基本档案"].waitForExistence(timeout: 30), "onboarding should show again")
        app.buttons["下一步"].tap()
        let authorize = app.buttons["授权访问「健康」"]
        XCTAssertTrue(authorize.waitForExistence(timeout: 10))
        authorize.tap()
        Thread.sleep(forTimeInterval: 5)
        attachScreen("item2-setmio-after-authorize")

        let template = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "推拉腿")).firstMatch
        if template.waitForExistence(timeout: 10) {
            template.tap()
        }
        let create = app.buttons["生成训练周期"]
        if create.waitForExistence(timeout: 10) {
            create.tap()
        }
        Thread.sleep(forTimeInterval: 3)

        app.tabBars.buttons["今日"].tap()
        let sync = app.buttons["同步健康数据"]
        if sync.waitForExistence(timeout: 10) {
            sync.tap()
        }
        Thread.sleep(forTimeInterval: 8)
        attachScreen("item2-today-after-sync")
        attachText("item2-today-hierarchy", app.debugDescription)
    }

    /// Item 2, allow half (authorised by the user for full automation): tap 允许 on the HealthKit sheet that is
    /// still open from the previous run, finish onboarding if it is still showing, then sync on Today.
    @MainActor
    func testItem2TapAllowAndSync() throws {
        let app = XCUIApplication()
        app.activate()
        Thread.sleep(forTimeInterval: 2)
        attachScreen("item2-allow-before")

        for _ in 0..<8 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
            Thread.sleep(forTimeInterval: 0.5)
        }
        Thread.sleep(forTimeInterval: 1)
        attachScreen("item2-allow-bottom")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.795)).tap()
        Thread.sleep(forTimeInterval: 5)
        attachScreen("item2-allow-after")

        let template = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "推拉腿")).firstMatch
        if template.waitForExistence(timeout: 8) {
            template.tap()
        }
        let create = app.buttons["生成训练周期"]
        if create.waitForExistence(timeout: 8) {
            create.tap()
        }
        Thread.sleep(forTimeInterval: 3)

        let today = app.tabBars.buttons["今日"]
        if today.waitForExistence(timeout: 10) {
            today.tap()
        }
        let sync = app.buttons["同步健康数据"]
        if sync.waitForExistence(timeout: 10) {
            sync.tap()
        }
        Thread.sleep(forTimeInterval: 10)
        attachScreen("item2-today-after-sync")
        attachText("item2-today-hierarchy", app.debugDescription)
    }

    /// Item 2, allow half, from a clean launch: onboarding → 授权访问「健康」 → 全选 → 允许 → finish onboarding →
    /// Today → 同步健康数据. Every step is captured so the outcome can be read from the screenshots.
    @MainActor
    func testItem2FreshAllowSyncFlow() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launch()

        XCTAssertTrue(app.staticTexts["基本档案"].waitForExistence(timeout: 30), "onboarding should show")
        app.buttons["下一步"].tap()
        let authorize = app.buttons["授权访问「健康」"]
        XCTAssertTrue(authorize.waitForExistence(timeout: 10))
        authorize.tap()
        Thread.sleep(forTimeInterval: 4)
        attachScreen("item2f-sheet-top")

        let selectAll = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "全选")).firstMatch
        if selectAll.waitForExistence(timeout: 3) {
            selectAll.tap()
            Thread.sleep(forTimeInterval: 1)
        }
        attachScreen("item2f-after-selectall")

        for _ in 0..<8 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
            Thread.sleep(forTimeInterval: 0.5)
        }
        Thread.sleep(forTimeInterval: 1)
        attachScreen("item2f-bottom")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.795)).tap()
        Thread.sleep(forTimeInterval: 6)
        attachScreen("item2f-after-allow")

        let template = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "推拉腿")).firstMatch
        if template.waitForExistence(timeout: 8) {
            template.tap()
        }
        let create = app.buttons["生成训练周期"]
        if create.waitForExistence(timeout: 8) {
            create.tap()
        }
        Thread.sleep(forTimeInterval: 3)

        let today = app.tabBars.buttons["今日"]
        if today.waitForExistence(timeout: 10) {
            today.tap()
        }
        let sync = app.buttons["同步健康数据"]
        if sync.waitForExistence(timeout: 10) {
            sync.tap()
        }
        Thread.sleep(forTimeInterval: 12)
        attachScreen("item2f-today")
        attachText("item2f-today-hierarchy", app.debugDescription)
    }

    /// Item 2, allow half, using coordinate taps for the out-of-process sheet (accessibility taps do not reach it):
    /// 全选 at the top of the sheet, scroll to the bottom, 允许, then finish onboarding and sync on Today.
    @MainActor
    func testItem2SelectAllCoordFlow() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launch()

        XCTAssertTrue(app.staticTexts["基本档案"].waitForExistence(timeout: 30), "onboarding should show")
        app.buttons["下一步"].tap()
        let authorize = app.buttons["授权访问「健康」"]
        XCTAssertTrue(authorize.waitForExistence(timeout: 10))
        authorize.tap()
        Thread.sleep(forTimeInterval: 4)
        attachScreen("item2c-sheet-top")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4025)).tap()
        Thread.sleep(forTimeInterval: 2)
        attachScreen("item2c-after-selectall")

        for _ in 0..<8 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
            Thread.sleep(forTimeInterval: 0.5)
        }
        Thread.sleep(forTimeInterval: 1)
        attachScreen("item2c-bottom")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.795)).tap()
        Thread.sleep(forTimeInterval: 6)
        attachScreen("item2c-after-allow")

        let template = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "推拉腿")).firstMatch
        if template.waitForExistence(timeout: 8) {
            template.tap()
        }
        let create = app.buttons["生成训练周期"]
        if create.waitForExistence(timeout: 8) {
            create.tap()
        }
        Thread.sleep(forTimeInterval: 3)

        let today = app.tabBars.buttons["今日"]
        if today.waitForExistence(timeout: 10) {
            today.tap()
        }
        let sync = app.buttons["同步健康数据"]
        if sync.waitForExistence(timeout: 10) {
            sync.tap()
        }
        Thread.sleep(forTimeInterval: 12)
        attachScreen("item2c-today")
        attachText("item2c-today-hierarchy", app.debugDescription)
    }

    /// Item 2, allow half, complete flow: 全选 → 允许 → choose 所有已记录的数据及后续数据 (the app needs 60 days of
    /// history for its baseline) → 允许 → finish onboarding → sync on Today.
    @MainActor
    func testItem2CompleteAllowFlow() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launch()

        XCTAssertTrue(app.staticTexts["基本档案"].waitForExistence(timeout: 30), "onboarding should show")
        app.buttons["下一步"].tap()
        let authorize = app.buttons["授权访问「健康」"]
        XCTAssertTrue(authorize.waitForExistence(timeout: 10))
        authorize.tap()
        Thread.sleep(forTimeInterval: 4)

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4025)).tap()
        Thread.sleep(forTimeInterval: 2)
        attachScreen("item2d-sheet1-selected")

        for _ in 0..<8 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
            Thread.sleep(forTimeInterval: 0.5)
        }
        Thread.sleep(forTimeInterval: 1)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.795)).tap()
        Thread.sleep(forTimeInterval: 4)
        attachScreen("item2d-sheet2")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.565)).tap()
        Thread.sleep(forTimeInterval: 2)
        attachScreen("item2d-sheet2-option")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8675)).tap()
        Thread.sleep(forTimeInterval: 8)
        attachScreen("item2d-after-allow")

        let create = app.buttons["生成训练周期"]
        if create.waitForExistence(timeout: 10) {
            create.tap()
        }
        Thread.sleep(forTimeInterval: 3)

        let today = app.tabBars.buttons["今日"]
        if today.waitForExistence(timeout: 10) {
            today.tap()
        }
        let sync = app.buttons["同步健康数据"]
        if sync.waitForExistence(timeout: 10) {
            sync.tap()
        }
        Thread.sleep(forTimeInterval: 15)
        attachScreen("item2d-today")
        attachText("item2d-today-hierarchy", app.debugDescription)
    }

    /// Item 3: record 本地记录 in Settings, re-import, switch tabs while the import runs (UI must not freeze),
    /// then record 本地记录 again. The counts should be unchanged.
    @MainActor
    func testItem3ReimportKeepsRowCounts() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launch()

        let settingsTab = app.tabBars.buttons["设置"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 30), "main tabs should show")
        settingsTab.tap()
        Thread.sleep(forTimeInterval: 3)
        attachScreen("item3-settings-before")
        attachText("item3-settings-before-hierarchy", app.debugDescription)

        let reimport = app.buttons["重新导入健康数据"]
        XCTAssertTrue(reimport.waitForExistence(timeout: 10), "re-import button should show")
        reimport.tap()
        Thread.sleep(forTimeInterval: 3)
        attachScreen("item3-during-import")

        // The UI must stay responsive while the import runs: switch tabs and back.
        app.tabBars.buttons["训练"].tap()
        Thread.sleep(forTimeInterval: 2)
        attachScreen("item3-training-tab-during-import")
        settingsTab.tap()
        Thread.sleep(forTimeInterval: 2)

        // Wait for the import to finish (the progress line disappears).
        let importing = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "导入")).firstMatch
        _ = importing.waitForNonExistence(timeout: 300)
        Thread.sleep(forTimeInterval: 5)
        attachScreen("item3-settings-after")
        attachText("item3-settings-after-hierarchy", app.debugDescription)
    }

    /// Item 5, phone part: log two sets on the phone, end with effort 6, check 「已写入「健康」」 in the history, then
    /// look for 「传统力量训练」 in the Fitness app. The next-day plan change needs a day and is checked separately.
    @MainActor
    func testItem5PhoneWorkoutToFitness() throws {
        let app = XCUIApplication()
        app.terminate()
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["训练"].waitForExistence(timeout: 30), "main tabs should show")
        app.tabBars.buttons["训练"].tap()
        Thread.sleep(forTimeInterval: 2)

        let start = app.buttons["开始手机记录"]
        if start.waitForExistence(timeout: 5) {
            start.tap()
        }
        Thread.sleep(forTimeInterval: 2)
        attachScreen("item5-started")

        for index in 1...2 {
            let logSet = app.buttons["记一组"]
            if logSet.waitForExistence(timeout: 8) {
                logSet.tap()
            }
            Thread.sleep(forTimeInterval: 2)
            let save = app.buttons["保存"]
            if save.waitForExistence(timeout: 8) {
                save.tap()
            }
            Thread.sleep(forTimeInterval: 2)
            attachScreen("item5-logged-\(index)")
        }

        let end = app.buttons["结束训练"]
        if end.waitForExistence(timeout: 8) {
            end.tap()
        }
        Thread.sleep(forTimeInterval: 2)
        let confirmEnd = app.buttons["结束"]
        if confirmEnd.waitForExistence(timeout: 8) {
            confirmEnd.tap()
        }
        Thread.sleep(forTimeInterval: 5)
        attachScreen("item5-ended")

        let healthMark = app.staticTexts["已写入「健康」"].firstMatch
        _ = healthMark.waitForExistence(timeout: 90)
        Thread.sleep(forTimeInterval: 3)
        attachScreen("item5-history")
        attachText("item5-history-hierarchy", app.debugDescription)

        let fitness = XCUIApplication(bundleIdentifier: "com.apple.Fitness")
        fitness.launch()
        Thread.sleep(forTimeInterval: 4)
        attachScreen("item5-fitness-home")
        attachText("item5-fitness-hierarchy", fitness.debugDescription)
    }

    /// Item 5, Fitness check: get past the Fitness intro, then look for 传统力量训练 from Setmio (scrolling down a few times).
    @MainActor
    func testItem5FitnessShowsWorkout() throws {
        let fitness = XCUIApplication(bundleIdentifier: "com.apple.Fitness")
        fitness.terminate()
        fitness.launch()
        Thread.sleep(forTimeInterval: 3)
        let cont = fitness.buttons["继续"]
        if cont.waitForExistence(timeout: 8) {
            cont.tap()
        }
        Thread.sleep(forTimeInterval: 4)
        attachScreen("item5f-summary")

        for index in 1...4 {
            let found = fitness.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "传统力量训练")).firstMatch
            if found.exists { break }
            fitness.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.1, thenDragTo: fitness.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
            Thread.sleep(forTimeInterval: 1)
            attachScreen("item5f-scroll-\(index)")
        }
        attachText("item5f-hierarchy", fitness.debugDescription)
    }

    /// Watch install: open the Watch app on the iPhone, find 可用的 App, and try to install Setmio on the paired watch.
    @MainActor
    func testWatchInstallSetmio() throws {
        let watch = XCUIApplication(bundleIdentifier: "com.apple.Bridge")
        watch.terminate()
        watch.launch()
        Thread.sleep(forTimeInterval: 4)
        attachScreen("watch-app-home")

        let available = watch.staticTexts["可用的 App"].firstMatch
        if available.waitForExistence(timeout: 5) {
            available.tap()
            Thread.sleep(forTimeInterval: 3)
        }
        attachScreen("watch-app-available")
        attachText("watch-app-hierarchy", watch.debugDescription)

        let setmio = watch.staticTexts["Setmio"].firstMatch
        if setmio.waitForExistence(timeout: 5) {
            setmio.tap()
            Thread.sleep(forTimeInterval: 3)
        }
        attachScreen("watch-app-setmio")
        attachText("watch-app-setmio-hierarchy", watch.debugDescription)
    }

    /// Watch install, second pass: scroll the Watch app's home list until 可用的 App (or an existing Setmio row) shows,
    /// open it, and tap 安装 for Setmio if it is offered. Each step is captured.
    @MainActor
    func testWatchInstallSetmioScroll() throws {
        let watch = XCUIApplication(bundleIdentifier: "com.apple.Bridge")
        watch.terminate()
        watch.launch()
        Thread.sleep(forTimeInterval: 4)

        var available = watch.staticTexts["可用的 App"].firstMatch
        for index in 1...8 where !available.exists {
            watch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.1, thenDragTo: watch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
            Thread.sleep(forTimeInterval: 1)
            available = watch.staticTexts["可用的 App"].firstMatch
            if index == 8 { attachScreen("watch-scroll-end") }
        }
        attachScreen("watch-home-scrolled")
        if available.exists {
            available.tap()
            Thread.sleep(forTimeInterval: 3)
        }
        attachScreen("watch-available-list")

        let setmioRow = watch.staticTexts["Setmio"].firstMatch
        if setmioRow.waitForExistence(timeout: 5) {
            setmioRow.tap()
            Thread.sleep(forTimeInterval: 3)
        }
        attachScreen("watch-setmio-detail")

        let install = watch.buttons["安装"].firstMatch
        if install.waitForExistence(timeout: 5) {
            install.tap()
            Thread.sleep(forTimeInterval: 10)
        }
        attachScreen("watch-after-install")
        attachText("watch-after-install-hierarchy", watch.debugDescription)
    }

    /// Watch install, via the App row at the bottom of the Watch app's list: open it, find 可用的 App, look for Setmio.
    @MainActor
    func testWatchInstallViaAppRow() throws {
        let watch = XCUIApplication(bundleIdentifier: "com.apple.Bridge")
        watch.terminate()
        watch.launch()
        Thread.sleep(forTimeInterval: 4)

        var appRow = watch.staticTexts["App"].firstMatch
        for _ in 1...8 where !appRow.exists {
            watch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.1, thenDragTo: watch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
            Thread.sleep(forTimeInterval: 1)
            appRow = watch.staticTexts["App"].firstMatch
        }
        if appRow.exists {
            appRow.tap()
            Thread.sleep(forTimeInterval: 3)
        }
        attachScreen("watchapp-app-row")
        attachText("watchapp-app-row-hierarchy", watch.debugDescription)

        let available = watch.staticTexts["可用的 App"].firstMatch
        for _ in 1...6 where !available.exists {
            watch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.1, thenDragTo: watch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
            Thread.sleep(forTimeInterval: 1)
        }
        if available.exists {
            available.tap()
            Thread.sleep(forTimeInterval: 3)
        }
        attachScreen("watchapp-available")
        attachText("watchapp-available-hierarchy", watch.debugDescription)
    }

    /// Item 4 exploration: walk Health -> Browse -> 心肺 -> 心率变异性 -> add data, capturing each screen's buttons.
    /// Nothing is saved: the flow stops at the add-data form.
    @MainActor
    func testItem4ExploreHealthAddHRV() throws {
        XCUIApplication().terminate()
        let health = XCUIApplication(bundleIdentifier: "com.apple.Health")
        health.terminate()
        health.launch()
        Thread.sleep(forTimeInterval: 3)

        func snapshot(_ name: String) {
            attachScreen(name)
            let buttons = health.buttons.allElementsBoundByIndex.prefix(40).map { "\($0.label) | \($0.identifier)" }
            attachText(name + "-buttons", buttons.joined(separator: "\n"))
        }

        health.buttons.matching(identifier: "UIA.Health.Tab.Browse").firstMatch.tap()
        Thread.sleep(forTimeInterval: 2)
        snapshot("h4-1-browse")

        let heart = health.staticTexts["心肺"].firstMatch
        if heart.waitForExistence(timeout: 5) { heart.tap() }
        Thread.sleep(forTimeInterval: 2)
        snapshot("h4-2-heart")

        for _ in 0..<5 where !health.staticTexts["心率变异性"].firstMatch.exists {
            health.swipeUp()
            Thread.sleep(forTimeInterval: 1)
        }
        let hrv = health.staticTexts["心率变异性"].firstMatch
        if hrv.waitForExistence(timeout: 5) { hrv.tap() }
        Thread.sleep(forTimeInterval: 2)
        snapshot("h4-3-hrv")

        let add = health.buttons["添加数据"].firstMatch
        if add.waitForExistence(timeout: 5) { add.tap() }
        Thread.sleep(forTimeInterval: 2)
        snapshot("h4-4-add-form")
        attachText("h4-4-hierarchy", health.debugDescription)
    }

    /// Reads Settings -> 数据 (上次同步 / 上次导入 / 本地记录) without changing anything. Used before and after a manual step.
    @MainActor
    func testReadSyncStatus() throws {
        let app = XCUIApplication()
        app.activate()
        let tab = app.tabBars.buttons["设置"]
        XCTAssertTrue(tab.waitForExistence(timeout: 30), "main tabs should show (is the phone unlocked?)")
        tab.tap()
        Thread.sleep(forTimeInterval: 3)
        let labels = app.staticTexts.allElementsBoundByIndex
            .map(\.label)
            .filter { $0.contains("同步") || $0.contains("导入") || $0.contains("本地记录") }
        attachText("sync-status", labels.joined(separator: "\n") + "\n(read at \(Date()))")
        attachScreen("sync-status-screen")
    }
}
