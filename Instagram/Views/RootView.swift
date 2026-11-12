import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            switch app.authState {
            case .signedOut:
                EmptyState(symbol: "camera", title: "Instagram",
                           message: "Sign in on Instagram's own page. The session stays on this Mac.",
                           actionTitle: "Sign In") { app.showSignIn = true }
            case .signedIn:
                EmptyState(symbol: "checkmark.circle", title: "Signed in", message: "The native client is being built.",
                           actionTitle: "Sign Out") { app.signOut() }
            }
        }
        .background(Theme.background)
        .sheet(isPresented: $app.showSignIn) {
            SignInView(onComplete: { app.completeSignIn($0) }, onCancel: { app.showSignIn = false })
        }
    }
}
