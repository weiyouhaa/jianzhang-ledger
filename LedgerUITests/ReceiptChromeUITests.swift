import XCTest

/// 3.3 (24)：小票皮肤下标签页根页面的标题必须真的显示出来（3.2 只剩一块空白）。合成演示数据。
final class ReceiptChromeUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UIScreenshotDemo", screen, "-appearance.skin", "receipt",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
    }

    func testReceiptTabRootTitlesVisible() {
        for (screen, title) in [("home", "简账"), ("stats", "统计"), ("assets", "资产"), ("settings", "设置")] {
            let app = launch(screen)
            let bar = app.navigationBars.firstMatch
            XCTAssertTrue(bar.waitForExistence(timeout: 10), "\(screen) 没有导航栏")
            print("UI-DUMP receipt \(screen) bar=\(bar.frame)")
            print("UI-DUMP " + bar.debugDescription.replacingOccurrences(of: "\n", with: "\nUI-DUMP "))
            let label = bar.staticTexts[title]
            XCTAssertTrue(label.exists, "\(screen) 导航栏里没有标题「\(title)」")
            app.terminate()
        }
    }
}
