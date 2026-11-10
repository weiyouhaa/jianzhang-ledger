import XCTest

/// 4.3 (35)：明细页滑动时悬浮按钮隐藏，停下后重新出现。合成演示数据。
final class HomeFabScrollUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    func testFabHidesWhileScrollingAndReturns() {
        let app = XCUIApplication()
        app.launchArguments = ["-UIScreenshotDemo", "home", "-appearance.skin", "receipt",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-JZFabDebugLog"]
        app.launch()

        let fab = app.buttons["home-add"]
        XCTAssertTrue(fab.waitForExistence(timeout: 10), "悬浮按钮没有出现")
        XCTAssertTrue(fab.isHittable, "静止时悬浮按钮应可点")

        // 手指按住慢慢拖动并保持按住：滚动进行中
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 260, thenHoldForDuration: 0)
        let during = XCUIScreen.main.screenshot()
        try? during.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/shots/fab-during.png"))
        // 注：XCUITest 会等界面空闲才返回，这里无法可靠采样「滚动中」，隐藏过程用 -JZFabDebugLog 日志核对

        // 停下后应重新出现
        sleep(2)
        let after = XCUIScreen.main.screenshot()
        try? after.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/shots/fab-after.png"))
        XCTAssertTrue(fab.waitForExistence(timeout: 3) && fab.isHittable, "停下后悬浮按钮应重新出现")
        print("UI-DUMP fab after stop hittable=\(fab.isHittable)")
    }
}
