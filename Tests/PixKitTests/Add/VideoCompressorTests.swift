@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import PixKit

/// The video compressor against clips made here (AVAssetWriter, H.264).
/// Serialized: the simulator's software encoder fails exports run side by
/// side (the compressor then falls back to the original, as designed), which
/// made the "brought down" tests flaky.
@Suite(.serialized) struct VideoCompressorTests {
    let config: PixConfig
    /// The account's capture folder, where sources wait and exports land.
    let dir: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "pixkit-compress-\(UUID().uuidString)", directoryHint: .isDirectory)
        config = PixConfig(baseURL: URL(string: "http://localhost:1")!, currentUserID: UUID(),
                           tokenProvider: { nil }, storageDirectory: base)
        dir = try PixCapture.directory(config)
    }

    /// A `seconds`-long clip of moving noise at width×height.
    func clip(width: Int, height: Int, seconds: Int = 2, fps: Int32 = 10) async throws -> URL {
        let url = dir.appending(path: "\(UUID().uuidString.lowercased()).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var g = SystemRandomNumberGenerator()
        for frame in 0..<(seconds * Int(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pb = try #require(buffer)
            CVPixelBufferLockBaseAddress(pb, [])
            // A moving band over a flat colour: cheap to make and to encode.
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt32.self)
            let row = CVPixelBufferGetBytesPerRow(pb) / 4
            let colour = UInt32.random(in: 0...UInt32.max, using: &g) | 0xFF00_0000
            let band = (frame * 37) % height
            for y in 0..<height {
                let v: UInt32 = abs(y - band) < 40 ? 0xFFFF_FFFF : colour
                for x in 0..<width { base[y * row + x] = v }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed, "\(String(describing: writer.error))")
        return url
    }

    func longSide(_ url: URL) async throws -> CGFloat {
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let (size, t) = try await track.load(.naturalSize, .preferredTransform)
        let shown = size.applying(t)
        return max(abs(shown.width), abs(shown.height))
    }

    @Test func aSmallVideoGoesAsItIs() async throws {
        let src = try await clip(width: 640, height: 360)
        let (url, mime) = try await PixVideoCompressor.prepare(src, mimeType: "video/quicktime", config: config)
        #expect(url == src && mime == "video/quicktime")
        #expect(FileManager.default.fileExists(atPath: src.path))
    }

    @Test func aBiggerThan1080pVideoIsBroughtDownAndTheSourceGoes() async throws {
        let src = try await clip(width: 2560, height: 1440)
        let progress = Steps()
        let (url, mime) = try await PixVideoCompressor.prepare(src, mimeType: "video/quicktime", config: config) { progress.add($0) }
        #expect(url != src && mime == "video/mp4" && url.pathExtension == "mp4")
        #expect(url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL, "lands in the capture folder")
        #expect(!FileManager.default.fileExists(atPath: src.path), "the source is gone once the new file checks out")
        #expect(try await longSide(url) <= PixVideoCompressor.maxSide)
        let d = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(d - 2) < 0.5)
        #expect(PixKind(mimeType: mime) == .video)
    }

    @Test func aFileThatIsNoVideoIsRefusedAndKept() async throws {
        let src = dir.appending(path: "junk.mov")
        try Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }).write(to: src)
        await #expect(throws: PixCaptureError.unsupported) {
            _ = try await PixVideoCompressor.prepare(src, mimeType: "video/quicktime", config: config)
        }
        #expect(FileManager.default.fileExists(atPath: src.path), "the caller decides what to do with it")
    }

    @Test func aCancelledExportLeavesOnlyTheSource() async throws {
        let src = try await clip(width: 2560, height: 1440, seconds: 4)
        let task = Task { try await PixVideoCompressor.prepare(src, mimeType: "video/quicktime", config: config) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.result
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        switch result {
        case .failure:
            #expect(files == [src.lastPathComponent], "no half-written export: \(files)")
        case .success(let (url, _)):
            // The export won the race; then it's a complete, single file.
            #expect(files == [url.lastPathComponent], "\(files)")
        }
    }
}

final class Steps: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ v: Double) { lock.withLock { values.append(v) } }
    var all: [Double] { lock.withLock { values } }
}
