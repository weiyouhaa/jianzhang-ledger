import XCTest

/// 信用卡还款：支出页「信用卡还款」与资产页长按信用卡「还款」。
/// 保存后付款账户减少、信用卡欠款同步减少（全额还款后再打开，已没有「全额还款」按钮），并写入变动日志。
final class CardRepaymentUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UIScreenshotDemo", screen, "-UITestChangeLogProbe",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func probeCount(_ app: XCUIApplication) -> Int {
        let probe = app.staticTexts["debug-changelog-count"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 10), "找不到日志计数探针")
        return Int(probe.label) ?? -1
    }

    private func waitForCount(_ app: XCUIApplication, above before: Int, timeout: TimeInterval = 8) -> Int {
        let end = Date().addingTimeInterval(timeout)
        var n = probeCount(app)
        while n <= before && Date() < end {
            Thread.sleep(forTimeInterval: 0.5)
            n = probeCount(app)
        }
        return n
    }

    private func dump(_ app: XCUIApplication, _ name: String) {
        print("UI-DUMP-BEGIN \(name)\n\(app.debugDescription)\nUI-DUMP-END")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// 资产页长按信用卡 →「还款」，返回是否打开了还款表单
    private func openRepayFromAssets(_ app: XCUIApplication, card: String) {
        // 列表是懒加载的：负债分组在下面，先等页面出来，再上滑直到信用卡行可点
        XCTAssertTrue(element(app, "account-微信").waitForExistence(timeout: 15) || element(app, "account-" + card).exists,
                      "资产页没有出现")
        let row = element(app, "account-" + card)
        var tries = 0
        while !(row.exists && row.isHittable) && tries < 8 {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.4)
            tries += 1
        }
        if !row.exists { dump(app, "repay-assets") }
        XCTAssertTrue(row.exists, "找不到账户行 \(card)")
        row.press(forDuration: 1.2)
        let item = app.buttons["还款"].firstMatch
        if !item.waitForExistence(timeout: 5) { dump(app, "repay-menu") }
        XCTAssertTrue(item.exists, "长按信用卡没有「还款」")
        item.tap()
        // 3.8 (29)：等菜单退场 + sheet（present 延迟约 1.0s）；repay-form / repay-from 探针
        Thread.sleep(forTimeInterval: 1.2)
        let form = element(app, "repay-form")
        let cardPicker = element(app, "repay-card")
        let from = element(app, "repay-from")
        let end = Date().addingTimeInterval(12)
        while !(form.exists || cardPicker.exists || from.exists) && Date() < end {
            Thread.sleep(forTimeInterval: 0.4)
        }
        if !(form.exists || cardPicker.exists || from.exists) { dump(app, "repay-form") }
        XCTAssertTrue(form.exists || cardPicker.exists || from.exists, "没有打开信用卡还款表单")
    }

    func testFullRepaymentFromAssetsClearsCardDebt() {
        let app = launch("assets")
        let before = probeCount(app)
        openRepayFromAssets(app, card: "招行信用卡")
        XCTAssertTrue(element(app, "repay-from").exists || element(app, "repay-form").exists || element(app, "repay-card").exists,
                      "缺少付款账户 / 还款表单")
        // 全额按钮在还款区下部；账户 Query 补全后才会出现
        app.swipeUp()
        let full = app.descendants(matching: .any).matching(identifier: "repay-full").firstMatch
        let fullEnd = Date().addingTimeInterval(6)
        while !full.exists && Date() < fullEnd { Thread.sleep(forTimeInterval: 0.4) }
        if !full.exists { dump(app, "repay-full-missing") }
        XCTAssertTrue(full.exists, "信用卡有欠款时应显示「全额还款」")
        XCTAssertTrue(full.label.contains("全额还款"), "按钮文字：\(full.label)")
        full.tap()
        let save = app.buttons["保存"].firstMatch
        XCTAssertTrue(save.isEnabled, "填好全额后保存应可用")
        save.tap()
        let closed = element(app, "repay-form").waitForNonExistence(timeout: 5)
            || element(app, "repay-card").waitForNonExistence(timeout: 2)
            || element(app, "repay-from").waitForNonExistence(timeout: 2)
        XCTAssertTrue(closed, "保存后表单没有关闭")

        // 变动日志：新增一条流水
        XCTAssertGreaterThan(waitForCount(app, above: before), before, "还款没有写入变动日志")

        // 欠款已清零：再次打开还款，已没有「全额还款」
        Thread.sleep(forTimeInterval: 1)
        openRepayFromAssets(app, card: "招行信用卡")
        Thread.sleep(forTimeInterval: 1)
        app.swipeUp()
        let fullAfter = app.descendants(matching: .any).matching(identifier: "repay-full").firstMatch
        if fullAfter.exists { dump(app, "repay-after-full") }
        XCTAssertFalse(fullAfter.exists, "全额还款后信用卡仍有欠款")
        app.buttons["取消"].firstMatch.tap()
    }

    func testExpenseTileCreatesRepaymentRow() {
        let app = launch("home")
        let before = probeCount(app)
        let routes = app.staticTexts.matching(identifier: "repayment-route")
        _ = app.staticTexts["早餐"].firstMatch.waitForExistence(timeout: 15)
        let routesBefore = routes.count

        let add = element(app, "home-add")
        XCTAssertTrue(add.waitForExistence(timeout: 10), "找不到记一笔按钮")
        add.tap()
        let tile = element(app, "tile-card-repayment")
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "支出分类里没有「信用卡还款」")
        tile.tap()
        // 还款区在分类网格下方，Form 懒加载时需要滑一下才进 a11y 树
        Thread.sleep(forTimeInterval: 0.5)
        app.swipeUp()
        let form = element(app, "repay-form")
        let cardPicker = element(app, "repay-card")
        let from = element(app, "repay-from")
        let end = Date().addingTimeInterval(8)
        while !(form.exists || cardPicker.exists || from.exists) && Date() < end {
            Thread.sleep(forTimeInterval: 0.4)
        }
        if !(form.exists || cardPicker.exists || from.exists) {
            // 再试一次：按可见标题点
            let byLabel = app.buttons["信用卡还款"].firstMatch
            if byLabel.exists { byLabel.tap(); Thread.sleep(forTimeInterval: 0.5); app.swipeUp() }
            dump(app, "repay-tile")
        }
        XCTAssertTrue(form.exists || cardPicker.exists || from.exists,
                      "点「信用卡还款」后没有出现还款信用卡")
        // 还款模式隐藏商户：identifier 或 placeholder 都不应出现
        XCTAssertFalse(element(app, "editor-merchant").exists || app.textFields["商户（可选）"].exists,
                       "还款模式不应显示商户")

        let amount = app.textFields["0.00"].firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 3))
        amount.tap()
        amount.typeText("100")
        app.buttons["保存"].firstMatch.tap()
        XCTAssertTrue(tile.waitForNonExistence(timeout: 5), "保存后编辑页没有关闭")

        XCTAssertGreaterThan(waitForCount(app, above: before), before, "还款没有写入变动日志")
        let end = Date().addingTimeInterval(5)
        while routes.count <= routesBefore && Date() < end { Thread.sleep(forTimeInterval: 0.3) }
        if routes.count <= routesBefore { dump(app, "repay-home") }
        XCTAssertGreaterThan(routes.count, routesBefore, "明细里没有新的「付款账户 → 信用卡」还款行")
        XCTAssertTrue(routes.firstMatch.label.contains("→"), "还款行副标题：\(routes.firstMatch.label)")
    }
}
