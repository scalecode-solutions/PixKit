import Foundation
import Testing
@testable import PixKit

/// The uploader against the fake /v1/blobs/ server (chunk 64, alignment 16).
@Suite struct UploaderTests {

    @Test func sendsInServerSizedPartsAndCompletes() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        let up = fx.uploader(server)
        let events = up.events()
        let (file, data) = try fx.file(150)

        let id = try await up.enqueue(file: file, mimeType: "image/jpeg", spaceID: fx.space, ownsFile: false)
        let got = await collect(events)

        guard case .completed(let item, .added)? = got.final else { Issue.record("final: \(String(describing: got.final))"); return }
        #expect(got.allSatisfy { $0.id == id && $0.spaceID == fx.space && $0.size == 150 && $0.mimeType == "image/jpeg" })
        #expect(got.first?.state == .queued)
        #expect(got.states.contains(.uploading(sent: 128, total: 150)))
        #expect(got.states.contains(.processing))
        #expect(got.last(where: { $0.state.isFinal })?.uploadID != nil)
        // Parts at 0, 64, 128: the server's chunk size, not a fixed one.
        let puts = server.lock.withLock { server.log.filter { $0.hasPrefix("PUT") } }
        #expect(puts.map { $0.split(separator: "=").last.map(String.init) } == ["0", "64", "128"])
        #expect(server.lock.withLock { server.items[item]?.data } == data)
        // Copied, not moved: the caller's file stays; the staged copy is gone.
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(await eventually { (try? FileManager.default.contentsOfDirectory(atPath: up.folder.path))?.isEmpty ?? true })
    }

    @Test func anOwnedFileIsMovedSoNothingLingersInTmp() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        let up = fx.uploader(server)
        let events = up.events()
        let (file, _) = try fx.file(40, name: "recording.m4a")

        _ = try await up.enqueue(file: file, mimeType: "audio/mp4", spaceID: fx.space, ownsFile: true)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let got = await collect(events)
        guard case .completed? = got.final else { Issue.record("\(got.states)"); return }
        #expect(await eventually { (try? FileManager.default.contentsOfDirectory(atPath: up.folder.path))?.isEmpty ?? true })
    }

    @Test func anOwnedFileIsDeletedWhenEnqueueFails() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        // The uploader's folder can't be made: a plain file sits where it goes.
        let blocker = fx.dir.appending(path: "blocked")
        try Data().write(to: blocker)
        let up = fx.uploader(server, base: blocker)
        let (file, _) = try fx.file(40, name: "recording.m4a")

        await #expect(throws: (any Error).self) {
            _ = try await up.enqueue(file: file, mimeType: "audio/mp4", spaceID: fx.space, ownsFile: true)
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func resumesAfterAKillFromTheServersOffset() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        // First life: the second PUT can't connect, and the retry waits "forever".
        server.inject = { req, _ in
            if req.httpMethod == "PUT", req.url?.query == "offset=64" { throw URLError(.notConnectedToInternet) }
            return nil
        }
        let first = fx.uploader(server, backoff: .seconds(3600))
        let events = first.events()
        let (file, data) = try fx.file(150)
        _ = try await first.enqueue(file: file, mimeType: "image/jpeg", spaceID: fx.space, ownsFile: false)
        var seenWaiting = false
        for await e in events { if case .waiting = e.state { seenWaiting = true; break } }
        #expect(seenWaiting)

        // The "kill": the app's folder as it was, picked up by a new process.
        let relaunched = fx.dir.appending(path: "relaunched")
        try FileManager.default.copyItem(at: fx.dir.appending(path: "support"), to: relaunched)
        await first.wipeAll() // stop the first life (its own copy)
        server.inject = nil
        server.lock.withLock { server.log.removeAll() }

        let second = fx.uploader(server, base: relaunched)
        let events2 = second.events()
        let found = await second.resumeOnLaunch()
        #expect(found.count == 1 && found.first?.state == .queued && found.first?.uploadID != nil)
        let got = await collect(events2)
        guard case .completed(let item, .added)? = got.final else { Issue.record("\(got.states)"); return }
        #expect(got.first?.id == found.first?.id)

        let log = server.lock.withLock { server.log }
        #expect(!log.contains { $0.hasPrefix("POST") && $0.hasSuffix("/uploads") }, "no new upload: \(log)")
        #expect(log.first?.hasPrefix("GET /v1/blobs/uploads/") == true, "asks the server first: \(log)")
        #expect(log.filter { $0.hasPrefix("PUT") }.map { String($0.split(separator: "=").last!) } == ["64", "128"])
        #expect(server.lock.withLock { server.items[item]?.data } == data)
    }

    @Test func anUploadTheServerForgotStartsOverOnce() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        server.inject = { req, _ in
            if req.httpMethod == "PUT", req.url?.query == "offset=64" { throw URLError(.notConnectedToInternet) }
            return nil
        }
        let first = fx.uploader(server, backoff: .seconds(3600))
        let events = first.events()
        let (file, data) = try fx.file(150)
        _ = try await first.enqueue(file: file, mimeType: "image/jpeg", spaceID: fx.space, ownsFile: false)
        for await e in events { if case .waiting = e.state { break } }
        let relaunched = fx.dir.appending(path: "relaunched")
        try FileManager.default.copyItem(at: fx.dir.appending(path: "support"), to: relaunched)
        await first.wipeAll()
        // Reaped while we were gone.
        server.lock.withLock { server.uploads.removeAll(); server.log.removeAll() }
        server.inject = nil

        let second = fx.uploader(server, base: relaunched)
        let events2 = second.events()
        _ = await second.resumeOnLaunch()
        let got = await collect(events2)
        guard case .completed(let item, _)? = got.final else { Issue.record("\(got.states)"); return }
        let log = server.lock.withLock { server.log }
        #expect(log.filter { $0 == "POST /v1/blobs/uploads" }.count == 1)
        #expect(log.filter { $0.hasPrefix("PUT") }.map { String($0.split(separator: "=").last!) } == ["0", "64", "128"])
        #expect(server.lock.withLock { server.items[item]?.data } == data)
    }

    @Test func aLostPutAnswerContinuesFromTheServersOffset() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        // The server takes the part at 64, but the answer never arrives.
        let flag = Flag()
        server.dropReply = { req, _ in req.httpMethod == "PUT" && req.url?.query == "offset=64" && !flag.flip() }
        let up = fx.uploader(server)
        let events = up.events()
        let (file, data) = try fx.file(150)
        _ = try await up.enqueue(file: file, mimeType: "image/jpeg", spaceID: fx.space, ownsFile: false)
        let got = await collect(events)
        guard case .completed(let item, _)? = got.final else { Issue.record("\(got.states)"); return }
        #expect(server.lock.withLock { server.items[item]?.data } == data, "no byte sent twice or skipped")
        let log = server.lock.withLock { server.log }
        // 64 (answer lost) → ask the server where it is (128) → 128: the part
        // it already took is never sent again.
        #expect(log.filter { $0.hasPrefix("PUT") }.map { String($0.split(separator: "=").last!) } == ["0", "64", "128"])
        #expect(log.contains { $0.hasPrefix("GET /v1/blobs/uploads/") })
    }

    @Test func aWrongOffsetCarriesTheServersOffset() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        let client = server.client()
        let s = try await client.initUpload(space: fx.space, mimeType: "image/jpeg", size: 100)
        _ = try await client.put(upload: s.uploadId, offset: 0, bytes: Data(count: 64))
        do {
            _ = try await client.put(upload: s.uploadId, offset: 0, bytes: Data(count: 64))
            Issue.record("a stale offset was taken")
        } catch let err as PixBlobError {
            guard case .server(let e) = err else { Issue.record("\(err)"); return }
            #expect(e.reason == "OFFSET_MISMATCH" && e.uploadOffset == 64 && e.status == 409)
        }
    }

    @Test func aLostCompleteAnswerIsAskedAgainForTheSameItem() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        let flag = Flag()
        server.dropReply = { req, _ in req.url?.path.hasSuffix("/complete") == true && !flag.flip() }
        let up = fx.uploader(server)
        let events = up.events()
        let (file, _) = try fx.file(20)
        _ = try await up.enqueue(file: file, mimeType: "image/jpeg", spaceID: fx.space, ownsFile: false)
        let got = await collect(events)
        guard case .completed(let item, _)? = got.final else { Issue.record("\(got.states)"); return }
        #expect(server.lock.withLock { server.items.count } == 1)
        #expect(server.lock.withLock { server.items[item] } != nil)
        #expect(got.states.contains { if case .waiting = $0 { true } else { false } })
    }

    @Test func serverFailuresWaitAndRetry() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        server.inject = { _, n in n <= 3 ? 503 : nil }
        let up = fx.uploader(server)
        let events = up.events()
        let (file, _) = try fx.file(20)
        _ = try await up.enqueue(file: file, mimeType: "image/jpeg", spaceID: fx.space, ownsFile: false)
        let got = await collect(events)
        guard case .completed? = got.final else { Issue.record("\(got.states)"); return }
        #expect(got.states.contains(.waiting(attempt: 3)))
    }

    @Test(arguments: [
        ("SPACE_NOT_FOUND", 404, PixUploadFailure.spaceGone),
        ("UPLOAD_TOO_LARGE", 413, .tooLarge),
        ("UNSUPPORTED_MEDIA_TYPE", 415, .unsupported),
        ("MEDIA_UNREADABLE", 422, .unreadable),
        ("MEDIA_TOO_LONG", 422, .tooLong),
    ])
    func serverReasonsMapToFailures(reason: String, status: Int, want: PixUploadFailure) async throws {
        #expect(PixUploadFailure.from(.server(.init(status: status, code: "X", reason: reason, message: "m"))) == want)
    }

    @Test func aGoneSpaceFailsTheJobAndCleansUp() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        server.lock.withLock { _ = server.goneSpaces.insert(fx.space) }
        let up = fx.uploader(server)
        let events = up.events()
        let (file, _) = try fx.file(20)
        _ = try await up.enqueue(file: file, mimeType: "image/jpeg", spaceID: fx.space, ownsFile: false)
        let got = await collect(events)
        #expect(got.final == .failed(.spaceGone))
        #expect(await eventually { (try? FileManager.default.contentsOfDirectory(atPath: up.folder.path))?.isEmpty ?? true })
        #expect(await up.jobs().isEmpty)
    }

    @Test func aBadRequestIsNotRetried() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        server.inject = { req, _ in req.httpMethod == "POST" ? 400 : nil }
        let up = fx.uploader(server)
        let events = up.events()
        let (file, _) = try fx.file(20)
        _ = try await up.enqueue(file: file, mimeType: "image/jpeg", spaceID: fx.space, ownsFile: false)
        let got = await collect(events)
        guard case .failed(.refused)? = got.final else { Issue.record("\(got.states)"); return }
        #expect(server.lock.withLock { server.requestCount } == 1)
    }

    @Test func cancelWhileWaitingEndsItAndDropsTheFile() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        server.inject = { _, _ in throw URLError(.notConnectedToInternet) }
        let up = fx.uploader(server, backoff: .seconds(3600))
        let events = up.events()
        let (file, _) = try fx.file(20)
        let id = try await up.enqueue(file: file, mimeType: "image/jpeg", spaceID: fx.space, ownsFile: false)
        for await e in events { if case .waiting = e.state { break } }
        await up.cancel(id)
        #expect(await up.jobs().isEmpty)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: up.folder.path))?.isEmpty ?? true)
    }

    @Test func forgetSpaceCancelsOnlyThatSpacesJobs() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        let other = UUID()
        // Hold everything until we've forgotten the space.
        let gate = Flag()
        server.inject = { _, _ in
            if !gate.isSet { throw URLError(.notConnectedToInternet) }
            return nil
        }
        let up = fx.uploader(server, backoff: .milliseconds(20))
        let events = up.events()
        let (f1, _) = try fx.file(20)
        let (f2, _) = try fx.file(20)
        let a = try await up.enqueue(file: f1, mimeType: "image/jpeg", spaceID: fx.space, ownsFile: false)
        let b = try await up.enqueue(file: f2, mimeType: "image/jpeg", spaceID: other, ownsFile: false)
        await up.forgetSpace(fx.space)
        _ = gate.flip()
        let got = await collect(events, finals: 2)
        #expect(got.last(where: { $0.id == a && $0.state.isFinal })?.state == .cancelled)
        guard case .completed? = got.last(where: { $0.id == b && $0.state.isFinal })?.state else { Issue.record("\(got.states)"); return }
    }

    @Test func wipeAllRemovesTheJournal() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        server.inject = { _, _ in throw URLError(.notConnectedToInternet) }
        let up = fx.uploader(server, backoff: .seconds(3600))
        let (file, _) = try fx.file(20)
        _ = try await up.enqueue(file: file, mimeType: "image/jpeg", spaceID: fx.space, ownsFile: false)
        await up.wipeAll()
        #expect(!FileManager.default.fileExists(atPath: up.folder.path))
        #expect(await up.jobs().isEmpty)
    }

    @Test func aHalfWrittenJournalEntryIsDroppedOnLaunch() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        let up = fx.uploader(server)
        let junk = up.folder.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        try Data("{\"id\":".utf8).write(to: junk.appending(path: "job.json"))
        try Data([1, 2, 3]).write(to: junk.appending(path: "file.jpg"))
        #expect(await up.resumeOnLaunch().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: junk.path))
    }

    @Test func noTokenWaitsInsteadOfFailing() async throws {
        let fx = try BytesFixture(); defer { fx.cleanup() }
        let server = FakeBlobServer()
        let up = PixUploader(account: fx.account, client: server.client(token: nil), base: fx.dir.appending(path: "support"),
                             backoff: { _ in .seconds(3600) })
        let events = up.events()
        let (file, _) = try fx.file(20)
        _ = try await up.enqueue(file: file, mimeType: "image/jpeg", spaceID: fx.space, ownsFile: false)
        var waited = false
        for await e in events { if case .waiting = e.state { waited = true; break }; if e.state.isFinal { break } }
        #expect(waited)
        #expect(server.lock.withLock { server.requestCount } == 0, "nothing is sent without a token")
        await up.wipeAll()
    }

    @Test(arguments: [
        ("image/jpeg", PixKind.photo), ("IMAGE/HEIC", .photo), ("video/quicktime", .video),
        ("audio/x-m4a", .audio), (" audio/mpeg\n", .audio),
    ])
    func kindsMatchTheServer(mime: String, kind: PixKind) { #expect(PixKind(mimeType: mime) == kind) }

    @Test func typesTheServerRefusesHaveNoKind() {
        for m in ["image/gif", "image/webp", "video/webm", "application/pdf", ""] { #expect(PixKind(mimeType: m) == nil) }
    }
}

/// A one-way switch for the fake's closures.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var isSet: Bool { lock.withLock { on } }
    /// Sets it and returns what it was.
    func flip() -> Bool { lock.withLock { defer { on = true }; return on } }
}
