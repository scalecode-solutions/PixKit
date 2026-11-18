import Foundation
import Testing
@testable import PixKit

/// PixEngine against an in-memory mvPix: what the screen shows after each call,
/// and the rules (nothing optimistic; NotFound means the space is gone; nothing
/// written after a wipe; uploads mirrored and merged by item id).
@MainActor
struct EngineTests {
    let me: UUID
    let bea = UUID()
    let cal = UUID()
    let server: FakePixServer
    let cache = FakeCache()
    let uploader = FakeUploader()
    let engine: PixEngine

    init() {
        let me = UUID()
        self.me = me
        server = FakePixServer(me: me)
        let config = PixConfig(baseURL: URL(string: "http://localhost:1")!, currentUserID: me, tokenProvider: { "t" })
        engine = PixEngine(config: config, transport: server, cache: cache, uploader: uploader)
    }

    func friends() async {
        await server.befriend(bea, name: "Bea")
        await server.befriend(cal, name: "Cal")
    }

    // MARK: friends + spaces

    @Test func refreshShowsFriendsAndSpaces() async {
        await friends()
        let s = await server.seedSpace(with: bea)
        await engine.refresh()
        #expect(engine.spacesState == .loaded)
        #expect(engine.spaces.map(\.id) == [s.id])
        #expect(engine.friends.count == 2)
        #expect(engine.friendsWithoutSpace.map(\.id) == [cal])
        #expect(engine.space(with: bea)?.id == s.id)
    }

    @Test func aBlankNameShowsTheOtherPerson() async {
        await friends()
        let s = await server.seedSpace(with: bea)
        let named = await server.seedSpace(with: cal, name: "Trip")
        await engine.refresh()
        #expect(engine.displayName(of: s) == "Bea")
        #expect(engine.displayName(of: named) == "Trip")
        let stranger = PixSpace(id: UUID(), otherID: UUID(), name: "", createdBy: me, createdAt: .now, renamedAt: nil)
        #expect(engine.displayName(of: stranger) == "Shared space")
    }

    @Test func refreshesJoinWhileOneRuns() async {
        await friends()
        await server.hold("listSpaces")
        async let one: Void = engine.refresh()
        #expect(await eventually { await server.isHolding("listSpaces") })
        async let two: Void = engine.refresh()
        await server.release("listSpaces")
        _ = await (one, two)
        #expect(await server.calls("listSpaces") == 1)
    }

    @Test func aFailedRefreshSaysSo() async {
        await server.fail("listSpaces", with: .unavailable("down"))
        await engine.refresh()
        #expect(engine.spacesState == .failed("Can't reach the server."))
    }

    @Test func aRefusedTokenAsksForSignIn() async {
        await server.fail("listFriends", with: .notAuthenticated)
        await engine.refresh()
        #expect(engine.needsSignIn)
    }

    @Test func creatingASpaceShowsItOnceTheServerAnswers() async {
        await friends()
        await engine.refresh()
        let s = await engine.createSpace(with: bea)
        #expect(s != nil)
        #expect(engine.spaces.first?.id == s?.id)
        #expect(engine.friend(bea)?.spaceID == s?.id)
        #expect(engine.friendsWithoutSpace.map(\.id) == [cal])
        // Safe to repeat, and the engine doesn't even ask again.
        let again = await engine.createSpace(with: bea)
        #expect(again?.id == s?.id)
        #expect(await server.calls("createSpace") == 1)
        #expect(engine.spaces.count == 1)
    }

    @Test func noSpaceWithSomeoneWhoIsntAFriend() async {
        await friends()
        await engine.refresh()
        await server.unfriend(cal)
        let s = await engine.createSpace(with: cal)
        #expect(s == nil)
        #expect(engine.spaces.isEmpty)
        #expect(engine.friend(cal) == nil) // the stale friend leaves the list
        #expect(engine.notices.map(\.message) == ["You can only share a space with a friend."])
    }

    @Test func renameLandsOnlyWhenTheServerTakesIt() async {
        await friends()
        let s = await server.seedSpace(with: bea)
        await engine.refresh()
        #expect(await engine.rename(s.id, to: "  Summer  "))
        #expect(engine.space(s.id)?.name == "Summer") // trimmed
        #expect(await engine.rename(s.id, to: String(repeating: "x", count: 101)) == false)
        #expect(engine.space(s.id)?.name == "Summer")
        #expect(engine.notices.last?.message == "a name is at most 100 characters")
        #expect(await engine.rename(s.id, to: ""))
        #expect(engine.displayName(of: engine.space(s.id)!) == "Bea")
    }

