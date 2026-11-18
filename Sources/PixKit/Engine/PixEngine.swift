import Foundation
import Observation
import os

private let log = Logger(subsystem: "PixKit", category: "engine")

/// Something the person should know about: a change that didn't land, or a
/// space that went away.
public struct PixNotice: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let message: String

    public init(message: String) { self.message = message }
}

/// One space's items as far as they've been loaded, newest first.
public struct PixSpaceItems: Sendable, Equatable {
    public internal(set) var items: [PixItem] = []
    /// nil once the last page is in (or before the first page loads).
    public internal(set) var nextPageToken: String?
    public internal(set) var state: PixEngine.LoadState = .idle

    /// More pages wait on the server.
    public var hasMore: Bool { nextPageToken != nil }
}

/// One upload as the UI shows it, mirrored from the uploader's events.
public struct PixUploadRow: Identifiable, Sendable, Equatable {
    public let id: PixUploadID
    public let spaceID: UUID
    public let mimeType: String
    public let size: Int64
    public let state: PixUploadState

    public var kind: PixKind? { PixKind(mimeType: mimeType) }

    /// 0…1 while bytes go up; nil when there's nothing to measure.
    public var progress: Double? {
        switch state {
        case .uploading(let sent, let total) where total > 0: Double(sent) / Double(total)
        case .processing: 1
        default: nil
        }
    }

    public var isFailed: Bool { if case .failed = state { true } else { false } }
}

/// The kit's coordinator: friends, spaces and their items, kept in memory and
/// refreshed from mvPix. The host builds it with a `PixConfig`, calls
/// `refresh()` when the spaces come on screen, and `wipe()` on sign-out.
///
/// The rules it keeps:
/// - Nothing is optimistic. A rename, a new space or a delete shows once the
///   server has answered, so the screen never shows something that isn't so.
/// - A space that answers NotFound, or drops out of the list, is gone: an
///   unfriend looks exactly like that. It leaves the list, its items and cached
///   files are dropped, its pending uploads are forgotten, and a notice says so.
///   Views showing it watch `isGone(_:)` and close.
/// - Work that started before `wipe()` never writes after it (a generation
///   counter), so a signed-out person's spaces can't come back.
@MainActor
@Observable
public final class PixEngine {
    public enum LoadState: Sendable, Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    /// People the person can share a space with, with any space already shared.
    public private(set) var friends: [PixFriend] = []
    /// The person's spaces, newest first.
    public private(set) var spaces: [PixSpace] = []
    public private(set) var spacesState: LoadState = .idle
    /// Items per space, for the spaces that have been opened.
    public private(set) var items: [UUID: PixSpaceItems] = [:]
    /// Things worth telling the person, newest last. The host shows and clears them.
    public private(set) var notices: [PixNotice] = []
    /// Spaces that went away while the engine ran (unfriend, or never reachable).
    public private(set) var goneSpaces: Set<UUID> = []
    /// The host's session was refused: it needs to sign in again.
    public private(set) var needsSignIn = false

    public let config: PixConfig
    private let transport: any PixTransport
    private let cache: (any PixMediaCaching)?
    private let uploader: (any PixUploading)?

    /// Bumped by wipe(): work that started before must not write after.
    private var generation = 0
    /// Bumped per space by every first-page load, so an older page (or a
    /// load-more of the previous list) can't land on a newer one.
    private var itemLoads: [UUID: Int] = [:]
    private var refreshing: Task<Void, Never>?
    private var listening: Task<Void, Never>?

    /// Uploads waiting, sending or failed, oldest first. A finished one leaves
    /// and its item shows in the space; a cancelled one just leaves.
    public private(set) var uploads: [PixUploadRow] = []
    /// Jobs that ended here (finished, cancelled, dismissed, space gone): no
    /// later event or late enqueue answer makes a row for them again.
    private var ended: Set<PixUploadID> = []

    public init(config: PixConfig, transport: (any PixTransport)? = nil,
                cache: (any PixMediaCaching)? = nil, uploader: (any PixUploading)? = nil) {
        self.config = config
        self.transport = transport ?? config.transport
        self.cache = cache
        self.uploader = uploader
    }

    /// Page size for items. The server's max is 500; a screenful or two is plenty.
    var pageSize = 120

    // MARK: reading

