import Foundation
import Connect
import SwiftProtobuf

/// Transport-level failures, sorted by what the caller should do about them.
public enum PixTransportError: Error, Sendable, Equatable {
    /// No token, or the server rejected it: the host's session is gone.
    case notAuthenticated
    /// It doesn't exist, or the caller may not reach it now. For a space this
    /// is also what an unfriend looks like: drop it and its cache.
    case notFound
    /// Not the caller's to change (deleting someone else's item).
    case forbidden(String)
    /// The request was refused as invalid (a message for people).
    case invalid(String)
    /// Too many requests: try again shortly.
    case slowDown
    /// The server couldn't be reached: try again later.
    case unavailable(String)
    /// The server answered with an internal failure.
    case serverFailed(String)
    /// The server answered something this kit can't read.
    case badResponse(String)

    /// Worth trying again later unchanged.
    public var isRetryable: Bool {
        switch self {
        case .unavailable, .serverFailed, .slowDown, .notAuthenticated: return true
        default: return false
        }
    }
}

/// The kit's view of mvPix's metadata API. A protocol so tests and previews can
/// fake it. Bytes (uploads, downloads) travel over plain HTTP, not through here.
public protocol PixTransport: Sendable {
    /// The caller's own id: proves the token is accepted without touching data.
    func whoAmI() async throws -> UUID
    /// People the caller can share a space with, with any space already shared.
    func listFriends() async throws -> [PixFriend]
    /// The caller's reachable spaces, newest first.
    func listSpaces() async throws -> [PixSpace]
    /// Opens the caller's space with a friend, or returns the existing one
    /// (safe to repeat). Not friends: `.notFound`.
    func createSpace(otherID: UUID) async throws -> PixSpace
    /// "" clears the name. Up to 100 characters, no line breaks: `.invalid` otherwise.
    func renameSpace(id: UUID, name: String) async throws -> PixSpace
    /// A page of a space's live items, newest first. `pageSize` 0 = the server's max (500).
    func listItems(spaceID: UUID, pageSize: Int, pageToken: String?) async throws -> PixItemPage
    /// Hides an item for both members (soft delete). Only its uploader may:
    /// `.forbidden` for the other member. Safe to repeat.
    func deleteItem(id: UUID) async throws
}

/// `PixTransport` over Connect/protobuf. Wraps the generated client and injects
/// the bearer token per call.
public struct ConnectPixTransport: PixTransport {
    private let client: Pix_V1_PixServiceClient
    private let tokenProvider: @Sendable () async -> String?

    public init(baseURL: URL, tokenProvider: @escaping @Sendable () async -> String?) {
        let config = ProtocolClientConfig(host: baseURL.absoluteString, networkProtocol: .connect, codec: ProtoCodec(),
                                          timeout: 30)
        self.client = Pix_V1_PixServiceClient(client: ProtocolClient(httpClient: URLSessionHTTPClient(), config: config))
        self.tokenProvider = tokenProvider
    }

    // MARK: plumbing

    private func headers() async throws -> Headers {
        // No token → fail locally rather than send a request the server can only reject.
        guard let tok = await tokenProvider() else { throw PixTransportError.notAuthenticated }
        return ["Authorization": ["Bearer \(tok)"]]
    }

    private func value<T: ProtobufMessage>(_ r: ResponseMessage<T>) throws -> T {
        if let m = r.message { return m }
        guard let e = r.error else { throw PixTransportError.badResponse("empty response") }
        throw Self.map(e)
    }

    static func map(_ e: ConnectError) -> PixTransportError {
        let msg = e.message ?? ""
        switch e.code {
        case .unauthenticated: return .notAuthenticated
        case .notFound: return .notFound
        case .permissionDenied: return .forbidden(msg)
        case .invalidArgument, .failedPrecondition, .outOfRange: return .invalid(msg)
        case .resourceExhausted: return .slowDown
        case .internalError, .unknown, .dataLoss:
            return .serverFailed(msg.isEmpty ? "\(e.code)" : msg)
        case .unavailable, .deadlineExceeded, .aborted, .canceled:
            return .unavailable(msg.isEmpty ? "\(e.code)" : msg)
        default: return .badResponse("\(e.code): \(msg)")
        }
    }

