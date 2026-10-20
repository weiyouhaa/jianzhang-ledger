import XCTest

/// 回归：长按账户 →「修改余额」弹出的 sheet 不能自己消失（真实 / 防窥会话 / 编辑防窥数据）
final class QuickBalanceSheetUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UIScreenshotDemo", screen, "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
    }

    private func runQuickBalance(screen: String, account: String, file: StaticString = #filePath, line: UInt = #line) {
        let app = launch(screen)
        let row = app.descendants(matching: .any).matching(identifier: "account-" + account).firstMatch
        if !row.waitForExistence(timeout: 15) {
            print("UI-DUMP-BEGIN\n\(app.debugDescription)\nUI-DUMP-END")
            XCTFail("找不到账户行 \(account)", file: file, line: line)
            return
        }
        row.press(forDuration: 1.2)
        let menuItem = app.buttons["修改余额"].firstMatch
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "长按菜单没有「修改余额」", file: file, line: line)
        menuItem.tap()
        let field = app.textFields["quickbalance-field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "修改余额 sheet 没有出现", file: file, line: line)
        // 关键：等 3 秒后 sheet 仍在
        Thread.sleep(forTimeInterval: 3)
        if !field.exists { print("UI-DUMP-BEGIN\n\(app.debugDescription)\nUI-DUMP-END") }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "quickbalance-\(screen)"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(field.exists, "修改余额 sheet 弹出后自己消失了（\(screen)）", file: file, line: line)
        // 能输入
        field.tap()
        field.typeText("1")
        XCTAssertTrue(field.exists, "输入后 sheet 消失（\(screen)）", file: file, line: line)
    }

    func testRealModeQuickBalanceStays() {
        runQuickBalance(screen: "assets", account: "微信")
    }

    func testDecoySessionQuickBalanceStays() {
        runQuickBalance(screen: "decoyassets", account: "微信")
    }

    func testDecoyEditorQuickBalanceStays() {
        runQuickBalance(screen: "decoyeditor", account: "微信")
    }
}
