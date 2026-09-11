import SwiftUI

@main struct OuchikaeruApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            HomeView(model: model).tint(Color.ouchiGreen).task {
                WatchSync.shared.refreshHandler = { await model.refresh() }
                await model.refresh()
            }.onChange(of: scenePhase) { _, phase in if phase == .active { Task { await model.refresh() } } }
        }
    }
}
