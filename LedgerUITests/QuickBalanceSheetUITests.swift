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

    // MARK: - 编辑防窥数据：顶栏不能盖住子页面的导航栏按钮

    private func assertBelowBar(_ app: XCUIApplication, _ element: XCUIElement, _ name: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 15), "找不到 \(name)", file: file, line: line)
        XCTAssertTrue(element.isHittable, "\(name) 不可点（被顶栏遮住？）", file: file, line: line)
        let bar = app.descendants(matching: .any).matching(identifier: "decoy-editor-done").firstMatch
        XCTAssertTrue(bar.exists, "找不到「完成」", file: file, line: line)
        XCTAssertTrue(bar.isHittable, "「完成」不可点", file: file, line: line)
        let barBottom = app.descendants(matching: .any).matching(identifier: "decoy-editor-bar").firstMatch
        let limit = barBottom.exists ? barBottom.frame.maxY : bar.frame.maxY
        XCTAssertGreaterThanOrEqual(element.frame.minY + 0.5, limit,
                                    "\(name) 顶部 \(element.frame.minY) 在顶栏底部 \(limit) 之上", file: file, line: line)
    }

    func testDecoyEditorTopBarDoesNotCoverChildButtons() {
        let app = launch("decoyeditorhome")
        let search = app.descendants(matching: .any).matching(identifier: "home-search").firstMatch
        assertBelowBar(app, search, "明细页右上角搜索")
        search.tap()
        XCTAssertTrue(app.navigationBars["搜索"].waitForExistence(timeout: 5)
                      || app.staticTexts["筛选"].waitForExistence(timeout: 5), "点搜索没有进入搜索页")
        let back = app.navigationBars["搜索"].buttons.element(boundBy: 0)
        if back.exists { back.tap() }

        app.tabBars.buttons["资产"].firstMatch.tap()
        let add = app.descendants(matching: .any).matching(identifier: "assets-add-menu").firstMatch
        assertBelowBar(app, add, "资产页右上角添加")

        app.tabBars.buttons["说明"].firstMatch.tap()
        let title = app.navigationBars["说明"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "说明页导航栏不见了")
        XCTAssertGreaterThanOrEqual(title.frame.minY + 0.5,
                                    app.descendants(matching: .any).matching(identifier: "decoy-editor-bar").firstMatch.frame.maxY,
                                    "说明页导航栏被顶栏盖住")
    }

    // MARK: - 编辑防窥数据读防窥偏好；真实首页仍读真实偏好

    private func text(_ app: XCUIApplication, containing s: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }

    func testDecoyEditorShowsDecoyBudgetRealHomeShowsReal() {
        let app = launch("decoyeditorhome")
        // 编辑器里：防窥预算 ¥3,000，不能出现真实预算 ¥5,000
        XCTAssertTrue(text(app, containing: "3,000.00").waitForExistence(timeout: 15), "编辑防窥数据没有显示防窥预算 ¥3,000")
        XCTAssertFalse(text(app, containing: "5,000.00").exists, "编辑防窥数据里出现了真实预算 ¥5,000")

        // 关闭编辑器回到真实界面：明细页显示真实预算 ¥5,000
        app.descendants(matching: .any).matching(identifier: "decoy-editor-done").firstMatch.tap()
        let homeTab = app.tabBars.buttons["明细"].firstMatch
        XCTAssertTrue(homeTab.waitForExistence(timeout: 5))
        homeTab.tap()
        XCTAssertTrue(text(app, containing: "5,000.00").waitForExistence(timeout: 10), "真实首页没有显示真实预算 ¥5,000")
        XCTAssertFalse(text(app, containing: "3,000.00").exists, "真实首页出现了防窥预算 ¥3,000")
    }

    func testRealHomeShowsRealBudget() {
        let app = launch("home")
        XCTAssertTrue(text(app, containing: "5,000.00").waitForExistence(timeout: 15), "真实首页没有显示真实预算 ¥5,000")
        XCTAssertFalse(text(app, containing: "3,000.00").exists, "真实首页出现了防窥预算 ¥3,000")
    }
}
