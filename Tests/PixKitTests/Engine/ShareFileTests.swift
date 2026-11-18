import Foundation
import Testing
@testable import PixKit

/// The named copies a share sheet needs: made in the account's own folder,
/// gone on sign-out and when the viewer sweeps.
@MainActor
struct ShareFileTests {
    let base = FileManager.default.temporaryDirectory.appending(path: "pixkit-share-\(UUID().uuidString)", directoryHint: .isDirectory)

    func config(_ user: UUID = UUID()) -> PixConfig {
        PixConfig(baseURL: URL(string: "http://localhost:1")!, currentUserID: user, tokenProvider: { "t" },
                  storageDirectory: base)
    }

    func source() throws -> URL {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let u = base.appending(path: UUID().uuidString.lowercased()) // like the cache: no extension
        try Data("clip".utf8).write(to: u)
        return u
    }

    @Test func aCopyIsNamedAndLivesInTheAccountsFolder() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let c = config()
        let item = UUID()
        let out = try PixShareFile.copy(try source(), mimeType: "audio/mp4", itemID: item,
                                        into: try PixShareFile.folder(c), name: "Voice clip")
        #expect(out.lastPathComponent == "Voice clip.m4a")
        #expect(out.path.hasPrefix(base.appending(path: "PixKit/\(c.currentUserID.uuidString.lowercased())/share").path))
        #expect(try Data(contentsOf: out) == Data("clip".utf8))
        // Sharing again replaces it.
        _ = try PixShareFile.copy(try source(), mimeType: "audio/mp4", itemID: item,
                                  into: try PixShareFile.folder(c), name: "Voice clip")
    }

    @Test func signOutTakesTheCopiesAndLeavesOtherAccounts() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let mine = config()
        let theirs = config()
        let a = try PixShareFile.copy(try source(), mimeType: "audio/mp4", itemID: UUID(),
                                      into: try PixShareFile.folder(mine), name: "Voice clip")
        let b = try PixShareFile.copy(try source(), mimeType: "audio/mp4", itemID: UUID(),
                                      into: try PixShareFile.folder(theirs), name: "Voice clip")
        let engine = PixEngine(config: mine, transport: FakePixServer(me: mine.currentUserID))
        engine.wipe()
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(!FileManager.default.fileExists(atPath: try PixShareFile.folder(mine).path))
        #expect(FileManager.default.fileExists(atPath: b.path))
    }
}
