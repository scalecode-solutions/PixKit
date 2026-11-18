import Foundation

/// Which backend PixLab talks to. Auth goes to mvServer (WebSocket via MvAuth);
/// space calls go to mvPix (Connect + HTTP via PixKit). Same credentials, two
/// services. Develop against **Local** (mvServer + mvPix in local Docker).
enum LabServer: String, CaseIterable, Identifiable, Sendable {
    case production = "Production"
    case local = "Local"

    var id: String { rawValue }

    /// mvServer WebSocket endpoint MvAuth logs in against.
    var authWS: URL {
        switch self {
        case .production: URL(string: "wss://api.mvchat.app/v0/ws")!
        case .local:      URL(string: "ws://localhost:6170/v0/ws")!
        }
    }

    /// mvPix base URL PixKit talks to.
    var pixBaseURL: URL {
        switch self {
        case .production: URL(string: "https://pix.mvchat.app")!
        case .local:      URL(string: "http://localhost:6102")!
        }
    }
}