    // MARK: calls

    public func whoAmI() async throws -> UUID {
        try PixWire.uuid(value(await client.whoAmI(request: .init(), headers: try await headers())).userID)
    }

    public func listFriends() async throws -> [PixFriend] {
        try value(await client.listFriends(request: .init(), headers: try await headers())).friends.map(PixWire.friend)
    }

    public func listSpaces() async throws -> [PixSpace] {
        try value(await client.listSpaces(request: .init(), headers: try await headers())).spaces.map(PixWire.space)
    }

    public func createSpace(otherID: UUID) async throws -> PixSpace {
        var req = Pix_V1_CreateSpaceRequest()
        req.otherID = PixWire.string(otherID)
        return try PixWire.space(value(await client.createSpace(request: req, headers: try await headers())).space)
    }

    public func renameSpace(id: UUID, name: String) async throws -> PixSpace {
        var req = Pix_V1_RenameSpaceRequest()
        req.spaceID = PixWire.string(id)
        req.name = name
        return try PixWire.space(value(await client.renameSpace(request: req, headers: try await headers())).space)
    }

    public func listItems(spaceID: UUID, pageSize: Int, pageToken: String?) async throws -> PixItemPage {
        var req = Pix_V1_ListItemsRequest()
        req.spaceID = PixWire.string(spaceID)
        req.pageSize = Int32(clamping: pageSize)
        req.pageToken = pageToken ?? ""
        let r = try value(await client.listItems(request: req, headers: try await headers()))
        return PixItemPage(items: try r.items.map(PixWire.item),
                           nextPageToken: r.nextPageToken.isEmpty ? nil : r.nextPageToken)
    }

    public func deleteItem(id: UUID) async throws {
        var req = Pix_V1_DeleteItemRequest()
        req.itemID = PixWire.string(id)
        _ = try value(await client.deleteItem(request: req, headers: try await headers()))
    }
}

/// Proto ↔ kit types. Internal so tests can pin the mapping.
enum PixWire {
    static func string(_ id: UUID) -> String { id.uuidString.lowercased() }

    static func uuid(_ s: String) throws -> UUID {
        guard let u = UUID(uuidString: s) else { throw PixTransportError.badResponse("bad id \(s.prefix(40))") }
        return u
    }

    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }

    static func space(_ s: Pix_V1_Space) throws -> PixSpace {
        PixSpace(id: try uuid(s.id), otherID: try uuid(s.otherID), name: s.name, createdBy: try uuid(s.createdBy),
                 createdAt: date(s.createdAt), renamedAt: s.renamedAt == 0 ? nil : date(s.renamedAt))
    }

    static func friend(_ f: Pix_V1_Friend) throws -> PixFriend {
        PixFriend(id: try uuid(f.userID), name: f.name,
                  avatar: f.avatar.isEmpty ? nil : Data(base64Encoded: f.avatar),
                  spaceID: f.spaceID.isEmpty ? nil : try uuid(f.spaceID))
    }

    static func item(_ i: Pix_V1_Item) throws -> PixItem {
        guard let kind = PixKind(rawValue: i.kind) else { throw PixTransportError.badResponse("unknown kind \(i.kind.prefix(20))") }
        return PixItem(id: try uuid(i.id), spaceID: try uuid(i.spaceID), uploaderID: try uuid(i.uploaderID),
                       kind: kind, mimeType: i.mimeType, size: i.size,
                       width: Int(i.width), height: Int(i.height),
                       duration: i.durationMs > 0 ? .milliseconds(Int64(i.durationMs)) : nil,
                       createdAt: date(i.createdAt), hasThumb: i.hasThumb_p)
    }
}
