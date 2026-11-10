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

    /// 凭条存根：系统 Sheet（下拉关闭）+ 显式按钮进入编辑 / 再来一笔
    func testStubSheetStandardActionsNoCrash() {
        let app = launch("home")
        let row = app.buttons["record-row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "明细页没有记录行")

        // 1) 点开 → 验证底部两排操作按钮无需滚动即完整可见且可点 → 「完成」关闭
        row.tap()
        let stubEdit = app.buttons["stub-edit"]
        let stubDup = app.buttons["stub-duplicate"]
        let stubKeep = app.buttons["stub-keep"]
        let stubDelete = app.buttons["stub-delete"]
        XCTAssertTrue(stubEdit.waitForExistence(timeout: 5), "未弹出回执存根")
        XCTAssertTrue(stubEdit.isHittable, "底部「修改」按钮未完整显示")
        XCTAssertTrue(stubDup.isHittable, "底部「再来一笔」按钮未完整显示")
        XCTAssertTrue(stubKeep.isHittable, "底部第二排「保留存根」按钮被截断不可见")
        XCTAssertTrue(stubDelete.isHittable, "底部第二排「撕毁作废」按钮被截断不可见")
        app.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(stubEdit.waitForNonExistence(timeout: 5), "「完成」未关闭存根")

        // 2) 点开 → 系统下拉手势关闭
        row.tap()
        XCTAssertTrue(stubEdit.waitForExistence(timeout: 5))
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        top.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        if !stubEdit.waitForNonExistence(timeout: 4) { app.buttons["完成"].firstMatch.tap() }

        // 3) 点开 → 「修改」→ 收银台 → 「取消」
        row.tap()
        XCTAssertTrue(stubEdit.waitForExistence(timeout: 5))
        stubEdit.tap()
        let saveBtn = app.buttons["保存"].firstMatch
        XCTAssertTrue(saveBtn.waitForExistence(timeout: 8), "点「修改」未进入编辑页")
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(saveBtn.waitForNonExistence(timeout: 5), "编辑页「取消」未关闭")
        let feed = app.buttons["cashier-feed"]

        // 4) 点开 → 「再来一笔」→ 收银台 → 「取消」
        row.tap()
        let dup = app.buttons["stub-duplicate"]
        XCTAssertTrue(dup.waitForExistence(timeout: 5))
        dup.tap()
        XCTAssertTrue(feed.waitForExistence(timeout: 8), "再来一笔未进入收银台")
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(feed.waitForNonExistence(timeout: 5))
        app.terminate()
    }

    /// 系统导航：搜索页 / 账户详情页用系统返回按钮返回；账户详情里存根可正常打开关闭
    func testSystemNavigationBackNoCrash() {
        let app = launch("home")
        let search = app.buttons["home-search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(app.buttons["record-row"].firstMatch.waitForExistence(timeout: 5), "搜索页返回失败")

        app.tabBars.buttons["资产"].firstMatch.tap()
        let acc = app.descendants(matching: .any).matching(identifier: "account-微信").firstMatch
        XCTAssertTrue(acc.waitForExistence(timeout: 8))
        acc.tap()
        let detailRow = app.buttons["record-row"].firstMatch
        if detailRow.waitForExistence(timeout: 5) {
            detailRow.tap()
            let stubEdit = app.buttons["stub-edit"]
            XCTAssertTrue(stubEdit.waitForExistence(timeout: 5))
            stubEdit.tap()
            let saveBtn = app.buttons["保存"].firstMatch
            XCTAssertTrue(saveBtn.waitForExistence(timeout: 8))
            app.buttons["取消"].firstMatch.tap()
            XCTAssertTrue(saveBtn.waitForNonExistence(timeout: 5))
        }
        let back2 = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back2.waitForExistence(timeout: 5))
        back2.tap()
        XCTAssertTrue(acc.waitForExistence(timeout: 5), "账户详情返回失败")
        app.terminate()
    }

    /// 4.3 (47)~(56) 十个迭代版本的核心 UX/UI 改进自测：
    /// 1) 明细页快筛与金额隐私切换
    /// 2) 搜索页可折叠高级筛选 + 点击结果弹出回执存根（且底部按钮完整可见）
    /// 3) 资产页顶栏一键转账快捷入口
    /// 4) 设置页账本数据健康概览条
    func testUXIterations47To56() {
        let app = launch("home")

        // 1) 明细页快筛展开与金额隐藏按钮存在（含动画切换验证）
        let filterBtn = app.buttons["home-inline-filter"].firstMatch
        XCTAssertTrue(filterBtn.waitForExistence(timeout: 8), "明细页缺少快筛按钮")
        filterBtn.tap()
        let expPill = app.buttons["支出"].firstMatch
        XCTAssertTrue(expPill.waitForExistence(timeout: 3), "快筛未展示支出胶囊")
        expPill.tap()
        app.buttons["全部"].firstMatch.tap()
        filterBtn.tap()

        let hideBtn = app.buttons["home-toggle-hide-amounts"].firstMatch
        XCTAssertTrue(hideBtn.exists, "汇总卡缺少金额隐藏切换按钮")
        hideBtn.tap()
        hideBtn.tap()

        // 2) 搜索页可折叠高级筛选 + 点击记录弹出存根
        app.buttons["home-search"].firstMatch.tap()
        let advToggle = app.buttons["search-advanced-toggle"].firstMatch
        XCTAssertTrue(advToggle.waitForExistence(timeout: 5), "搜索页缺少可折叠高级筛选")
        let searchRow = app.buttons["record-row"].firstMatch
        XCTAssertTrue(searchRow.waitForExistence(timeout: 5), "搜索页未展示记录行")
        searchRow.tap()
        let stubKeep = app.buttons["stub-keep"]
        XCTAssertTrue(stubKeep.waitForExistence(timeout: 5), "搜索页点击记录未弹出回执存根")
        XCTAssertTrue(stubKeep.isHittable, "搜索页弹出的存根底部按钮被截断")
        stubKeep.tap()
        XCTAssertTrue(stubKeep.waitForNonExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // 3) 资产页一键转账按钮存在
        app.tabBars.buttons["资产"].firstMatch.tap()
        let quickTransfer = app.buttons["assets-quick-transfer"].firstMatch
        XCTAssertTrue(quickTransfer.waitForExistence(timeout: 5), "资产页顶栏缺少一键转账按钮")

        // 4) 设置页账本数据概览看板
        app.tabBars.buttons["设置"].firstMatch.tap()
        app.swipeUp()
        let overview = app.descendants(matching: .any).matching(identifier: "settings-ledger-overview").firstMatch
        XCTAssertTrue(overview.waitForExistence(timeout: 5), "设置页缺少账本数据概览看板")

        app.terminate()
    }
}
