import AppIntents

/// 系统「快捷指令」App 与 Siri 中自动出现的快捷指令
struct LedgerShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RecognizeReceiptIntent(),
            phrases: [
                "用\(.applicationName)识图记账",
                "\(.applicationName)识图记账",
                "\(.applicationName)识别截图记账",
            ],
            shortTitle: "识图记账",
            systemImageName: "text.viewfinder"
        )
        AppShortcut(
            intent: AddRecordIntent(),
            phrases: [
                "用\(.applicationName)记一笔",
                "\(.applicationName)记一笔",
                "在\(.applicationName)记账",
            ],
            shortTitle: "记一笔",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: MonthSummaryIntent(),
            phrases: [
                "\(.applicationName)本月收支",
                "\(.applicationName)这个月花了多少",
            ],
            shortTitle: "本月收支",
            systemImageName: "chart.pie.fill"
        )
    }
}