    /// The space shared with a person, if there is one.
    public func space(with person: UUID) -> PixSpace? { spaces.first { $0.otherID == person } }

    public func space(_ id: UUID) -> PixSpace? { spaces.first { $0.id == id } }

    public func friend(_ id: UUID) -> PixFriend? { friends.first { $0.id == id } }

    /// What to call a space: its name, else the other person's, else a fallback.
    public func displayName(of space: PixSpace) -> String {
        if !space.name.isEmpty { return space.name }
        if let name = friend(space.otherID)?.name, !name.isEmpty { return name }
        return String(localized: "Shared space")
    }

    /// Friends without a space yet: the ones "new space" offers.
    public var friendsWithoutSpace: [PixFriend] {
        let have = Set(spaces.map(\.otherID))
        return friends.filter { !have.contains($0.id) }
    }

    public func isGone(_ spaceID: UUID) -> Bool { goneSpaces.contains(spaceID) }

    /// Only the person who added an item may delete it (the server agrees).
    public func canDelete(_ item: PixItem) -> Bool { item.uploaderID == config.currentUserID }

    public func clearNotice(_ id: UUID) { notices.removeAll { $0.id == id } }

    // MARK: friends + spaces

    /// Reload friends and spaces. Calls made while one runs join it.
    public func refresh() async {
        if let refreshing { return await refreshing.value }
        let task = Task { await self.runRefresh() }
        refreshing = task
        await task.value
        if refreshing == task { refreshing = nil }
    }

    private func runRefresh() async {
        let gen = generation
        let goneBefore = goneSpaces
        if spaces.isEmpty { spacesState = .loading }
        async let f = transport.listFriends()
        async let s = transport.listSpaces()
        do {
            let (newFriends, newSpaces) = try await (f, s)
            guard gen == generation else { return }
            needsSignIn = false
            // A space that was here and isn't now went away (an unfriend).
            // One that went away while this ran (a NotFound elsewhere) stays
            // gone: this answer was taken before it.
            let goneMeanwhile = goneSpaces.subtracting(goneBefore)
            let fresh = newSpaces.filter { !goneMeanwhile.contains($0.id) }
            let now = Set(fresh.map(\.id))
            for old in spaces where !now.contains(old.id) { spaceGone(old.id, notify: true) }
            // One that's back (a re-friend reopens the same space) isn't gone.
            goneSpaces.subtract(now)
            friends = newFriends
            spaces = fresh
            spacesState = .loaded
        } catch {
            guard gen == generation else { return }
            spacesState = .failed(describe(error))
        }
    }

    /// Open the space with a friend, or the one already shared (safe to repeat).
    /// Returns nil, with a notice, when it couldn't.
    @discardableResult
    public func createSpace(with person: UUID) async -> PixSpace? {
        if let have = space(with: person) { return have }
        let gen = generation
        do {
            let s = try await transport.createSpace(otherID: person)
            guard gen == generation else { return nil }
            goneSpaces.remove(s.id) // a re-friend reopens the same space
            upsert(s, atFront: true)
            if let i = friends.firstIndex(where: { $0.id == person }) {
                let f = friends[i]
                friends[i] = PixFriend(id: f.id, name: f.name, avatar: f.avatar, spaceID: s.id)
            }
            return s
        } catch PixTransportError.notFound {
            guard gen == generation else { return nil }
            // Not friends (any more): the friend list is stale.
            notify(String(localized: "You can only share a space with a friend."))
            friends.removeAll { $0.id == person }
            return nil
        } catch {
            guard gen == generation else { return nil }
            notify(String(localized: "Couldn't open the space: \(describe(error))"))
            return nil
        }
    }