    // MARK: space gone

    @Test func anUnfriendFoundByRefreshDropsTheSpaceAndItsFiles() async {
        await friends()
        let s = await server.seedSpace(with: bea)
        await server.seedItem(in: s.id, at: 1)
        await engine.refresh()
        await engine.loadItems(s.id)
        #expect(engine.items[s.id]?.items.count == 1)
        await server.unfriend(bea)
        await engine.refresh()
        #expect(engine.spaces.isEmpty)
        #expect(engine.items[s.id] == nil)
        #expect(engine.isGone(s.id))
        #expect(engine.notices.map(\.message) == ["Bea isn't available any more."])
        #expect(await eventually { await cache.wipedSpaces == [s.id] })
        #expect(await eventually { await uploader.forgottenSpaces == [s.id] })
    }

    @Test func notFoundOnASpaceCallMeansGone() async {
        await friends()
        let s = await server.seedSpace(with: bea)
        let t = await server.seedSpace(with: cal)
        await engine.refresh()
        await server.unfriend(bea)
        await engine.loadItems(s.id)
        #expect(engine.isGone(s.id) && engine.space(s.id) == nil)
        await server.unfriend(cal)
        #expect(await engine.rename(t.id, to: "x") == false)
        #expect(engine.isGone(t.id))
        #expect(engine.notices.count == 2)
    }

    @Test func goneIsReportedOnce() async {
        await friends()
        let s = await server.seedSpace(with: bea)
        await engine.refresh()
        await server.unfriend(bea)
        await engine.loadItems(s.id)
        await engine.loadItems(s.id)
        await engine.refresh()
        #expect(engine.notices.count == 1)
        #expect(await eventually { await cache.wipedSpaces == [s.id] })
    }

    @Test func aRefriendReopensTheSameSpace() async {
        await friends()
        let s = await server.seedSpace(with: bea)
        await engine.refresh()
        await server.unfriend(bea)
        await engine.refresh()
        #expect(engine.isGone(s.id))
        await server.befriend(bea, name: "Bea")
        await engine.refresh()
        let again = await engine.createSpace(with: bea)
        #expect(again?.id == s.id)
        #expect(!engine.isGone(s.id))
    }

    // MARK: items

    @Test func itemsPageNewestFirst() async {
        await friends()
        let s = await server.seedSpace(with: bea)
        for n in 1...5 { await server.seedItem(in: s.id, at: Double(n)) }
        await engine.refresh()
        engine.pageSize = 2
        await engine.loadItems(s.id)
        #expect(engine.items[s.id]?.items.map { $0.createdAt.timeIntervalSince1970 } == [5, 4])
        #expect(engine.items[s.id]?.hasMore == true)
        await engine.loadMoreItems(s.id)
        await engine.loadMoreItems(s.id)
        #expect(engine.items[s.id]?.items.map { $0.createdAt.timeIntervalSince1970 } == [5, 4, 3, 2, 1])
        #expect(engine.items[s.id]?.hasMore == false)
        await engine.loadMoreItems(s.id) // nothing more to ask for
        #expect(await server.calls("listItems") == 3)
    }

    @Test func anOlderLoadNeverLandsOnANewerOne() async {
        await friends()
        let s = await server.seedSpace(with: bea)
        await server.seedItem(in: s.id, at: 1)
        await server.seedItem(in: s.id, at: 0.5)
        await engine.refresh()
        engine.pageSize = 1
        await engine.loadItems(s.id)
        #expect(engine.items[s.id]?.hasMore == true)
        // A load-more starts, then a reload starts before it answers.
        await server.hold("listItems")
        async let more: Void = engine.loadMoreItems(s.id)
        #expect(await eventually { await server.calls("listItems") == 2 })
        await server.seedItem(in: s.id, at: 2)
        async let reload: Void = engine.loadItems(s.id)
        #expect(await eventually { await server.calls("listItems") == 3 })
        // The reload answers first, the stale load-more after it.
        await server.releaseNewest("listItems")
        await reload
        await server.release("listItems")
        await more
        // The screen shows the reload's page alone.
        #expect(engine.items[s.id]?.items.map { $0.createdAt.timeIntervalSince1970 } == [2])
    }

