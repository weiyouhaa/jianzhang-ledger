import XCTest

/// 设置 › 智能记账 ›「识别引擎」：有选项和 Apple 智能状态行（CI 模拟器通常没有端侧模型，只检查显示）
final class OCREngineSettingsUITests: XCTestCase {
    func testEngineSettingShowsStatus() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-UIScreenshotDemo", "settings", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let picker = app.descendants(matching: .any).matching(identifier: "ocr-engine-picker").firstMatch
        var tries = 0
        while !(picker.exists && picker.isHittable) && tries < 10 { app.swipeUp(); tries += 1 }
        if !picker.exists { print("UI-DUMP-BEGIN\n\(app.debugDescription)\nUI-DUMP-END") }
        XCTAssertTrue(picker.exists, "设置里没有「识别引擎」")
        let status = app.descendants(matching: .any).matching(identifier: "ai-status").firstMatch
        let label = status.exists ? status.label : picker.label
        print("AI-STATUS: \(label)")
        let known = ["Apple 智能 可用", "设备不支持", "未开启", "模型下载中", "不支持", "需要 iOS 26", "暂不可用"]
        XCTAssertTrue(known.contains(where: { label.contains($0) }), "状态行：\(label)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "ocr-engine-setting"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
