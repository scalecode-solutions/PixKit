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
        if let dev = DevSignIn.fromEnvironment(), let user = UUID(uuidString: dev.user) {
            PixLabHost(userID: user, server: .local, tokenProvider: { dev.token }, signOut: {})
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
            if let user = UUID(uuidString: profile.userID) {
                PixLabHost(userID: user, server: auth.server,
                           tokenProvider: { [auth] in await auth.accessToken() },
                           signOut: { auth.logOut() })
                    .id(user) // a fresh kit per identity
            } else {
                // A profile id is always a UUID; anything else must not become
                // a random account with its own storage.
                ContentUnavailableView("This account's id can't be used", systemImage: "exclamationmark.triangle",
                                       description: Text(profile.userID))
                    .overlay(alignment: .bottom) { Button("Sign out") { auth.logOut() }.padding() }
            }
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

/// The dev host: builds the kit's config with the Lab's token provider, one
/// engine per signed-in identity (the caller gives each its own `.id`), and
/// shows the shell.
struct PixLabHost: View {
    let userID: UUID
    let server: LabServer
    let signOut: () -> Void
    let config: PixConfig
    /// Holds the one engine. SwiftUI re-runs this view's init on every parent
    /// render (each scene-phase change, a permission prompt included) and
    /// keeps only the first State, so the engine is built lazily inside a
    /// holder, never in init: a throwaway engine, cache or uploader per
    /// render would be wasteful at best.
    @State private var kit = LabKit()

    init(userID: UUID, server: LabServer, tokenProvider: @escaping @Sendable () async -> String?, signOut: @escaping () -> Void) {
        self.userID = userID
        self.server = server
        self.signOut = signOut
        self.config = PixConfig(baseURL: server.pixBaseURL,
                                currentUserID: userID,
                                tokenProvider: tokenProvider)
    }

    private var engine: PixEngine { kit.engine(config) }

    var body: some View {
        LabShell(config: config, engine: engine) { account }
    }

    /// PixLab's own rows.
    private var account: some View {
        Section("Account") {
            LabeledContent("User ID") { Text(userID.uuidString.lowercased()).font(.caption.monospaced()).textSelection(.enabled) }
            LabeledContent("Server", value: server.rawValue)
            // Sign-out wipes the kit first: its memory, the cache and the
            // upload journal under PixKit/<account>.
            Button("Sign out", role: .destructive) {
                engine.wipe()
                signOut()
            }
        }
    }
}

/// The Lab's one engine per identity, made on first use.
@MainActor
final class LabKit {
    private var made: PixEngine?

    func engine(_ config: PixConfig) -> PixEngine {
        if let made { return made }
        let e = PixEngine(config: config, cache: PixMediaCache(config: config), uploader: PixUploader(config: config))
        made = e
        return e
    }
}
