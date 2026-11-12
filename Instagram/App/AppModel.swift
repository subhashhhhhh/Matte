import SwiftUI
import OSLog

/// Central state: the session, the API client and navigation.
@Observable
final class AppModel {
    enum AuthState: Equatable { case signedOut, signedIn }

    private(set) var authState: AuthState = .signedOut
    private(set) var client: IGClient?
    var showSignIn = false

    @ObservationIgnored private let log = Logger(subsystem: "com.subhash.Instagram", category: "App")

    init() {
        if let session = IGSession.restore() {
            client = IGClient(session: session)
            authState = .signedIn
        }
    }

    func completeSignIn(_ cookies: [StoredCookie]) {
        SessionStore.shared.save(cookies)
        let session = IGSession(cookies: cookies)
        client = IGClient(session: session)
        authState = .signedIn
        showSignIn = false
        log.info("Signed in")
    }

    func signOut() {
        let old = client
        Task { await old?.session.end() }
        SessionStore.shared.clear()
        client = nil
        authState = .signedOut
    }
}
