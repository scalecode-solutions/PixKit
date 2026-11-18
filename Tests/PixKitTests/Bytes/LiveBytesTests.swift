import AVFoundation
import Foundation
import Testing
import UIKit
@testable import PixKit

/// The bytes code against a REAL throwaway mvPix (scripts/live-bytes-test.sh
/// refuses localhost:6102 and anything not local). Test accounts only.
struct LiveBytes: Sendable {
    struct Who: Sendable { let id: UUID; let token: String }
    let base: URL
    let a: Who, b: Who, outsider: Who

    static let env: LiveBytes? = {
        let e = ProcessInfo.processInfo.environment
        func who(_ k: String) -> Who? {
            guard let id = e["PIX_BYTES_\(k)"].flatMap(UUID.init(uuidString:)), let t = e["PIX_BYTES_\(k)_TOKEN"] else { return nil }
            return Who(id: id, token: t)
        }
        guard let base = e["PIX_BYTES_BASE"].flatMap(URL.init(string:)),
              let a = who("A"), let b = who("B"), let o = who("OUT") else { return nil }
        return LiveBytes(base: base, a: a, b: b, outsider: o)
    }()

    func config(_ w: Who, dir: URL) -> PixConfig {
        PixConfig(baseURL: base, currentUserID: w.id, tokenProvider: { [t = w.token] in t }, storageDirectory: dir)
    }
    func transport(_ w: Who) -> ConnectPixTransport { ConnectPixTransport(baseURL: base, tokenProvider: { [t = w.token] in t }) }
}

