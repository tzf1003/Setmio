import XCTest

/// M1 acceptance in the simulator: first launch → onboarding (profile → skip HealthKit → pick a template) →
/// Settings → 演示数据 on → 「今日」 shows the readiness score and its components.
final class OnboardingAndDemoUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testOnboardingThenDemoDataShowsReadiness() throws {
        let app = XCUIApplication()
        app.launch()

        // Step 1 — profile.
        XCTAssertTrue(app.staticTexts["基本档案"].waitForExistence(timeout: 20), "onboarding profile step should appear on first launch")
        attach(app, "1-onboarding-profile")
        app.buttons["下一步"].tap()

        // Step 2 — HealthKit: skip (the system sheet is covered by the device checklist).
        XCTAssertTrue(app.buttons["稍后在设置中授权"].waitForExistence(timeout: 5))
        attach(app, "2-onboarding-health")
        app.buttons["稍后在设置中授权"].tap()

        // Step 3 — program template.
        let create = app.buttons["生成训练周期"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["训练模板"].exists)
        attach(app, "3-onboarding-program")
        create.tap()

        // Today tab with a plan (no readiness yet: nothing imported).
        XCTAssertTrue(app.staticTexts["今日准备度"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["今日训练"].exists)
        attach(app, "4-today-before-demo")

        // Settings → demo data.
        app.tabBars.buttons["设置"].tap()
        let toggle = app.switches["使用演示数据（60 天）"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        // A plain tap hits the middle of the row, which does not flip a Form switch; aim at the knob on the right edge.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1", "demo data switch should be on")

        // Back to Today: the readiness card shows a score (the gauge) and component rows, not 「数据不足」.
        app.tabBars.buttons["今日"].tap()
        let baseline = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "基线 ")).firstMatch
        XCTAssertTrue(baseline.waitForExistence(timeout: 30), "readiness details should appear once the demo data is imported")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "数据不足")).firstMatch.exists)
        attach(app, "5-today-with-demo-readiness")
    }
}
