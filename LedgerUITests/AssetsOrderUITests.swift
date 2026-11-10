import XCTest

/// 4.3 (35)：资产页账户顺序必须与「排序与归档」逐行一致。合成演示数据。
final class AssetsOrderUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    func testAssetsOrderMatchesManager() {
        let app = XCUIApplication()
        app.launchArguments = ["-UIScreenshotDemo", "assets", "-appearance.skin", "receipt",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()

        let first = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'account-'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'account-'"))
            .allElementsBoundByIndex
        var seen = Set<String>()
        let pageOrder = rows
            .sorted { $0.frame.minY < $1.frame.minY }
            .map { String($0.identifier.dropFirst("account-".count)) }
            .filter { seen.insert($0).inserted }
        print("UI-DUMP assets order: \(pageOrder.joined(separator: " | "))")

        app.buttons["assets-add-menu"].tap()
        app.buttons["排序与归档"].tap()
        XCTAssertTrue(app.navigationBars["排序与归档"].waitForExistence(timeout: 5))
        sleep(1)
        let cells = app.cells.allElementsBoundByIndex.sorted { $0.frame.minY < $1.frame.minY }
        let managerNames = cells.compactMap { cell -> String? in
            cell.staticTexts.allElementsBoundByIndex.first?.label
        }
        let managerOrder = managerNames.filter { pageOrder.contains($0) }
        print("UI-DUMP manager order: \(managerOrder.joined(separator: " | "))")
        XCTAssertEqual(pageOrder, Array(managerOrder.prefix(pageOrder.count)), "资产页顺序与「排序与归档」不一致")
    }
}
