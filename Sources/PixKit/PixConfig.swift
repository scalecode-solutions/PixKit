import Foundation

/// Everything PixKit needs from the host. The token provider is `@Sendable` +
/// `async` so the host can hand over its current access token (auto-refreshed)
/// from its own actor. PixKit never logs anyone in.
public struct PixConfig: Sendable {
    /// The mvPix server: metadata at `/pix.v1.PixService/…`, bytes under `/v1/blobs/`.
    public let baseURL: URL
    /// The signed-in user.
    public let currentUserID: UUID
    public let tokenProvider: @Sendable () async -> String?
    /// Where the kit keeps its cache and upload journal, when the host wants
    /// somewhere specific; nil → the app's own Caches / Application Support.
    public let storageDirectory: URL?
    // No notifications of any kind: nothing in a space announces itself
    // outside the app.

    public init(baseURL: URL,
                currentUserID: UUID,
                tokenProvider: @escaping @Sendable () async -> String?,
                storageDirectory: URL? = nil) {
        self.baseURL = baseURL
        self.currentUserID = currentUserID
        self.tokenProvider = tokenProvider
        self.storageDirectory = storageDirectory
    }

    /// The live transport — Connect/protobuf against mvPix.
    public var transport: any PixTransport {
        ConnectPixTransport(baseURL: baseURL, tokenProvider: tokenProvider)
    }
}
