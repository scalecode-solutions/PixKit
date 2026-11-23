import Foundation
import SwiftUI
import Testing
@testable import PixKit

/// The host's names win over mvPix's, mvPix's are the fallback, and a space's
/// own name beats everyone's (MVCALE-123).
@MainActor
struct HostPeopleTests {
    let me = UUID()
    let bea = UUID()
    let cal = UUID()
    let server: FakePixServer
    let engine: PixEngine

    init() {
        server = FakePixServer(me: me)
        let config = PixConfig(baseURL: URL(string: "http://localhost:1")!, currentUserID: me, tokenProvider: { "t" })
        engine = PixEngine(config: config, transport: server, cache: FakeCache(), uploader: FakeUploader())
    }

    func host(_ names: [UUID: String]) -> PixHostPeople {
        PixHostPeople(name: { names[$0] })
    }

    @Test func theHostsNameWinsAndMvPixIsTheFallback() async {
        await server.befriend(bea, name: "Bea")
        await server.befriend(cal, name: "Cal")
        await engine.refresh()
        let people = PixPeople(host: host([bea: "Bee"]), engine: engine)
        #expect(people.name(bea) == "Bee")
        #expect(people.name(cal) == "Cal") // the host doesn't know Cal
        #expect(people.name(UUID()) == "") // nobody knows them
        // An empty host answer counts as none.
        #expect(PixPeople(host: host([bea: ""]), engine: engine).name(bea) == "Bea")
        // No host: exactly mvPix.
        #expect(PixPeople(host: .none, engine: engine).name(bea) == "Bea")
    }

    @Test func aSpacesOwnNameBeatsTheHosts() async {
        await server.befriend(bea, name: "Bea")
        await server.befriend(cal, name: "Cal")
        let plain = await server.seedSpace(with: bea)
        let named = await server.seedSpace(with: cal, name: "Trip")
        await engine.refresh()
        let people = PixPeople(host: host([bea: "Bee", cal: "Callie"]), engine: engine)
        #expect(people.title(of: plain) == "Bee")
        #expect(people.title(of: named) == "Trip")
        let stranger = PixSpace(id: UUID(), otherID: UUID(), name: "", createdBy: me, createdAt: .now, renamedAt: nil)
        #expect(people.title(of: stranger) == "Shared space")
    }

    @Test func theDefaultsAnswerNothing() {
        let none = PixHostPeople.none
        #expect(none.name(bea) == nil)
        #expect(none.shortName(bea) == nil)
        #expect(none.avatar(bea, 44) == nil)
        #expect(none.presence(bea) == nil)
    }
}
