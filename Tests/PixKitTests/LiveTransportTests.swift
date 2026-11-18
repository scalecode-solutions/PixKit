import Foundation
import Testing
@testable import PixKit

/// Round trips against a REAL local mvPix, through the real Connect transport.
/// Skipped unless the runner passes the environment (only scripts/live-test.sh
/// does: it mints the tokens). TEST accounts only, never a real person's.
struct Live: Sendable {
    let base: URL
    let user: UUID
    let token: String

    static let env: Live? = {
        let e = ProcessInfo.processInfo.environment
        guard let b = e["PIX_LIVE_BASE"], let base = URL(string: b),
              let u = e["PIX_LIVE_USER"].flatMap(UUID.init(uuidString:)),
              let t = e["PIX_LIVE_TOKEN"] else { return nil }
        return Live(base: base, user: u, token: t)
    }()

    var transport: ConnectPixTransport { ConnectPixTransport(baseURL: base, tokenProvider: { [t = token] in t }) }
}

@Suite("Live transport", .serialized, .enabled(if: Live.env != nil, "set by scripts/live-test.sh"))
struct LiveTransportTests {
    @Test func whoAmIIsTheTokensUser() async throws {
        let live = try #require(Live.env)
        #expect(try await live.transport.whoAmI() == live.user)
    }

    @Test func aForgedTokenIsNotAuthenticated() async throws {
        let live = try #require(Live.env)
        let bad = ConnectPixTransport(baseURL: live.base, tokenProvider: { "eyJhbGciOiJIUzI1NiJ9.e30.AAAA" })
        await #expect(throws: PixTransportError.notAuthenticated) { _ = try await bad.whoAmI() }
    }

    @Test func spacesAndFriendsRead() async throws {
        let live = try #require(Live.env)
        let spaces = try await live.transport.listSpaces()
        #expect(spaces.allSatisfy { $0.otherID != live.user })
        let friends = try await live.transport.listFriends()
        #expect(friends.allSatisfy { $0.id != live.user })
    }

    @Test func aSpaceNobodyHasIsNotFound() async throws {
        let live = try #require(Live.env)
        await #expect(throws: PixTransportError.notFound) {
            _ = try await live.transport.listItems(spaceID: UUID(), pageSize: 0, pageToken: nil)
        }
    }
}
