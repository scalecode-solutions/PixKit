import AVFoundation
import Synchronization
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
        #expect(url.deletingLastPathComponent().path().hasSuffix("PixKit/\(config.currentUserID.uuidString.lowercased())/capture/"))
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

/// Captures never outlive the session that made them.
@MainActor
struct CaptureSweepTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "pix-sweep-\(UUID().uuidString)")

    func config(_ user: UUID) -> PixConfig {
        PixConfig(baseURL: URL(string: "http://localhost:1")!, currentUserID: user, tokenProvider: { nil }, storageDirectory: root)
    }

    @Test func capturesArePerAccount() throws {
        let a = UUID(), b = UUID()
        let fa = try PixCapture.newFile(config(a), ext: "jpg")
        let fb = try PixCapture.newFile(config(b), ext: "jpg")
        #expect(fa.path().contains("/PixKit/\(a.uuidString.lowercased())/capture/"))
        #expect(fb.path().contains("/PixKit/\(b.uuidString.lowercased())/capture/"))
        try? FileManager.default.removeItem(at: root)
    }

    @Test func makingAnEngineTouchesNothing() throws {
        // A host may build engines it throws away while a sheet is open.
        let user = UUID()
        let live = try PixCapture.newFile(config(user), ext: "mov")
        try Data([1]).write(to: live)
        _ = PixEngine(config: config(user))
        #expect(FileManager.default.fileExists(atPath: live.path()))
        try? FileManager.default.removeItem(at: root)
    }

    @Test func theFirstStartUploadsSweepsOrphansOnce() async throws {
        let user = UUID()
        let orphan = try PixCapture.newFile(config(user), ext: "mov")
        try Data([1]).write(to: orphan)
        let other = try PixCapture.newFile(config(UUID()), ext: "mov")
        try Data([1]).write(to: other)
        let engine = PixEngine(config: config(user))
        await engine.startUploads()
        #expect(!FileManager.default.fileExists(atPath: orphan.path()))
        // Someone else's folder isn't this engine's to sweep.
        #expect(FileManager.default.fileExists(atPath: other.path()))
        // A later call (the screen coming back) leaves a sheet's file alone.
        let live = try PixCapture.newFile(config(user), ext: "jpg")
        try Data([1]).write(to: live)
        await engine.startUploads()
        #expect(FileManager.default.fileExists(atPath: live.path()))
        try? FileManager.default.removeItem(at: root)
    }

    @Test func anAddBeforeStartUploadsIsNeverSwept() async throws {
        let user = UUID()
        let engine = PixEngine(config: config(user), transport: nil, cache: nil, uploader: NoUploader())
        let file = try PixCapture.newFile(config(user), ext: "jpg")
        try Data([1]).write(to: file)
        _ = await engine.add(file: file, mimeType: "image/jpeg", to: UUID(), ownsFile: true)
        await engine.startUploads()
        #expect(await NoUploader.sawFile(file))
        try? FileManager.default.removeItem(at: root)
    }

    @Test func wipeRemovesTheCaptureFolder() throws {
        let user = UUID()
        let engine = PixEngine(config: config(user))
        let left = try PixCapture.newFile(config(user), ext: "m4a")
        try Data([1]).write(to: left)
        engine.wipe()
        #expect(!FileManager.default.fileExists(atPath: try PixCapture.folder(config(user)).path()))
        try? FileManager.default.removeItem(at: root)
    }

    @Test func aFileOverTheServersLimitIsRefusedUpFront() async throws {
        let c = config(UUID())
        let url = try PixCapture.newFile(c, ext: "mov")
        FileManager.default.createFile(atPath: url.path(), contents: nil)
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: UInt64(PixCapture.maxBytes) + 1) // sparse: no real gigabyte written
        try h.close()
        await #expect(throws: PixCaptureError.tooLarge) { _ = try await PixCapture.timedFile(url) }
        try? FileManager.default.removeItem(at: root)
    }

    @Test func capturesAreProtectedUntilFirstUnlock() throws {
        let c = config(UUID())
        let url = try PixCapture.newFile(c, ext: "m4a")
        try Data([1]).write(to: url)
        PixCapture.protect(url)
        let p = try FileManager.default.attributesOfItem(atPath: url.path())[.protectionKey] as? FileProtectionType
        // The simulator doesn't keep data protection; on a device it's the class set.
        #if !targetEnvironment(simulator)
        #expect(p == .completeUntilFirstUserAuthentication)
        #else
        _ = p
        #endif
        try? FileManager.default.removeItem(at: root)
    }
}

/// An uploader that records whether the file it was handed still existed
/// after the engine went on to startUploads.
actor NoUploader: PixUploading {
    static let seen = Mutex<[URL]>([])
    static func sawFile(_ url: URL) async -> Bool {
        seen.withLock { $0.contains(url) } && FileManager.default.fileExists(atPath: url.path())
    }
    func enqueue(file: URL, mimeType: String, spaceID: UUID, ownsFile: Bool) async throws -> PixUploadID {
        Self.seen.withLock { $0.append(file) }
        return UUID()
    }
    nonisolated func events() -> AsyncStream<PixUploadEvent> { AsyncStream { _ in } }
    func cancel(_ id: PixUploadID) async {}
    func resumeOnLaunch() async -> [PixUploadEvent] { [] }
    func forgetSpace(_ spaceID: UUID) async {}
    func wipeAll() async {}
}