@Suite("Live bytes", .serialized, .enabled(if: LiveBytes.env != nil, "set by scripts/live-bytes-test.sh"))
struct LiveBytesTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "pixkit-live-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// A noise JPEG well over one 8 MiB part, unique per call (so no dedup).
    func bigJPEG() throws -> URL {
        let side = 2600
        var px = [UInt8](repeating: 0, count: side * side * 4)
        var g = SystemRandomNumberGenerator()
        px.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt64.self)
            for i in words.indices { words[i] = g.next() | 0xFF00_0000_FF00_0000 }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let data = try #require(UIImage(cgImage: ctx.makeImage()!).jpegData(compressionQuality: 1.0))
        #expect(data.count > 9 << 20, "big enough for several parts (\(data.count) bytes)")
        let url = dir.appending(path: "\(UUID()).jpg")
        try data.write(to: url)
        return url
    }

    func smallJPEG() throws -> URL {
        let img = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).image { c in
            UIColor(hue: .random(in: 0...1), saturation: 1, brightness: 1, alpha: 1).setFill()
            c.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        let url = dir.appending(path: "\(UUID()).jpg")
        try #require(img.jpegData(compressionQuality: 0.9)).write(to: url)
        return url
    }

    /// One second of a tone as AAC in .m4a.
    func clip() throws -> URL {
        let url = dir.appending(path: "\(UUID()).m4a")
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1])
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44_100)!
        buf.frameLength = 44_100
        let hz = Float.random(in: 300...900)
        for i in 0..<44_100 { buf.floatChannelData![0][i] = 0.3 * sin(2 * .pi * hz * Float(i) / 44_100) }
        try file.write(from: buf)
        return url
    }

    func space(_ live: LiveBytes) async throws -> UUID {
        try await live.transport(live.a).createSpace(otherID: live.b.id).id
    }

    func upload(_ up: PixUploader, _ file: URL, _ mime: String, _ space: UUID, timeout: Duration = .seconds(120)) async throws -> PixUploadEvent? {
        let events = up.events()
        _ = try await up.enqueue(file: file, mimeType: mime, spaceID: space, ownsFile: false)
        return await collect(events, timeout: timeout).last { $0.state.isFinal }
    }

    @Test func aBigPhotoGoesUpInPartsAndBothMembersGetTheSameBytes() async throws {
        let live = try #require(LiveBytes.env)
        let space = try await space(live)
        let up = PixUploader(config: live.config(live.a, dir: dir.appending(path: "a")))
        let file = try bigJPEG()
        let size = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64)

        let events = up.events()
        _ = try await up.enqueue(file: file, mimeType: "image/jpeg", spaceID: space, ownsFile: false)
        let got = await collect(events, timeout: .seconds(120))
        guard case .completed(let item, .added)? = got.final else { Issue.record("\(got.states)"); return }
        let sends = got.compactMap { if case .uploading(let s, _) = $0.state { s } else { nil } }
        #expect(sends.count >= 3 && sends.last == size, "progress across parts: \(sends)")

        // It's listed, and both members download the same stored file.
        let page = try await live.transport(live.b).listItems(spaceID: space, pageSize: 0, pageToken: nil)
        let listed = try #require(page.items.first { $0.id == item })
        #expect(listed.uploaderID == live.a.id && listed.kind == .photo && listed.hasThumb)
        let mine = try await PixMediaCache(config: live.config(live.a, dir: dir.appending(path: "a"))).file(item: item, spaceID: space, thumb: false)
        let theirs = try await PixMediaCache(config: live.config(live.b, dir: dir.appending(path: "b"))).file(item: item, spaceID: space, thumb: false)
        let bytes = try Data(contentsOf: mine)
        #expect(bytes == (try Data(contentsOf: theirs)))
        #expect(Int64(bytes.count) == listed.size)
        #expect(UIImage(data: bytes) != nil)
        let thumb = try await PixMediaCache(config: live.config(live.b, dir: dir.appending(path: "b"))).file(item: item, spaceID: space, thumb: true)
        #expect(UIImage(contentsOfFile: thumb.path) != nil)
    }

    @Test func theSameFileAgainIsTheSameItem() async throws {
        let live = try #require(LiveBytes.env)
        let space = try await space(live)
        let up = PixUploader(config: live.config(live.a, dir: dir.appending(path: "a")))
        let file = try smallJPEG()
        guard case .completed(let first, .added)? = try await upload(up, file, "image/jpeg", space)?.state else { Issue.record("first"); return }
        guard case .completed(let again, .existing)? = try await upload(up, file, "image/jpeg", space)?.state else { Issue.record("again"); return }
        #expect(first == again)
    }

    @Test func anAudioClipHasNoThumb() async throws {
        let live = try #require(LiveBytes.env)
        let space = try await space(live)
        let up = PixUploader(config: live.config(live.a, dir: dir.appending(path: "a")))
        guard case .completed(let item, _)? = try await upload(up, try clip(), "audio/mp4", space)?.state else { Issue.record("clip"); return }
        let page = try await live.transport(live.a).listItems(spaceID: space, pageSize: 0, pageToken: nil)
        let listed = try #require(page.items.first { $0.id == item })
        #expect(listed.kind == .audio && !listed.hasThumb && listed.duration != nil)
        let cache = PixMediaCache(config: live.config(live.a, dir: dir.appending(path: "a")))
        #expect(try Data(contentsOf: try await cache.file(item: item, spaceID: space, thumb: false)).count == Int(listed.size))
    }

    @Test func aTypeTheServerRefusesFailsAsUnsupported() async throws {
        let live = try #require(LiveBytes.env)
        let space = try await space(live)
        let up = PixUploader(config: live.config(live.a, dir: dir.appending(path: "a")))
        let gif = dir.appending(path: "x.gif")
        try Data("GIF89a".utf8).write(to: gif)
        #expect(try await upload(up, gif, "image/gif", space)?.state == .failed(.unsupported))
    }

    @Test func bytesThatAreNoImageFailAsUnsupported() async throws {
        let live = try #require(LiveBytes.env)
        let space = try await space(live)
        let up = PixUploader(config: live.config(live.a, dir: dir.appending(path: "a")))
        let junk = dir.appending(path: "junk.jpg")
        try Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 13) }).write(to: junk)
        let end = try await upload(up, junk, "image/jpeg", space)
        #expect(end?.state == .failed(.unsupported), "\(String(describing: end))")
        #expect(await up.jobs().isEmpty)
    }

    @Test func anImageOfAnotherTypeFailsAsUnreadable() async throws {
        let live = try #require(LiveBytes.env)
        let space = try await space(live)
        let up = PixUploader(config: live.config(live.a, dir: dir.appending(path: "a")))
        let png = dir.appending(path: "really-a-png.jpg")
        let img = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { c in
            UIColor.systemTeal.setFill(); c.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        try #require(img.pngData()).write(to: png)
        let end = try await upload(up, png, "image/jpeg", space)
        #expect(end?.state == .failed(.unreadable), "\(String(describing: end))")
    }

    @Test func anOutsiderGetsNothing() async throws {
        let live = try #require(LiveBytes.env)
        let space = try await space(live)
        let up = PixUploader(config: live.config(live.a, dir: dir.appending(path: "a")))
        guard case .completed(let item, _)? = try await upload(up, try smallJPEG(), "image/jpeg", space)?.state else { Issue.record("up"); return }

        let theirs = PixMediaCache(config: live.config(live.outsider, dir: dir.appending(path: "out")))
        await #expect(throws: PixTransportError.notFound) { _ = try await theirs.file(item: item, spaceID: space, thumb: false) }
        await #expect(throws: PixTransportError.notFound) { _ = try await theirs.file(item: item, spaceID: space, thumb: true) }
        let theirUp = PixUploader(config: live.config(live.outsider, dir: dir.appending(path: "out")))
        #expect(try await upload(theirUp, try smallJPEG(), "image/jpeg", space)?.state == .failed(.spaceGone))
    }

    @Test func aKilledUploadResumesWhereTheServerIs() async throws {
        let live = try #require(LiveBytes.env)
        let space = try await space(live)
        let first = PixUploader(config: live.config(live.a, dir: dir.appending(path: "a")))
        let file = try bigJPEG()
        let events = first.events()
        _ = try await first.enqueue(file: file, mimeType: "image/jpeg", spaceID: space, ownsFile: false)
        // Once the first part is in, "kill" it: copy its folder as it is now.
        for await e in events { if case .uploading(let sent, _) = e.state, sent > 0 { break } }
        let relaunched = dir.appending(path: "relaunched")
        try FileManager.default.copyItem(at: dir.appending(path: "a"), to: relaunched)
        await first.wipeAll()

        let second = PixUploader(config: live.config(live.a, dir: relaunched))
        let events2 = second.events()
        let found = await second.resumeOnLaunch()
        #expect(found.count == 1)
        let got = await collect(events2, timeout: .seconds(120))
        guard case .completed(_, .added)? = got.final else { Issue.record("\(got.states)"); return }
        let firstSent = got.compactMap { if case .uploading(let s, _) = $0.state { s } else { nil } }.first
        #expect((firstSent ?? 0) > 0, "resumed past zero: \(String(describing: firstSent))")
    }

    @Test func aRangeResumeOnTheRealServer() async throws {
        let live = try #require(LiveBytes.env)
        let space = try await space(live)
        let up = PixUploader(config: live.config(live.a, dir: dir.appending(path: "a")))
        guard case .completed(let item, _)? = try await upload(up, try bigJPEG(), "image/jpeg", space)?.state else { Issue.record("up"); return }
        let cfg = live.config(live.b, dir: dir.appending(path: "b"))
        let cache = PixMediaCache(config: cfg)
        let whole = try Data(contentsOf: try await cache.file(item: item, spaceID: space, thumb: false))
        await cache.forget(item: item, spaceID: space)

        // A part from "an earlier try" with the server's own validator.
        var head = URLRequest(url: live.base.appending(path: "v1/blobs/items/\(item.uuidString.lowercased())"))
        head.httpMethod = "HEAD"
        head.setValue("Bearer \(live.b.token)", forHTTPHeaderField: "Authorization")
        let (_, resp) = try await URLSession.shared.data(for: head)
        let etag = try #require((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"))
        let dest = cache.url(item: item, spaceID: space)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try whole.prefix(whole.count / 3).write(to: dest.appendingPathExtension("part"))
        try etag.write(to: dest.appendingPathExtension("etag"), atomically: true, encoding: .utf8)

        #expect(try Data(contentsOf: try await cache.file(item: item, spaceID: space, thumb: false)) == whole)
    }

    @Test func aDeletedItemLeavesTheCache() async throws {
        let live = try #require(LiveBytes.env)
        let space = try await space(live)
        let up = PixUploader(config: live.config(live.a, dir: dir.appending(path: "a")))
        guard case .completed(let item, _)? = try await upload(up, try smallJPEG(), "image/jpeg", space)?.state else { Issue.record("up"); return }
        let theirs = PixMediaCache(config: live.config(live.b, dir: dir.appending(path: "b")))
        _ = try await theirs.file(item: item, spaceID: space, thumb: true)
        try await live.transport(live.a).deleteItem(id: item)
        await #expect(throws: PixTransportError.notFound) { _ = try await theirs.file(item: item, spaceID: space, thumb: false) }
        #expect(await theirs.cached(item: item, spaceID: space, thumb: true) == nil)
    }
}
