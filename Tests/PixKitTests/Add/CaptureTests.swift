import AVFoundation
import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import PixKit

/// The add sheet's files: where captures wait, which types go as they are,
/// which get re-encoded, and what's refused before anything is queued.
struct CaptureTests {
    let root: URL
    let config: PixConfig

    init() {
        root = FileManager.default.temporaryDirectory.appending(path: "pix-capture-\(UUID().uuidString)")
        config = PixConfig(baseURL: URL(string: "http://localhost:1")!, currentUserID: UUID(),
                           tokenProvider: { nil }, storageDirectory: root)
    }

    @Test func capturesWaitInTheStorageFolderOutOfBackups() throws {
        let url = try PixCapture.newFile(config, ext: "jpg")
        #expect(url.deletingLastPathComponent().path().hasSuffix("PixKit/capture/"))
        #expect(url.path().hasPrefix(root.path()))
        let dir = try PixCapture.directory(config)
        #expect(try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func mimeTypesMatchWhatTheServerTakes() {
        let cases: [(UTType, String?)] = [
            (.jpeg, "image/jpeg"), (.png, "image/png"), (.heic, "image/heic"),
            (.quickTimeMovie, "video/quicktime"), (.mpeg4Movie, "video/mp4"),
            (.mpeg4Audio, "audio/mp4"), (.mp3, "audio/mpeg"),
            (.gif, nil), (.webP, nil), (.pdf, nil),
        ]
        for (type, mime) in cases {
            #expect(PixCapture.mimeType(for: type) == mime, "\(type)")
            // Whatever the add sheet sends, the engine and server accept.
            if let mime { #expect(PixKind(mimeType: mime) != nil, "\(mime)") }
        }
    }

    private func pixel() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    @Test func aPNGGoesAsItIs() throws {
        let data = try #require(pixel().pngData())
        let (url, mime) = try PixCapture.imageFile(config, data: data, type: .png)
        #expect(mime == "image/png" && url.pathExtension == "png")
        #expect(try Data(contentsOf: url) == data)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func anImageTheServerWontTakeBecomesJPEG() throws {
        // Bytes UIImage can read, declared as a type the server refuses.
        let data = try #require(pixel().pngData())
        let (url, mime) = try PixCapture.imageFile(config, data: data, type: .gif)
        #expect(mime == "image/jpeg" && url.pathExtension == "jpg")
        let head = try Data(contentsOf: url).prefix(3)
        #expect(head == Data([0xFF, 0xD8, 0xFF]))
        try? FileManager.default.removeItem(at: root)
    }

    @Test func bytesThatArentAnImageAreRefused() {
        #expect(throws: PixCaptureError.unsupported) {
            _ = try PixCapture.imageFile(config, data: Data("not an image".utf8), type: .webP)
        }
        // Nothing left behind.
        let left = (try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: "PixKit/capture").path())) ?? []
        #expect(left.isEmpty)
        try? FileManager.default.removeItem(at: root)
    }

    /// A short AAC clip written with AVAudioFile.
    private func clip(seconds: Double) throws -> URL {
        let url = try PixCapture.newFile(config, ext: "m4a")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                                AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1])
        let frames = AVAudioFrameCount(8000 * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }

    @Test func aShortClipIsAudioMP4() async throws {
        let url = try clip(seconds: 1)
        #expect(try await PixCapture.timedFile(url) == "audio/mp4")
        try? FileManager.default.removeItem(at: root)
    }

    @Test func aClipOverFiveMinutesIsRefused() async throws {
        let url = try clip(seconds: PixCapture.maxDuration + 20)
        await #expect(throws: PixCaptureError.tooLong) { _ = try await PixCapture.timedFile(url) }
        try? FileManager.default.removeItem(at: root)
    }

    @Test func anUnknownExtensionIsRefused() async throws {
        let url = try PixCapture.newFile(config, ext: "xyz")
        try Data([1]).write(to: url)
        await #expect(throws: PixCaptureError.unsupported) { _ = try await PixCapture.timedFile(url) }
        try? FileManager.default.removeItem(at: root)
    }

    @Test func permissionPromptsGoThroughTheHost() async {
        let seen = PromptCounter()
        let hosted = PixConfig(baseURL: URL(string: "http://localhost:1")!, currentUserID: UUID(), tokenProvider: { nil },
                               systemPrompt: { request in await seen.bump(); return await request() })
        #expect(await hosted.prompt { true })
        #expect(await seen.value == 1)
        // No hook: the request runs as is.
        #expect(await config.prompt { false } == false)
    }
}

actor PromptCounter {
    var value = 0
    func bump() { value += 1 }
}
