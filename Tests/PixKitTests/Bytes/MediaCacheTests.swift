import Foundation
import Testing
@testable import PixKit

/// The media cache against the fake server's items.
@Suite struct MediaCacheTests {

    @Test func downloadsOnceThenServesFromDisk() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        let bytes = Data((0..<500).map { UInt8($0 % 251) })
        let item = server.addItem(space: fx.space, bytes: bytes)
        let cache = fx.cache(server)

        // Five at once share one download.
        let urls = try await withThrowingTaskGroup(of: URL.self) { g in
            for _ in 0..<5 { g.addTask { try await cache.file(item: item, spaceID: fx.space, thumb: false) } }
            return try await g.reduce(into: [URL]()) { $0.append($1) }
        }
        #expect(Set(urls).count == 1)
        #expect(try Data(contentsOf: urls[0]) == bytes)
        _ = try await cache.file(item: item, spaceID: fx.space, thumb: false)
        #expect(server.lock.withLock { server.log.filter { $0.hasPrefix("GET") }.count } == 1)
        // Laid out per account and space, keyed by item id.
        #expect(urls[0].path.hasSuffix("/PixKit/\(fx.account.uuidString.lowercased())/cache/\(fx.space.uuidString.lowercased())/\(item.uuidString.lowercased())"))
        #expect(await cache.cached(item: item, spaceID: fx.space, thumb: false) == urls[0])
    }

    @Test func theThumbnailIsItsOwnFile() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        let item = server.addItem(space: fx.space, bytes: Data("full".utf8))
        let cache = fx.cache(server)
        let thumb = try await cache.file(item: item, spaceID: fx.space, thumb: true)
        #expect(thumb.lastPathComponent.hasSuffix(".thumb"))
        #expect(try Data(contentsOf: thumb) == Data("thumb-\(item)".utf8))
        #expect(await cache.cached(item: item, spaceID: fx.space, thumb: false) == nil)
    }

    @Test func aCutDownloadResumesWithARange() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        let bytes = Data((0..<1000).map { UInt8($0 % 239) })
        let item = server.addItem(space: fx.space, bytes: bytes)
        server.lock.withLock { server.cutDownloadAfter = 300 }
        let cache = fx.cache(server)

        await #expect(throws: (any Error).self) { _ = try await cache.file(item: item, spaceID: fx.space, thumb: false) }
        #expect(await cache.cached(item: item, spaceID: fx.space, thumb: false) == nil, "a partial is never served")

        let url = try await cache.file(item: item, spaceID: fx.space, thumb: false)
        #expect(try Data(contentsOf: url) == bytes)
        let dest = cache.url(item: item, spaceID: fx.space)
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathExtension("part").path))
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathExtension("etag").path))
    }

    @Test func aResumeAskedForTheRestOnly() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        let bytes = Data((0..<1000).map { UInt8($0 % 239) })
        let item = server.addItem(space: fx.space, bytes: bytes)
        let cache = fx.cache(server)
        // A part from an earlier try, with its validator.
        let dest = cache.url(item: item, spaceID: fx.space)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.prefix(400).write(to: dest.appendingPathExtension("part"))
        try "\"\(item)\"".write(to: dest.appendingPathExtension("etag"), atomically: true, encoding: .utf8)

        let url = try await cache.file(item: item, spaceID: fx.space, thumb: false)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func aStalePartIsReplacedNotSpliced() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        let bytes = Data((0..<1000).map { UInt8($0 % 239) })
        let item = server.addItem(space: fx.space, bytes: bytes)
        let cache = fx.cache(server)
        let dest = cache.url(item: item, spaceID: fx.space)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xEE, count: 400).write(to: dest.appendingPathExtension("part"))
        try "\"some-other-version\"".write(to: dest.appendingPathExtension("etag"), atomically: true, encoding: .utf8)

        let url = try await cache.file(item: item, spaceID: fx.space, thumb: false)
        #expect(try Data(contentsOf: url) == bytes, "If-Range didn't match: the whole file came back")
    }

    @Test func aGoneItemThrowsNotFoundAndLeavesNothing() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        let item = server.addItem(space: fx.space, bytes: Data("x".utf8))
        let cache = fx.cache(server)
        _ = try await cache.file(item: item, spaceID: fx.space, thumb: true)
        server.lock.withLock { _ = server.items.removeValue(forKey: item) }

        await #expect(throws: PixTransportError.notFound) { _ = try await cache.file(item: item, spaceID: fx.space, thumb: false) }
        #expect(await cache.cached(item: item, spaceID: fx.space, thumb: true) == nil, "the thumb goes too")
    }

    @Test func noTokenIsNotAuthenticated() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        let item = server.addItem(space: fx.space, bytes: Data("x".utf8))
        let cache = PixMediaCache(account: fx.account, client: server.client(token: nil), base: fx.dir.appending(path: "caches"))
        await #expect(throws: PixTransportError.notAuthenticated) { _ = try await cache.file(item: item, spaceID: fx.space, thumb: false) }
        #expect(server.lock.withLock { server.requestCount } == 0)
    }

    @Test func wipeSpaceDropsOnlyThatSpace() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        let other = UUID()
        let a = server.addItem(space: fx.space, bytes: Data("a".utf8))
        let b = server.addItem(space: other, bytes: Data("b".utf8))
        let cache = fx.cache(server)
        _ = try await cache.file(item: a, spaceID: fx.space, thumb: false)
        _ = try await cache.file(item: b, spaceID: other, thumb: false)

        await cache.wipe(spaceID: fx.space)
        #expect(await cache.cached(item: a, spaceID: fx.space, thumb: false) == nil)
        #expect(await cache.cached(item: b, spaceID: other, thumb: false) != nil)

        await cache.wipeAll()
        #expect(await cache.cached(item: b, spaceID: other, thumb: false) == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.root.path))
    }

    @Test func aDownloadThatLandsAfterAWipeIsNotKept() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        let item = server.addItem(space: fx.space, bytes: Data(repeating: 1, count: 100))
        let cache = fx.cache(server)
        let started = Flag()
        let release = Flag()
        server.inject = { _, _ in
            _ = started.flip()
            while !release.isSet { usleep(1000) }
            return nil
        }
        let t = Task { try await cache.file(item: item, spaceID: fx.space, thumb: false) }
        #expect(await bytesEventually { started.isSet })
        await cache.wipe(spaceID: fx.space)
        _ = release.flip()
        _ = await t.result
        #expect(await bytesEventually { await cache.cached(item: item, spaceID: fx.space, thumb: false) == nil })
        #expect(!FileManager.default.fileExists(atPath: cache.url(item: item, spaceID: fx.space).path))
    }

    @Test func accountsDoNotShareFiles() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        let item = server.addItem(space: fx.space, bytes: Data("x".utf8))
        let mine = fx.cache(server)
        let theirs = PixMediaCache(account: UUID(), client: server.client(), base: fx.dir.appending(path: "caches"))
        _ = try await mine.file(item: item, spaceID: fx.space, thumb: false)
        #expect(await theirs.cached(item: item, spaceID: fx.space, thumb: false) == nil)
        await theirs.wipeAll()
        #expect(await mine.cached(item: item, spaceID: fx.space, thumb: false) != nil)
    }

    @Test func theCacheAndTheJournalShareAStorageDirectoryWithoutTouching() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        server.inject = { _, _ in throw URLError(.notConnectedToInternet) } // the job stays queued
        let shared = fx.dir.appending(path: "group")
        let cache = PixMediaCache(account: fx.account, client: server.client(), base: shared)
        let up = PixUploader(account: fx.account, client: server.client(), base: shared, backoff: { _ in .seconds(3600) })
        let (file, _) = try fx.file(40)
        _ = try await up.enqueue(file: file, mimeType: "image/jpeg", spaceID: fx.space, ownsFile: false)

        await cache.wipeAll()
        #expect(await up.jobs().count == 1)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: up.folder.path)) ?? []).count == 1, "the journal survives a cache wipe")
        #expect(!up.folder.path.hasPrefix(cache.root.path + "/") && !cache.root.path.hasPrefix(up.folder.path + "/"))
        await up.wipeAll()
    }
}
