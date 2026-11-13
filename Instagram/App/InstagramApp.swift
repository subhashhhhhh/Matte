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
        // `-IGRenderWelcome <file.png>`: draws the signed-out screen (1180×780, dark) to a PNG
        // without showing a window, and quits.
        if let out = UserDefaults.standard.string(forKey: "IGRenderWelcome") {
            NSApplication.shared.setActivationPolicy(.prohibited)
            let model = app
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                let view = WelcomeView(animated: false).environment(model).frame(width: 1180, height: 780)
                    .environment(\.colorScheme, .dark).background(Theme.background)
                let r = ImageRenderer(content: view)
                r.scale = 2
                if let cg = r.cgImage, let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, cg, nil)
                    CGImageDestinationFinalize(dest)
                }
                exit(0)
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .tint(Theme.accent)
                .frame(minWidth: 860, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1180, height: 860)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { app.showSettings = true }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .sidebar) {
                Button(app.isSidebarCollapsed ? "Expand Sidebar" : "Collapse Sidebar") { app.toggleSidebar() }
                    .keyboardShortcut("s")
            }
        }
    }
}
