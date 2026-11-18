@preconcurrency import AVFoundation
import Foundation

/// Makes a video ready to queue: anything bigger than 1080p (or heavier than
/// `passThroughBytes`) is re-encoded to fit 1920×1080, HEVC where the device
/// has it, as .mp4. Small videos go as
/// they are. The new file goes in the account's capture folder. The source is deleted only once the new file checks out; when
/// the export fails, the source goes as it is if the server would take its
/// size, and is refused otherwise.
enum PixVideoCompressor {
    /// The longest side a queued video keeps.
    static let maxSide: CGFloat = 1920
    /// A video at or under 1080p and this size is sent as it is.
    static let passThroughBytes: Int64 = 200 << 20
    /// mvPix's upload limit: one number, PixCapture's.
    static var serverMaxBytes: Int64 { PixCapture.maxBytes }

    /// A file to queue and its MIME type: `source` itself (unchanged), or a
    /// new .mp4 beside it (and `source` is gone).
    static func prepare(_ source: URL, mimeType: String, config: PixConfig,
                        progress: (@Sendable (Double) -> Void)? = nil) async throws -> (URL, String) {
        let asset = AVURLAsset(url: source)
        let size = fileSize(source)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let geometry = try? await track.load(.naturalSize, .preferredTransform),
              let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 else {
            throw PixCaptureError.unsupported
        }
        let shown = geometry.0.applying(geometry.1)
        let longSide = max(abs(shown.width), abs(shown.height))
        if longSide <= maxSide, size <= passThroughBytes { return (source, mimeType) }

        do {
            let out = try await export(asset, to: PixCapture.newFile(config, ext: "mp4"), progress: progress)
            let outSize = fileSize(out)
            let outDuration = try await AVURLAsset(url: out).load(.duration).seconds
            guard outSize > 0, abs(outDuration - duration.seconds) < 1 else {
                try? FileManager.default.removeItem(at: out)
                throw PixCaptureError.unsupported
            }
            if longSide <= maxSide, outSize >= size, size <= serverMaxBytes {
                // Only its weight was the reason, and re-encoding didn't
                // help (already efficient): keep the original.
                try? FileManager.default.removeItem(at: out)
                return (source, mimeType)
            }
            guard outSize <= serverMaxBytes else {
                try? FileManager.default.removeItem(at: out)
                throw PixCaptureError.tooLarge
            }
            try? FileManager.default.removeItem(at: source)
            return (out, "video/mp4")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            guard size <= serverMaxBytes else { throw PixCaptureError.tooLarge }
            return (source, mimeType)
        }
    }

    private static func export(_ asset: AVURLAsset, to out: URL,
                               progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        let presets = await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetHEVC1920x1080,
                                                                with: asset, outputFileType: .mp4)
        let preset = presets ? AVAssetExportPresetHEVC1920x1080 : AVAssetExportPreset1920x1080
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw PixCaptureError.unsupported }
        session.shouldOptimizeForNetworkUse = true
        // No location or device details in what's shared.
        session.metadataItemFilter = .forSharing()
        nonisolated(unsafe) let watched = session
        let watcher = Task {
            for await state in watched.states(updateInterval: 0.25) {
                if case .exporting(let p) = state { progress?(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        do {
            try await session.export(to: out, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        // A cancel that lands as the export finishes still leaves nothing behind.
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: out)
            throw CancellationError()
        }
        return out
    }

    static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
}
