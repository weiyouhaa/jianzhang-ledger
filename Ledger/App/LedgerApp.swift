import SwiftUI
import SwiftData

@main
struct LedgerApp: App {
    @StateObject private var lock = AppLockManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(lock)
        }
        .modelContainer(DataStore.shared)
    }
}
