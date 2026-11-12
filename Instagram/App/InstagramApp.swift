import SwiftUI

@main
struct InstagramApp: App {
    @State private var app = AppModel()

    init() {
        #if DEBUG
        Task { await DebugProbe.runIfAsked() }
        Task { @MainActor in DebugCapture.runIfAsked() }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .tint(Theme.accent)
                .frame(minWidth: 760, minHeight: 520)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1180, height: 860)
    }
}
