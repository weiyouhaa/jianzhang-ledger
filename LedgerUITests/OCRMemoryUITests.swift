import XCTest

/// 内存测量：合成 1290×2796 截图走快捷指令识别路径的 phys_footprint 峰值；运行日志入口可见
final class OCRMemoryUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testOCRPeakMemory() {
        let app = XCUIApplication()
        app.launchArguments = ["-UIScreenshotDemo", "home", "-UITestOCRMemoryProbe",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let probe = app.staticTexts["debug-ocr-memory"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 20), "找不到内存探针")
        let end = Date().addingTimeInterval(120)
        while !probe.label.hasPrefix("done") && Date() < end { Thread.sleep(forTimeInterval: 1) }
        let label = probe.label
        print("OCR-MEMORY-TEST " + label)
        XCTAssertTrue(label.hasPrefix("done"), "识别未完成：\(label)")
        XCTAssertTrue(label.contains("amountOK=yes"), "合成截图金额识别失败：\(label)")
    }

    func testRunLogViewer() {
        let app = XCUIApplication()
        app.launchArguments = ["-UIScreenshotDemo", "settings",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let link = app.descendants(matching: .any).matching(identifier: "settings-run-log").firstMatch
        var tries = 0
        while !(link.exists && link.isHittable) && tries < 12 {
            app.swipeUp()
            tries += 1
        }
        if !link.exists { print("UI-DUMP-BEGIN\n\(app.debugDescription)\nUI-DUMP-END") }
        XCTAssertTrue(link.waitForExistence(timeout: 5), "设置中没有运行日志入口")
        link.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "runlog-copy").firstMatch.waitForExistence(timeout: 5), "没有「复制全部」")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "runlog-clear").firstMatch.exists, "没有「清空」")
        let export = app.descendants(matching: .any).matching(identifier: "runlog-export").firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 5), "没有「导出日志」")
        // 启动日志应已写入
        let launchLine = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "启动：")).firstMatch
        XCTAssertTrue(launchLine.waitForExistence(timeout: 5), "日志里没有启动记录")
        print("RUNLOG-TEST viewer ok")
    }

    func testAboutShowsVersion() {
        let app = XCUIApplication()
        app.launchArguments = ["-UIScreenshotDemo", "settings",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let row = app.descendants(matching: .any).matching(identifier: "about-version-row").firstMatch
        var tries = 0
        while !(row.exists && row.isHittable) && tries < 15 { app.swipeUp(); tries += 1 }
        XCTAssertTrue(row.exists, "关于里没有版本行")
        print("VERSION-TEST " + row.label)
        XCTAssertTrue(row.label.contains("2.0 (2)"), "版本：\(row.label)")
    }
}