    /// Rename a space; "" clears the name (it then shows the other person's).
    /// Returns whether it landed.
    @discardableResult
    public func rename(_ spaceID: UUID, to name: String) async -> Bool {
        let gen = generation
        do {
            let s = try await transport.renameSpace(id: spaceID, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
            guard gen == generation else { return false }
            upsert(s, atFront: false)
            return true
        } catch {
            guard gen == generation else { return false }
            if case .invalid(let why) = error as? PixTransportError {
                notify(why.isEmpty ? String(localized: "That name can't be used.") : why)
            } else if !handleSpaceError(error, spaceID) {
                notify(String(localized: "Couldn't rename the space: \(describe(error))"))
            }
            return false
        }
    }

    // MARK: items

    /// Load a space's first page (again), replacing what's shown.
    public func loadItems(_ spaceID: UUID) async {
        let gen = generation
        let load = (itemLoads[spaceID] ?? 0) + 1
        itemLoads[spaceID] = load
        var current = items[spaceID] ?? PixSpaceItems()
        if current.items.isEmpty { current.state = .loading; items[spaceID] = current }
        do {
            let page = try await transport.listItems(spaceID: spaceID, pageSize: pageSize, pageToken: nil)
            guard gen == generation, itemLoads[spaceID] == load, !isGone(spaceID) else { return }
            items[spaceID] = PixSpaceItems(items: page.items, nextPageToken: page.nextPageToken, state: .loaded)
        } catch {
            guard gen == generation, itemLoads[spaceID] == load else { return }
            if !handleSpaceError(error, spaceID) {
                items[spaceID, default: PixSpaceItems()].state = .failed(describe(error))
            }
        }
    }

    /// Load the next page, if there is one and none is loading.
    public func loadMoreItems(_ spaceID: UUID) async {
        guard let current = items[spaceID], let token = current.nextPageToken, current.state != .loading else { return }
        let gen = generation
        let load = itemLoads[spaceID] ?? 0
        items[spaceID]?.state = .loading
        do {
            let page = try await transport.listItems(spaceID: spaceID, pageSize: pageSize, pageToken: token)
            guard gen == generation, itemLoads[spaceID] == load, !isGone(spaceID) else { return }
            var next = items[spaceID] ?? PixSpaceItems()
            // Pages are keyset pages, but an item added between them could
            // still show twice: keep the first.
            let have = Set(next.items.map(\.id))
            next.items += page.items.filter { !have.contains($0.id) }
            next.nextPageToken = page.nextPageToken
            next.state = .loaded
            items[spaceID] = next
        } catch {
            guard gen == generation, itemLoads[spaceID] == load else { return }
            if !handleSpaceError(error, spaceID) {
                items[spaceID]?.state = .failed(describe(error))
            }
        }
    }

    /// Delete one of the person's own items, for both of them. Returns whether it went.
    @discardableResult
    public func delete(_ item: PixItem) async -> Bool {
        guard canDelete(item) else {
            notify(String(localized: "Only the person who added it can delete it."))
            return false
        }
        let gen = generation
        do {
            try await transport.deleteItem(id: item.id)
            guard gen == generation else { return false }
            removeItem(item)
            if let cache { Task { await cache.forget(item: item.id, spaceID: item.spaceID) } }
            return true
        } catch PixTransportError.notFound {
            guard gen == generation else { return false }
            // Gone already, or the whole space is: reloading the space tells which.
            removeItem(item)
            await loadItems(item.spaceID)
            return true
        } catch {
            guard gen == generation else { return false }
            notify(String(localized: "Couldn't delete it: \(describe(error))"))
            return false
        }
    }

    /// Put an item the server just answered for (a finished upload) into its
    /// space, once: a re-add answers the item already there, so this replaces
    /// by id rather than appending.
    func upsertItem(_ item: PixItem) {
        guard !isGone(item.spaceID) else { return }
        var current = items[item.spaceID] ?? PixSpaceItems(state: .loaded)
        if let i = current.items.firstIndex(where: { $0.id == item.id }) {
            current.items[i] = item
        } else {
            let at = current.items.firstIndex { $0.createdAt < item.createdAt } ?? current.items.endIndex
            current.items.insert(item, at: at)
        }
        items[item.spaceID] = current
    }

    // MARK: uploads

    /// Start listening to the uploader and pick up the jobs a previous launch
    /// left. Idempotent; `wipe()` stops it.
    public func startUploads() async {
        guard let uploader, listening == nil else { return }
        let gen = generation
        // Listen first: the stream carries events from the moment of the call,
        // so a resumed job can't finish unseen in between.
        let stream = uploader.events()
        listening = Task { [weak self] in
            for await event in stream {
                guard let self, self.generation == gen else { return }
                await self.apply(event)
            }
        }
        let found = await uploader.resumeOnLaunch()
        guard gen == generation else { return }
        for event in found where uploads.first(where: { $0.id == event.id }) == nil {
            await apply(event)
        }
    }

    /// Queue a file for a space. Returns whether it was queued (a notice says
    /// why not). The add sheet checks the type with `PixKind(mimeType:)` first.
    @discardableResult
    public func add(file: URL, mimeType: String, to spaceID: UUID, ownsFile: Bool) async -> Bool {
        guard let uploader else { return false }
        guard PixKind(mimeType: mimeType) != nil else {
            notify(String(localized: "That kind of file can't be shared here."))
            return false
        }
        guard !isGone(spaceID) else {
            notify(String(localized: "That space isn't available any more."))
            return false
        }
        if listening == nil { await startUploads() }
        let gen = generation
        do {
            let id = try await uploader.enqueue(file: file, mimeType: mimeType, spaceID: spaceID, ownsFile: ownsFile)
            guard gen == generation else { return false }
            // The job may already have ended (a tiny file, or a re-add the
            // server answered at once) while this waited for enqueue.
            if !ended.contains(id), uploads.first(where: { $0.id == id }) == nil {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                uploads.append(PixUploadRow(id: id, spaceID: spaceID, mimeType: mimeType, size: size, state: .queued))
            }
            return true
        } catch {
            guard gen == generation else { return false }
            notify(String(localized: "Couldn't add it: \(describe(error))"))
            return false
        }
    }

    /// The uploads in a space, oldest first: waiting, sending, or failed.
    public func uploads(in spaceID: UUID) -> [PixUploadRow] { uploads.filter { $0.spaceID == spaceID } }

    public func cancelUpload(_ id: PixUploadID) async {
        ended.insert(id)
        uploads.removeAll { $0.id == id }
        await uploader?.cancel(id)
    }

    /// Take a failed upload's row away. The uploader is told too, so the job's
    /// staged file and journal entry go with it.
    public func dismissUpload(_ id: PixUploadID) {
        guard uploads.contains(where: { $0.id == id && $0.isFailed }) else { return }
        ended.insert(id)
        uploads.removeAll { $0.id == id }
        if let uploader { Task { await uploader.cancel(id) } }
    }

    func apply(_ event: PixUploadEvent) async {
        switch event.state {
        case .cancelled:
            ended.insert(event.id)
            uploads.removeAll { $0.id == event.id }
        case .failed(.spaceGone):
            ended.insert(event.id)
            uploads.removeAll { $0.id == event.id }
            spaceGone(event.spaceID, notify: true)
        case .failed:
            setRow(event)
        case .completed:
            ended.insert(event.id)
            uploads.removeAll { $0.id == event.id }
            // complete answers only the item id: fetch the newest page and
            // merge it in by id (a re-add's item is already there; nothing
            // appends twice).
            await mergeNewest(event.spaceID)
        case .queued, .uploading, .waiting, .processing:
            // Events for a job that's been cancelled here may still be in the stream.
            guard !isGone(event.spaceID) else { return }
            setRow(event)
        }
    }

    private func setRow(_ event: PixUploadEvent) {
        // An event still in the stream for a job that ended here (cancelled,
        // finished, dismissed) doesn't bring its row back.
        guard !ended.contains(event.id) else { return }
        let row = PixUploadRow(id: event.id, spaceID: event.spaceID, mimeType: event.mimeType,
                               size: event.size, state: event.state)
        if let i = uploads.firstIndex(where: { $0.id == event.id }) {
            uploads[i] = row
        } else {
            uploads.append(row)
        }
    }

    /// Fetch a space's first page and merge it into what's loaded, by id,
    /// without dropping the pages after it.
    func mergeNewest(_ spaceID: UUID) async {
        guard !isGone(spaceID) else { return }
        let gen = generation
        do {
            let page = try await transport.listItems(spaceID: spaceID, pageSize: pageSize, pageToken: nil)
            guard gen == generation, !isGone(spaceID) else { return }
            if items[spaceID] == nil {
                items[spaceID] = PixSpaceItems(items: page.items, nextPageToken: page.nextPageToken, state: .loaded)
            } else {
                for item in page.items { upsertItem(item) }
            }
        } catch {
            guard gen == generation else { return }
            _ = handleSpaceError(error, spaceID)
        }
    }

    // MARK: files

    /// An item's file (or thumbnail) on disk, downloading it once if needed.
    /// An item the server no longer has leaves the space; if the whole space
    /// went away, that's found out too.
    public func file(for item: PixItem, thumb: Bool = false) async throws -> URL {
        guard let cache else { throw PixTransportError.unavailable("no cache") }
        let gen = generation
        do {
            return try await cache.file(item: item.id, spaceID: item.spaceID, thumb: thumb)
        } catch PixTransportError.notFound {
            guard gen == generation else { throw PixTransportError.notFound }
            removeItem(item)
            await probe(item.spaceID)
            throw PixTransportError.notFound
        }
    }

    /// The file if it's already on disk, without asking the server.
    public func cachedFile(for item: PixItem, thumb: Bool = false) async -> URL? {
        await cache?.cached(item: item.id, spaceID: item.spaceID, thumb: thumb)
    }

    /// Ask the server whether a space is still there (one item's worth).
    private func probe(_ spaceID: UUID) async {
        let gen = generation
        do {
            _ = try await transport.listItems(spaceID: spaceID, pageSize: 1, pageToken: nil)
        } catch {
            guard gen == generation else { return }
            _ = handleSpaceError(error, spaceID)
        }
    }

    // MARK: sign-out

    /// Sign-out: forget everything in memory, delete the cache, and make sure
    /// nothing still in flight writes afterwards.
    public func wipe() {
        generation += 1
        refreshing?.cancel()
        refreshing = nil
        friends = []
        spaces = []
        items = [:]
        itemLoads = [:]
        notices = []
        goneSpaces = []
        needsSignIn = false
        spacesState = .idle
        uploads = []
        ended = []
        listening?.cancel()
        listening = nil
        if let cache { Task { await cache.wipeAll() } }
        if let uploader { Task { await uploader.wipeAll() } }
    }

    // MARK: internals

    private func upsert(_ s: PixSpace, atFront: Bool) {
        if let i = spaces.firstIndex(where: { $0.id == s.id }) {
            spaces[i] = s
        } else if atFront {
            spaces.insert(s, at: 0)
        } else {
            spaces.append(s)
        }
    }

    private func removeItem(_ item: PixItem) {
        items[item.spaceID]?.items.removeAll { $0.id == item.id }
    }

    /// The errors any space call can answer that mean more than "it failed".
    /// Returns true when handled.
    private func handleSpaceError(_ error: Error, _ spaceID: UUID) -> Bool {
        switch error as? PixTransportError {
        case .notFound?:
            spaceGone(spaceID, notify: true)
            return true
        case .notAuthenticated?:
            needsSignIn = true
            return false
        default:
            return false
        }
    }

    private func spaceGone(_ spaceID: UUID, notify shouldNotify: Bool) {
        guard !goneSpaces.contains(spaceID) else { return }
        let name = space(spaceID).map(displayName(of:))
        goneSpaces.insert(spaceID)
        spaces.removeAll { $0.id == spaceID }
        items[spaceID] = nil
        itemLoads[spaceID] = nil
        uploads.removeAll { $0.spaceID == spaceID }
        for i in friends.indices where friends[i].spaceID == spaceID {
            let f = friends[i]
            friends[i] = PixFriend(id: f.id, name: f.name, avatar: f.avatar, spaceID: nil)
        }
        log.info("space gone")
        if let cache { Task { await cache.wipe(spaceID: spaceID) } }
        if let uploader { Task { await uploader.forgetSpace(spaceID) } }
        if shouldNotify {
            notify(name.map { String(localized: "\($0) isn't available any more.") }
                   ?? String(localized: "That space isn't available any more."))
        }
    }

    private func notify(_ message: String) {
        notices.append(PixNotice(message: message))
    }

    private func describe(_ error: Error) -> String {
        if case .notAuthenticated? = error as? PixTransportError { needsSignIn = true }
        switch error as? PixTransportError {
        case .notAuthenticated?: return String(localized: "You're signed out.")
        case .notFound?: return String(localized: "It isn't there any more.")
        case .forbidden(let m)?, .invalid(let m)?: return m.isEmpty ? String(localized: "Not allowed.") : m
        case .slowDown?: return String(localized: "Too many requests. Try again in a moment.")
        case .unavailable?: return String(localized: "Can't reach the server.")
        case .serverFailed?, .badResponse?: return String(localized: "Something went wrong on the server.")
        case nil: return error.localizedDescription
        }
    }
}
