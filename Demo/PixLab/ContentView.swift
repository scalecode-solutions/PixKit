import SwiftUI
import PixKit
import MvAuth

struct ContentView: View {
    @State private var auth = AuthModel()
    @Environment(\.scenePhase) private var phase

    var body: some View {
        content
            // The app switcher shows a blank screen, never a space (a host's
            // job, not the kit's: every host does it its own way).
            .overlay { if phase != .active { BlankScreen() } }
    }

    @ViewBuilder private var content: some View {
        #if DEBUG
        if let dev = DevSignIn.fromEnvironment() {
            PixLabHost(userID: dev.user, server: .local, tokenProvider: { dev.token }, signOut: {})
        } else {
            signedIn
        }
        #else
        signedIn
        #endif
    }

    @ViewBuilder private var signedIn: some View {
        switch auth.state {
        case .loggedIn(let profile):
            PixLabHost(userID: profile.userID, server: auth.server,
                       tokenProvider: { [auth] in await auth.accessToken() },
                       signOut: { auth.logOut() })
                .id(profile.userID) // a fresh kit per identity
        default:
            LoginView(auth: auth)
        }
    }
}

/// What the app switcher sees.
struct BlankScreen: View {
    var body: some View {
        Rectangle().fill(.background).ignoresSafeArea()
            .accessibilityIdentifier("lab.blankScreen")
    }
}

#if DEBUG
/// Debug-only: skip the login with a token minted from the LOCAL key
/// (launch environment PIX_DEV_TOKEN + PIX_DEV_USER). Only meaningful against
/// the local stack; compiled out of release builds.
struct DevSignIn {
    let token: String
    let user: String

    static func fromEnvironment() -> DevSignIn? {
        let e = ProcessInfo.processInfo.environment
        guard let t = e["PIX_DEV_TOKEN"], let u = e["PIX_DEV_USER"], UUID(uuidString: u) != nil else { return nil }
        return DevSignIn(token: t, user: u)
    }
}
#endif

/// The dev host: builds the kit's config with the Lab's token provider and
/// shows the shell. Until PixEngine (C3) and the space UI (C4) land, the shell
/// talks to the transport directly.
struct PixLabHost: View {
    let userID: String
    let server: LabServer
    let signOut: () -> Void
    let config: PixConfig

    init(userID: String, server: LabServer, tokenProvider: @escaping @Sendable () async -> String?, signOut: @escaping () -> Void) {
        self.userID = userID
        self.server = server
        self.signOut = signOut
        self.config = PixConfig(baseURL: server.pixBaseURL,
                                currentUserID: UUID(uuidString: userID) ?? UUID(),
                                tokenProvider: tokenProvider)
    }

    var body: some View {
        LabShell(config: config) { account }
    }

    /// PixLab's own rows.
    private var account: some View {
        Section("Account") {
            LabeledContent("User ID") { Text(userID).font(.caption.monospaced()).textSelection(.enabled) }
            LabeledContent("Server", value: server.rawValue)
            Button("Sign out", role: .destructive) { signOut() }
        }
    }
}
