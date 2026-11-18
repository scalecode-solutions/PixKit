import Foundation
import Synchronization
@testable import PixKit

/// An in-memory mvPix for engine tests, keeping the server's rules: a space is
/// two friends' and reachable only while they're friends (NotFound otherwise,
/// like anything that isn't yours); one space per pair (create is safe to
/// repeat); only the uploader may delete (PermissionDenied for the other
/// member; NotFound once unreachable); items newest first in pages.
actor FakePixServer: PixTransport {
    let me: UUID
    private(set) var friendIDs: [UUID: String] = [:]
    private(set) var spaces: [UUID: PixSpace] = [:]
    private var items: [UUID: [PixItem]] = [:] // by space, newest first
    private var deleted: Set<UUID> = []
    /// Fails the next call of a method (by name) with this error.
    private var failNext: [String: PixTransportError] = [:]
    /// Calls held until `release(_:)`.
    private var holding: Set<String> = []
    private var held: [String: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var calls: [String] = []

    init(me: UUID) { self.me = me }

    // MARK: arranging

    func befriend(_ id: UUID, name: String) { friendIDs[id] = name }
    func unfriend(_ id: UUID) { friendIDs[id] = nil }
    func fail(_ method: String, with error: PixTransportError) { failNext[method] = error }
    func hold(_ method: String) { holding.insert(method) }
    func release(_ method: String) {
        holding.remove(method)
        for c in held.removeValue(forKey: method) ?? [] { c.resume() }
    }
    /// Lets only the newest held call of a method answer (the rest stay held).
    func releaseNewest(_ method: String) {
        guard let c = held[method]?.popLast() else { return }
        c.resume()
    }
    func isHolding(_ method: String) -> Bool { !(held[method] ?? []).isEmpty }

    @discardableResult
    func seedSpace(with other: UUID, name: String = "", createdAt: Date = Date(timeIntervalSince1970: 1000)) -> PixSpace {
        let s = PixSpace(id: UUID(), otherID: other, name: name, createdBy: me, createdAt: createdAt, renamedAt: nil)
        spaces[s.id] = s
        return s
    }

    @discardableResult
    func seedItem(in spaceID: UUID, by uploader: UUID? = nil, kind: PixKind = .photo, at seconds: Double) -> PixItem {
        let i = PixItem(id: UUID(), spaceID: spaceID, uploaderID: uploader ?? me, kind: kind,
                        mimeType: kind == .photo ? "image/jpeg" : kind == .video ? "video/mp4" : "audio/mp4",
                        size: 10, width: 0, height: 0, duration: kind == .photo ? nil : .seconds(3),
                        createdAt: Date(timeIntervalSince1970: seconds), hasThumb: kind != .audio)
        items[spaceID, default: []].append(i)
        items[spaceID]!.sort { $0.createdAt > $1.createdAt }
        return i
    }

    func calls(_ method: String) -> Int { calls.filter { $0 == method }.count }

    // MARK: the rules

    private func enter(_ method: String) async throws {
        calls.append(method)
        if holding.contains(method) {
            await withCheckedContinuation { held[method, default: []].append($0) }
        }
        if let e = failNext.removeValue(forKey: method) { throw e }
    }

    private func reachable(_ spaceID: UUID) throws -> PixSpace {
        guard let s = spaces[spaceID], friendIDs[s.otherID] != nil else { throw PixTransportError.notFound }
        return s
    }

    // MARK: PixTransport

    func whoAmI() async throws -> UUID {
        try await enter("whoAmI")
        return me
    }

    func listFriends() async throws -> [PixFriend] {
        try await enter("listFriends")
        return friendIDs.map { id, name in
            PixFriend(id: id, name: name, avatar: nil, spaceID: spaces.values.first { $0.otherID == id }?.id)
        }.sorted { $0.name < $1.name }
    }

    func listSpaces() async throws -> [PixSpace] {
        try await enter("listSpaces")
        return spaces.values.filter { friendIDs[$0.otherID] != nil }.sorted { $0.createdAt > $1.createdAt }
    }

    func createSpace(otherID: UUID) async throws -> PixSpace {
        try await enter("createSpace")
        guard friendIDs[otherID] != nil else { throw PixTransportError.notFound }
        if let s = spaces.values.first(where: { $0.otherID == otherID }) { return s }
        return seedSpace(with: otherID, createdAt: Date())
    }

    func renameSpace(id: UUID, name: String) async throws -> PixSpace {
        try await enter("renameSpace")
        let s = try reachable(id)
        guard name.unicodeScalars.count <= 100 else { throw PixTransportError.invalid("a name is at most 100 characters") }
        let r = PixSpace(id: s.id, otherID: s.otherID, name: name, createdBy: s.createdBy, createdAt: s.createdAt,
                         renamedAt: Date())
        spaces[id] = r
        return r
    }

    func listItems(spaceID: UUID, pageSize: Int, pageToken: String?) async throws -> PixItemPage {
        try await enter("listItems")
        _ = try reachable(spaceID)
        let live = (items[spaceID] ?? []).filter { !deleted.contains($0.id) }
        let start = pageToken.flatMap { t in live.firstIndex { $0.id.uuidString == t }.map { $0 + 1 } } ?? 0
        let size = pageSize == 0 ? 500 : pageSize
        let page = Array(live.dropFirst(start).prefix(size))
        let more = start + page.count < live.count
        return PixItemPage(items: page, nextPageToken: more ? page.last?.id.uuidString : nil)
    }

    func deleteItem(id: UUID) async throws {
        try await enter("deleteItem")
        guard let (sid, item) = items.lazy.compactMap({ s, list in list.first { $0.id == id }.map { (s, $0) } }).first
        else { throw PixTransportError.notFound }
        _ = try reachable(sid)
        guard item.uploaderID == me else { throw PixTransportError.forbidden("only the person who added it") }
        deleted.insert(id)
    }
}

/// Records what the engine asked of the cache.
actor FakeCache: PixMediaCaching {
    private(set) var wipedSpaces: [UUID] = []
    private(set) var forgotten: [UUID] = []
    private(set) var wipedAll = 0

    func cached(item: UUID, spaceID: UUID, thumb: Bool) async -> URL? { nil }
    func file(item: UUID, spaceID: UUID, thumb: Bool) async throws -> URL { throw PixTransportError.notFound }
    func forget(item: UUID, spaceID: UUID) async { forgotten.append(item) }
    func wipe(spaceID: UUID) async { wipedSpaces.append(spaceID) }
    func wipeAll() async { wipedAll += 1 }
}

/// An uploader the test drives by hand: it emits what the test says.
actor FakeUploader: PixUploading {
    private let continuations = Mutex<[AsyncStream<PixUploadEvent>.Continuation]>([])
    private(set) var enqueued: [(PixUploadID, UUID, String)] = []
    private(set) var cancelled: [PixUploadID] = []
    private(set) var forgottenSpaces: [UUID] = []
    private(set) var wipedAll = 0
    var resumable: [PixUploadEvent] = []
    var enqueueError: PixTransportError?

    func setResumable(_ events: [PixUploadEvent]) { resumable = events }
    func setEnqueueError(_ e: PixTransportError?) { enqueueError = e }

    func emit(_ event: PixUploadEvent) {
        for c in continuations.withLock({ $0 }) { c.yield(event) }
    }

    var listeners: Int { continuations.withLock { $0.count } }

    func enqueue(file: URL, mimeType: String, spaceID: UUID, ownsFile: Bool) async throws -> PixUploadID {
        if let enqueueError { throw enqueueError }
        let id = UUID()
        enqueued.append((id, spaceID, mimeType))
        return id
    }

    nonisolated func events() -> AsyncStream<PixUploadEvent> {
        let (stream, continuation) = AsyncStream<PixUploadEvent>.makeStream()
        continuations.withLock { $0.append(continuation) }
        return stream
    }

    func cancel(_ id: PixUploadID) async { cancelled.append(id) }
    func resumeOnLaunch() async -> [PixUploadEvent] { resumable }
    func forgetSpace(_ spaceID: UUID) async { forgottenSpaces.append(spaceID) }
    func wipeAll() async { wipedAll += 1 }
}

/// Waits (briefly) for something the engine does in a detached task.
@MainActor
func eventually(_ check: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await check() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}