    @Test func deletingYourOwnItemTakesItAwayForBoth() async {
        await friends()
        let s = await server.seedSpace(with: bea)
        let mine = await server.seedItem(in: s.id, at: 2)
        await engine.refresh()
        await engine.loadItems(s.id)
        #expect(engine.canDelete(mine))
        #expect(await engine.delete(mine))
        #expect(engine.items[s.id]?.items.isEmpty == true)
        #expect(await eventually { await cache.forgotten == [mine.id] })
    }

    @Test func theOtherPersonsItemIsntYoursToDelete() async {
        await friends()
        let s = await server.seedSpace(with: bea)
        let hers = await server.seedItem(in: s.id, by: bea, at: 1)
        await engine.refresh()
        await engine.loadItems(s.id)
        #expect(!engine.canDelete(hers))
        #expect(await engine.delete(hers) == false)
        #expect(await server.calls("deleteItem") == 0) // refused before asking
        #expect(engine.items[s.id]?.items.count == 1)
    }

    @Test func deletingInASpaceThatWentAwayClosesIt() async {
        await friends()
        let s = await server.seedSpace(with: bea)
        let mine = await server.seedItem(in: s.id, at: 1)
        await engine.refresh()
        await engine.loadItems(s.id)
        await server.unfriend(bea)
        _ = await engine.delete(mine)
        #expect(engine.isGone(s.id))
        #expect(engine.items[s.id] == nil)
    }

    @Test func aFailedDeleteKeepsTheItem() async {
        await friends()
        let s = await server.seedSpace(with: bea)
        let mine = await server.seedItem(in: s.id, at: 1)
        await engine.refresh()
        await engine.loadItems(s.id)
        await server.fail("deleteItem", with: .unavailable("down"))
        #expect(await engine.delete(mine) == false)
        #expect(engine.items[s.id]?.items.count == 1)
        #expect(engine.notices.last?.message == "Couldn't delete it: Can't reach the server.")
    }

    // MARK: sign-out

    @Test func nothingWritesAfterAWipe() async {
        await friends()
        await server.seedSpace(with: bea)
        await server.hold("listSpaces")
        async let r: Void = engine.refresh()
        #expect(await eventually { await server.isHolding("listSpaces") })
        engine.wipe()
        await server.release("listSpaces")
        await r
        #expect(engine.spaces.isEmpty && engine.friends.isEmpty)
        #expect(engine.spacesState == .idle)
        #expect(await eventually { await cache.wipedAll == 1 })
        #expect(await eventually { await uploader.wipedAll == 1 })
    }

    @Test func aWipeDuringAnItemLoadLeavesNothing() async {
        await friends()
        let s = await server.seedSpace(with: bea)
        await server.seedItem(in: s.id, at: 1)
        await engine.refresh()
        await server.hold("listItems")
        async let l: Void = engine.loadItems(s.id)
        #expect(await eventually { await server.isHolding("listItems") })
        engine.wipe()
        await server.release("listItems")
        await l
        #expect(engine.items.isEmpty)
    }

    // MARK: uploads

    func event(_ id: UUID, _ space: UUID, _ state: PixUploadState) -> PixUploadEvent {
        PixUploadEvent(id: id, spaceID: space, mimeType: "image/jpeg", size: 100, uploadID: nil, state: state)
    }

    @Test func uploadsShowAsRowsAndLandAsItems() async {
        await friends()
        let s = await server.seedSpace(with: bea)
        await engine.refresh()
        await engine.loadItems(s.id)
        let file = FileManager.default.temporaryDirectory.appending(path: "frond-\(UUID()).jpg")
        try? Data(count: 100).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(await engine.add(file: file, mimeType: "image/jpeg", to: s.id, ownsFile: false))
        let id = await uploader.enqueued.first!.0
        #expect(engine.uploads(in: s.id).map(\.id) == [id])
        #expect(engine.uploads.first?.size == 100)
        await uploader.emit(event(id, s.id, .uploading(sent: 50, total: 100)))
        #expect(await eventually { engine.uploads.first?.progress == 0.5 })
        // The server stores it; the uploader says so with the item's id.
        let item = await server.seedItem(in: s.id, at: 9)
        await uploader.emit(event(id, s.id, .completed(itemID: item.id, outcome: .added)))
        #expect(await eventually { engine.uploads.isEmpty })
        #expect(await eventually { engine.items[s.id]?.items.map(\.id) == [item.id] })
    }

