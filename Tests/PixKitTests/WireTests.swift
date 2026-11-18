import Foundation
import Connect
import Testing
@testable import PixKit

/// The proto ↔ kit mapping and the error sorting the engine branches on.
struct WireTests {
    let a = UUID(uuidString: "00000000-0000-4000-8000-0000000000a1")!
    let b = UUID(uuidString: "00000000-0000-4000-8000-0000000000b2")!
    let s = UUID(uuidString: "00000000-0000-4000-8000-0000000000c3")!

    @Test func idsGoOutLowercase() {
        #expect(PixWire.string(a) == "00000000-0000-4000-8000-0000000000a1")
    }

    @Test func aSpaceMaps() throws {
        var p = Pix_V1_Space()
        p.id = PixWire.string(s); p.otherID = PixWire.string(b); p.createdBy = PixWire.string(a)
        p.createdAt = 1_700_000_000_123
        let space = try PixWire.space(p)
        #expect(space.id == s && space.otherID == b && space.createdBy == a)
        #expect(space.name == "")
        #expect(space.renamedAt == nil) // 0 = never renamed
        #expect(space.createdAt.timeIntervalSince1970 == 1_700_000_000.123)
        p.renamedAt = 1_700_000_001_000
        #expect(try PixWire.space(p).renamedAt == Date(timeIntervalSince1970: 1_700_000_001))
    }

    @Test func aFriendWithoutASpaceOrAvatar() throws {
        var p = Pix_V1_Friend()
        p.userID = PixWire.string(b)
        let f = try PixWire.friend(p)
        #expect(f.spaceID == nil && f.avatar == nil && f.name == "")
        p.spaceID = PixWire.string(s); p.avatar = Data([1, 2, 3]).base64EncodedString()
        let g = try PixWire.friend(p)
        #expect(g.spaceID == s && g.avatar == Data([1, 2, 3]))
    }

    @Test func itemsMapByKind() throws {
        var p = Pix_V1_Item()
        p.id = PixWire.string(a); p.spaceID = PixWire.string(s); p.uploaderID = PixWire.string(b)
        p.kind = "video"; p.mimeType = "video/mp4"; p.size = 42; p.width = 1920; p.height = 1080
        p.durationMs = 1500; p.createdAt = 1000; p.hasThumb_p = true
        let i = try PixWire.item(p)
        #expect(i.kind == .video && i.duration == .milliseconds(1500) && i.width == 1920 && i.hasThumb)
        p.kind = "photo"; p.durationMs = 0
        #expect(try PixWire.item(p).duration == nil)
        p.kind = "sticker"
        #expect(throws: PixTransportError.self) { try PixWire.item(p) }
    }

    @Test func aBadIDIsABadResponse() {
        #expect(throws: PixTransportError.self) { try PixWire.uuid("nope") }
    }

    @Test func errorsSortByWhatToDo() {
        func m(_ c: Code) -> PixTransportError {
            ConnectPixTransport.map(ConnectError(code: c, message: "x", exception: nil, details: [], metadata: [:]))
        }
        #expect(m(.unauthenticated) == .notAuthenticated)
        #expect(m(.notFound) == .notFound)
        #expect(m(.permissionDenied) == .forbidden("x"))
        #expect(m(.invalidArgument) == .invalid("x"))
        #expect(m(.resourceExhausted) == .slowDown)
        #expect(m(.unavailable).isRetryable)
        #expect(!m(.notFound).isRetryable)
    }

    @Test func noTokenFailsLocally() async {
        let t = ConnectPixTransport(baseURL: URL(string: "http://127.0.0.1:9")!, tokenProvider: { nil })
        await #expect(throws: PixTransportError.notAuthenticated) { _ = try await t.whoAmI() }
    }
}
