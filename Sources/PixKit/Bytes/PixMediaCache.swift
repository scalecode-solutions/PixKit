import Foundation

/// The disk cache for items' files and thumbnails, in the shape of the
/// host's own media cache: Library/Caches/PixKit/<account>/<space>/<item>,
/// with the thumbnail beside it as <item>.thumb. iOS may reclaim Caches
/// under storage pressure; a missing file just downloads again.
///
/// Files are keyed by item id (an item's bytes never change), so a hit is
/// served without asking the server. Concurrent asks for one file share a
/// single download. Nothing here outlives the account: sign-out wipes the
/// account's folder, and a space that's gone (unfriended, NotFound) wipes
/// its own.
public actor PixMediaCache: PixMediaCaching {
    public nonisolated let root: URL
    private let client: PixBlobClient
    private var inFlight: [String: Task<URL, Error>] = [:]
    /// Bumped by each wipe, so a download that lands after its space (or
    /// the account) was wiped is removed instead of kept.
    private var wipes: [UUID: Int] = [:]
    private var wipeAllCount = 0

    /// - Parameters:
    ///   - account: the signed-in user's id; each account gets its own folder.
    ///   - base: the caches directory (tests pass a temp folder).
    public init(config: PixConfig) {
        self.init(account: config.currentUserID, client: PixBlobClient(config: config), base: config.storageDirectory)
    }

    init(account: UUID, client: PixBlobClient, base: URL? = nil) {
        let caches = base ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.root = caches
            .appending(path: "PixKit", directoryHint: .isDirectory)
            .appending(path: account.uuidString.lowercased(), directoryHint: .isDirectory)
        self.client = client
    }

    /// Where an item's file (or thumbnail) lives once cached.
    public nonisolated func url(item: UUID, spaceID space: UUID, thumb: Bool = false) -> URL {
        root.appending(path: space.uuidString.lowercased(), directoryHint: .isDirectory)
            .appending(path: item.uuidString.lowercased() + (thumb ? ".thumb" : ""))
    }

    /// The cached file, if it's on disk.
    public func cached(item: UUID, spaceID space: UUID, thumb: Bool = false) -> URL? {
        let u = url(item: item, spaceID: space, thumb: thumb)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// The item's file (or thumbnail): from disk, or downloaded once.
    public func file(item: UUID, spaceID space: UUID, thumb: Bool = false) async throws -> URL {
        if let hit = cached(item: item, spaceID: space, thumb: thumb) { return hit }
        let dest = url(item: item, spaceID: space, thumb: thumb)
        let key = dest.path
        if let running = inFlight[key] { return try await running.value }
        let client = self.client
        let epoch = (wipes[space, default: 0], wipeAllCount)
        let task = Task<URL, Error> {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await client.download(item: item, thumb: thumb, to: dest)
            return dest
        }
        inFlight[key] = task
        defer { if inFlight[key] == task { inFlight[key] = nil } }
        do {
            let got = try await task.value
            guard epoch == (wipes[space, default: 0], wipeAllCount) else {
                forget(item: item, spaceID: space)
                throw CancellationError()
            }
            return got
        } catch let err as PixBlobError where err.reason == "ITEM_NOT_FOUND" {
            // Deleted, or the space is no longer ours: nothing of it stays.
            forget(item: item, spaceID: space)
            throw PixTransportError.notFound
        } catch let err as PixBlobError {
            throw err.transportError
        }
    }

    /// Drops one item's files (its owner deleted it).
    public func forget(item: UUID, spaceID space: UUID) {
        let fm = FileManager.default
        for thumb in [false, true] {
            let u = url(item: item, spaceID: space, thumb: thumb)
            for f in [u, u.appendingPathExtension("part"), u.appendingPathExtension("etag")] {
                try? fm.removeItem(at: f)
            }
        }
    }

    /// Drops everything cached for a space (unfriended, or NotFound).
    public func wipe(spaceID space: UUID) {
        wipes[space, default: 0] += 1
        cancelInFlight(prefix: root.appending(path: space.uuidString.lowercased(), directoryHint: .isDirectory).path)
        try? FileManager.default.removeItem(at: root.appending(path: space.uuidString.lowercased(), directoryHint: .isDirectory))
    }

    /// Drops everything cached for the account (sign-out).
    public func wipeAll() {
        wipeAllCount += 1
        cancelInFlight(prefix: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    /// Bytes on disk for this account.
    public func size() -> Int64 {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private func cancelInFlight(prefix: String) {
        for (key, task) in inFlight where key.hasPrefix(prefix) {
            task.cancel()
            inFlight[key] = nil
        }
    }
}
