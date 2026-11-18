import AVFoundation
import Foundation
import Testing
@testable import PixKit

/// A picked or recorded video on its way to the queue: length first, then
/// compressed when it's big, then the size the server takes.
extension VideoCompressorTests {
    func mp4s() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path())) ?? []).filter { $0.hasSuffix(".mp4") }
    }

    @Test func aSmallCameraVideoGoesAsItIs() async throws {
        let src = try await clip(width: 640, height: 360)
        let (out, mime) = try await PixCapture.preparedVideo(src, config: config)
        #expect(out == src && mime == "video/quicktime")
    }

    @Test func aBigVideoIsCompressedBeforeItsQueued() async throws {
        let src = try await clip(width: 2560, height: 1440)
        let (out, mime) = try await PixCapture.preparedVideo(src, config: config)
        #expect(mime == "video/mp4" && out.pathExtension == "mp4")
        #expect(try await longSide(out) <= 1920)
        #expect(!FileManager.default.fileExists(atPath: src.path()))
    }

    /// Too long is refused before any export: nothing is made, and the source
    /// is still the caller's to throw away.
    @Test func aTooLongVideoIsRefusedWithoutExporting() async throws {
        let src = try await clip(width: 2560, height: 1440, seconds: Int(PixCapture.maxDuration) + 20, fps: 1)
        await #expect(throws: PixCaptureError.tooLong) { _ = try await PixCapture.preparedVideo(src, config: config) }
        #expect(mp4s().isEmpty)
        #expect(FileManager.default.fileExists(atPath: src.path()))
    }

    @Test func aFileThatIsntAMovieTypeIsRefused() async throws {
        let src = dir.appending(path: "x.webm")
        try Data([1, 2, 3]).write(to: src)
        await #expect(throws: PixCaptureError.unsupported) { _ = try await PixCapture.preparedVideo(src, config: config) }
    }
}
