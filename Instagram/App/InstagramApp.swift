import SwiftUI

@main
struct InstagramApp: App {
    @State private var app = AppModel()

    init() {
        #if DEBUG
        Task { await DebugProbe.runIfAsked() }
        Task { await DebugCreate.makeTestMediaIfAsked() }
        Task { @MainActor in DebugCapture.runIfAsked() }
        IconSheet.renderIfAsked()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .tint(Theme.accent)
                .frame(minWidth: 860, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 860)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { app.showSettings = true }
                    .keyboardShortcut(",")
            }
            CommandGroup(before: .toolbar) {
                Button(app.isSidebarCollapsed ? "Expand Sidebar" : "Collapse Sidebar") { app.toggleSidebar() }
                    .keyboardShortcut("s", modifiers: [.control, .command])
            }
        }
    }
}