    @Test func aReAddDoesntShowTwice() async {
        await friends()
        let s = await server.seedSpace(with: bea)
        let item = await server.seedItem(in: s.id, at: 1)
        await engine.refresh()
        await engine.loadItems(s.id)
        await engine.startUploads()
        let id = UUID()
        await uploader.emit(event(id, s.id, .processing))
        #expect(await eventually { engine.uploads.count == 1 })
        await uploader.emit(event(id, s.id, .completed(itemID: item.id, outcome: .existing)))
        #expect(await eventually { engine.uploads.isEmpty })
        #expect(await eventually { await server.calls("listItems") == 2 })
        #expect(engine.items[s.id]?.items.map(\.id) == [item.id])
    }

    @Test func mergingTheNewestKeepsLaterPages() async {
        await friends()
        let s = await server.seedSpace(with: bea)
        for n in 1...4 { await server.seedItem(in: s.id, at: Double(n)) }
        await engine.refresh()
        engine.pageSize = 2
        await engine.loadItems(s.id)
        await engine.loadMoreItems(s.id)
        await server.seedItem(in: s.id, at: 10)
        await engine.mergeNewest(s.id)
        #expect(engine.items[s.id]?.items.map { $0.createdAt.timeIntervalSince1970 } == [10, 4, 3, 2, 1])
    }

    @Test func aFailedUploadStaysUntilDismissed() async {
        await friends()
        let s = await server.seedSpace(with: bea)
        await engine.refresh()
        await engine.startUploads()
        let id = UUID()
        await uploader.emit(event(id, s.id, .failed(.tooLarge)))
        #expect(await eventually { engine.uploads.first?.isFailed == true })
        engine.dismissUpload(id)
        #expect(engine.uploads.isEmpty)
    }

    @Test func anUploadToAGoneSpaceClosesIt() async {
        await friends()
        let s = await server.seedSpace(with: bea)
        await engine.refresh()
        await engine.startUploads()
        let other = UUID()
        await uploader.emit(event(other, s.id, .queued))
        await uploader.emit(event(UUID(), s.id, .failed(.spaceGone)))
        #expect(await eventually { engine.isGone(s.id) })
        #expect(engine.uploads.isEmpty) // its other rows went with it
        // A late event for a job in that space doesn't bring a row back.
        await uploader.emit(event(other, s.id, .uploading(sent: 1, total: 2)))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(engine.uploads.isEmpty)
    }

    @Test func cancellingTakesTheRowAway() async {
        await friends()
        let s = await server.seedSpace(with: bea)
        await engine.refresh()
        await engine.startUploads()
        let id = UUID()
        await uploader.emit(event(id, s.id, .queued))
        #expect(await eventually { engine.uploads.count == 1 })
        await engine.cancelUpload(id)
        #expect(engine.uploads.isEmpty)
        #expect(await uploader.cancelled == [id])
    }

    @Test func jobsFromTheLastLaunchShow() async {
        await friends()
        let s = await server.seedSpace(with: bea)
        let id = UUID()
        await uploader.setResumable([event(id, s.id, .queued)])
        await engine.refresh()
        await engine.startUploads()
        await engine.startUploads() // idempotent
        #expect(engine.uploads.map(\.id) == [id])
        #expect(await uploader.listeners == 1)
    }

    @Test func aTypeTheServerWontTakeIsRefusedBeforeQueueing() async {
        await friends()
        let s = await server.seedSpace(with: bea)
        await engine.refresh()
        let file = FileManager.default.temporaryDirectory.appending(path: "x.gif")
        #expect(await engine.add(file: file, mimeType: "image/gif", to: s.id, ownsFile: false) == false)
        #expect(await uploader.enqueued.isEmpty)
        #expect(engine.notices.last?.message == "That kind of file can't be shared here.")
    }

    @Test func aWipeStopsMirroringUploads() async {
        await friends()
        let s = await server.seedSpace(with: bea)
        await engine.refresh()
        await engine.startUploads()
        engine.wipe()
        await uploader.emit(event(UUID(), s.id, .queued))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(engine.uploads.isEmpty)
    }
}
