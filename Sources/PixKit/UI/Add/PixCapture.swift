import Foundation
import UniformTypeIdentifiers
import AVFoundation
import UIKit

/// Where captured and picked files wait before they're queued: the camera's
/// photos and videos, audio clips, and copies of what was picked from the
/// library. Not tmp: a resume after the app is killed must still find them.
/// A file leaves this folder by being queued (`ownsFile: true`, the uploader
/// deletes it when the job ends) or by being thrown away here (cancel, retake).
public enum PixCapture {
    /// The longest video or audio clip the server keeps (mvPix's cap is 5 min
    /// plus a little slack).
    public static let maxDuration: TimeInterval = 300
    /// The largest file mvPix takes by default (PIX_MAX_UPLOAD_MB 1024): refuse
    /// bigger before copying it anywhere.
    public static let maxBytes: Int64 = 1 << 30

    /// The account's capture folder, beside the uploader's and the cache's:
    /// `<storage>/PixKit/<account>/capture/`.
    static func folder(_ config: PixConfig) throws -> URL {
        let base = try config.storageDirectory
            ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
        return base.appending(path: "PixKit", directoryHint: .isDirectory)
            .appending(path: config.currentUserID.uuidString.lowercased(), directoryHint: .isDirectory)
            .appending(path: "capture", directoryHint: .isDirectory)
    }

    static func directory(_ config: PixConfig) throws -> URL {
        let dir = try folder(config)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var d = dir
        try? d.setResourceValues(values)
        return dir
    }

    /// A new file in the capture folder.
    static func newFile(_ config: PixConfig, ext: String) throws -> URL {
        try directory(config).appending(path: "\(UUID().uuidString.lowercased()).\(ext)")
    }

    /// Everything in the capture folder is an orphan whenever no add sheet is
    /// open: a queued file was moved out before enqueue returned, and a thrown
    /// away one deleted. The engine sweeps it when it's made and on wipe (a
    /// kill mid-capture, a cover closed under a review).
    static func sweep(_ config: PixConfig) {
        guard let dir = try? folder(config) else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Same protection for every capture, however it was written (the
    /// recorders and the picker's move don't take options).
    static func protect(_ url: URL) {
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                               ofItemAtPath: url.path)
    }

    /// Throw a capture away (cancel, retake, refused).
    static func discard(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// The MIME type the server expects for a file type, if it takes it.
    static func mimeType(for type: UTType) -> String? {
        if type.conforms(to: .heic) { return "image/heic" }
        if type.conforms(to: .heif) { return "image/heif" }
        if type.conforms(to: .jpeg) { return "image/jpeg" }
        if type.conforms(to: .png) { return "image/png" }
        if type.conforms(to: .quickTimeMovie) { return "video/quicktime" }
        if type.conforms(to: .mpeg4Movie) { return "video/mp4" }
        if type.conforms(to: .mpeg4Audio) { return "audio/mp4" }
        if type.conforms(to: .mp3) { return "audio/mpeg" }
        return nil
    }

    /// A picked image's bytes as a file the server takes: kept as they are when
    /// it's JPEG, PNG or HEIC, otherwise (GIF, WebP, RAW…) re-encoded as JPEG.
    static func imageFile(_ config: PixConfig, data: Data, type: UTType?) throws -> (URL, String) {
        if let type, let mime = mimeType(for: type), mime.hasPrefix("image/") {
            let url = try newFile(config, ext: type.preferredFilenameExtension ?? "img")
            try data.write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
            return (url, mime)
        }
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) else {
            throw PixCaptureError.unsupported
        }
        let url = try newFile(config, ext: "jpg")
        try jpeg.write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
        return (url, "image/jpeg")
    }

    /// A picked or recorded movie or clip: its MIME type, refusing what the
    /// server wouldn't keep (an unknown type, or longer than `maxDuration`).
    static func timedFile(_ url: URL) async throws -> String {
        guard let type = UTType(filenameExtension: url.pathExtension), let mime = mimeType(for: type) else {
            throw PixCaptureError.unsupported
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if Int64(size) > maxBytes { throw PixCaptureError.tooLarge }
        let seconds = try await AVURLAsset(url: url).load(.duration).seconds
        if seconds.isFinite, seconds > maxDuration + 10 { throw PixCaptureError.tooLong }
        return mime
    }
}

enum PixCaptureError: Error, Equatable {
    case unsupported, tooLong, tooLarge, denied, unavailable

    var message: String {
        switch self {
        case .unsupported: String(localized: "That kind of file can't be shared here.")
        case .tooLong: String(localized: "Videos and clips can be up to 5 minutes.")
        case .tooLarge: String(localized: "That file is too big to share (over 1 GB).")
        case .denied: String(localized: "Allow access in Settings to use this.")
        case .unavailable: String(localized: "This isn't available on this device.")
        }
    }
}
