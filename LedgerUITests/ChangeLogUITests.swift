import XCTest

/// 变动日志：真实账本的编辑会生成带字段差异的日志；防窥会话的编辑不生成任何日志
final class ChangeLogUITests: XCTestCase {
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

    private func probeCount(_ app: XCUIApplication) -> Int {
        let probe = app.staticTexts["debug-changelog-count"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 10), "找不到日志计数探针")
        return Int(probe.label) ?? -1
    }

    private func waitForCount(_ app: XCUIApplication, _ predicate: (Int) -> Bool, timeout: TimeInterval = 8) -> Int {
        let end = Date().addingTimeInterval(timeout)
        var n = probeCount(app)
        while !predicate(n) && Date() < end {
            Thread.sleep(forTimeInterval: 0.5)
            n = probeCount(app)
        }
        return n
    }

    /// 打开某条记录、在备注后追加文字并保存
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func editNote(_ app: XCUIApplication, row: String, append: String) {
        // 3.8 (29)：先等标题出现，再点 record-row（带 accessibilityLabel）
        _ = app.staticTexts[row].firstMatch.waitForExistence(timeout: 15)
        let byId = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "record-row", row)
        ).firstMatch
        let cell = byId.waitForExistence(timeout: 5) ? byId : app.staticTexts[row].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "找不到记录「\(row)」")
        cell.tap()
        // 编辑页打开的可靠信号：导航栏「保存」；备注可能在表单下方需上滑
        let save = app.buttons["保存"].firstMatch
        if !save.waitForExistence(timeout: 6) {
            dumpHierarchy(app, "edit-not-open-\(row)")
        }
        XCTAssertTrue(save.exists, "点「\(row)」后没有打开编辑页")
        var note = element(app, "editor-note")
        if !note.waitForExistence(timeout: 3) {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.4)
        }
        if !note.exists {
            let byValue = app.textFields[row].firstMatch
            let byPlaceholder = app.textFields["备注"].firstMatch
            if byValue.exists { note = byValue }
            else if byPlaceholder.exists { note = byPlaceholder }
        }
        if !note.waitForExistence(timeout: 4) {
            dumpHierarchy(app, "edit-no-note-\(row)")
        }
        XCTAssertTrue(note.exists, "编辑页没有备注输入框")
        note.tap()
        note.typeText(append)
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        save.tap()
        XCTAssertTrue(note.waitForNonExistence(timeout: 5) || save.waitForNonExistence(timeout: 5),
                      "保存后编辑页没有关闭")
    }

    private func dumpHierarchy(_ app: XCUIApplication, _ name: String) {
        print("UI-DUMP-BEGIN \(name)\n\(app.debugDescription)\nUI-DUMP-END")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testRealTransactionEditCreatesLogEntryWithDiff() {
        let app = launch("home")
        let before = probeCount(app)
        editNote(app, row: "早餐", append: "改")
        let after = waitForCount(app) { $0 > before }
        XCTAssertGreaterThan(after, before, "编辑真实记录后没有生成变动日志")

        // 设置 › 变动日志 › 第一条：备注 早餐 → 早餐改
        app.tabBars.buttons["设置"].firstMatch.tap()
        let link = app.descendants(matching: .any).matching(identifier: "settings-changelog").firstMatch
        var tries = 0
        while !(link.exists && link.isHittable) && tries < 8 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(link.exists, "设置里没有「变动日志」")
        link.tap()
        let row = app.descendants(matching: .any).matching(identifier: "changelog-row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "变动日志列表为空")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "改")).firstMatch.exists,
                      "列表摘要里没有新的备注")
        row.tap()
        let old = app.staticTexts["diff-old-备注"].firstMatch
        let new = app.staticTexts["diff-new-备注"].firstMatch
        XCTAssertTrue(old.waitForExistence(timeout: 5), "详情里没有备注的旧值")
        XCTAssertEqual(old.label, "早餐")
        XCTAssertTrue(new.exists, "详情里没有备注的新值")
        XCTAssertTrue(new.label.hasPrefix("早") && new.label.contains("改"), "备注新值不对：\(new.label)")
        // LabeledContent 会把「操作」与值合成一个辅助功能元素
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "修改")).firstMatch.exists,
                      "操作不是「修改」")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "changelog-detail"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testDecoySessionEditCreatesNoLogEntry() {
        let app = launch("decoyhome")
        let before = probeCount(app)
        XCTAssertGreaterThanOrEqual(before, 0)
        editNote(app, row: "晚饭外卖", append: "改")
        // 给日志写入留足时间，再确认计数没变
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(probeCount(app), before, "防窥会话里的编辑写进了变动日志")
        // 防窥会话的设置里没有「变动日志」
        app.tabBars.buttons["设置"].firstMatch.tap()
        for _ in 0..<4 { app.swipeUp() }
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "settings-changelog").firstMatch.exists,
                       "防窥会话显示了「变动日志」入口")
    }
}
