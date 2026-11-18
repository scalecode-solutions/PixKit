import Foundation
import Testing
@testable import PixKit

/// One uploader and one cache per account, storage folder and server.
@Suite struct SharedInstanceTests {
    func config(_ server: FakeBlobServer, account: UUID, storage: URL, token: String?) -> PixConfig {
        PixConfig(baseURL: server.baseURL, currentUserID: account, tokenProvider: { token }, storageDirectory: storage)
    }

    @Test func theSameAccountGetsTheSameUploaderAndCache() throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        let a = config(server, account: fx.account, storage: fx.dir, token: "tok")
        let again = config(server, account: fx.account, storage: fx.dir, token: "tok")
        #expect(PixUploader.shared(config: a) === PixUploader.shared(config: again))
        #expect(PixMediaCache.shared(config: a) === PixMediaCache.shared(config: again))
    }

    @Test func anotherAccountFolderOrServerGetsItsOwn() throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        let other = FakeBlobServer()
        let a = config(server, account: fx.account, storage: fx.dir, token: "tok")
        let up = PixUploader.shared(config: a)
        #expect(up !== PixUploader.shared(config: config(server, account: UUID(), storage: fx.dir, token: "tok")))
        #expect(up !== PixUploader.shared(config: config(server, account: fx.account, storage: fx.dir.appending(path: "x"), token: "tok")))
        #expect(up !== PixUploader.shared(config: config(other, account: fx.account, storage: fx.dir, token: "tok")))
    }

    @Test func aNewerTokenProviderIsTheOneUsed() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        URLProtocol.registerClass(FakeProtocol.self)
        let server = FakeBlobServer()
        // First made while signed out (no token): its job would wait forever.
        let up = PixUploader.shared(config: config(server, account: fx.account, storage: fx.dir, token: nil))
        // Signed in again: same uploader, the new provider.
        #expect(PixUploader.shared(config: config(server, account: fx.account, storage: fx.dir, token: "tok")) === up)
        let events = up.events()
        let (file, _) = try fx.file(20)
        _ = try await up.enqueue(file: file, mimeType: "image/jpeg", spaceID: fx.space, ownsFile: false)
        let got = await collect(events, timeout: .seconds(5))
        guard case .completed? = got.final else { Issue.record("\(got.states)"); return }
    }
}
