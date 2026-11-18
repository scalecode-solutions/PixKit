import XCTest

/// The whole path with real files, against a THROWAWAY local mvPix
/// (PIX_DEV_BASE): open a space with a friend, add a photo and a big video
/// from the library (the video is compressed first), see them land in the
/// grid, open them, delete one, and sign out to an empty kit folder.
/// Writes, so it never runs against the shared :6102 (scripts/e2e-test.sh).
final class PixLabEndToEndUITests: XCTestCase {
    var app: XCUIApplication!
    var friend = ""

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["PIX_E2E"] == "1", let token = env["PIX_DEV_TOKEN"], let user = env["PIX_DEV_USER"],
              let base = env["PIX_DEV_BASE"], let friend = env["PIX_E2E_FRIEND"] else {
            throw XCTSkip("run through scripts/e2e-test.sh")
        }
        self.friend = friend
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment = ["PIX_DEV_TOKEN": token, "PIX_DEV_USER": user, "PIX_DEV_BASE": base]
        app.launch()
    }

    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func dump(_ name: String) {
        let a = XCTAttachment(string: app.debugDescription)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func wait(_ e: XCUIElement, _ seconds: TimeInterval = 10, _ what: String) {
        if !e.waitForExistence(timeout: seconds) { dump("missing-\(what)"); XCTFail("no \(what)") }
    }

    func testAddViewDeleteAndSignOut() throws {
        XCTAssert(app.navigationBars["Spaces"].waitForExistence(timeout: 15))

        // Open the space with the friend (or the one already there).
        let new = app.buttons["pix.spaces.new"]
        wait(new, 10, "new-space")
        for _ in 0..<50 where !new.isEnabled { usleep(200_000) }
        new.tap()
        let pick = app.buttons["pix.friend.\(friend)"]
        wait(pick, 10, "friend")
        pick.tap()
        let add = app.buttons["pix.space.add"]
        wait(add, 15, "space")
        shot("space-empty")

        // Library: the photo and the big video.
        add.tap()
        wait(app.buttons["pix.add.library"], 5, "library-button")
        app.buttons["pix.add.library"].tap()
        // The picker loads the library the first time: wait for its cells.
        let anyCell = app.images.matching(NSPredicate(format: "label BEGINSWITH[c] 'Photo' OR label BEGINSWITH[c] 'Video'")).firstMatch
        if !anyCell.waitForExistence(timeout: 45) { dump("picker"); shot("picker") }
        sleep(1)
        shot("picker")
        // The media script added: today's photo, and the 8-second 4K video.
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo, ' AND label CONTAINS %@",
                                                    Date.now.formatted(.dateTime.month(.wide).day()))).firstMatch
        let video = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Video, eight seconds'")).firstMatch
        wait(photo, 5, "picker-photo")
        wait(video, 5, "picker-video")
        // A picker cell can report "not hittable" under the onboarding banner
        // at large text sizes: tap its centre.
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let done = app.buttons.matching(NSPredicate(format: "label == 'Done' AND isEnabled == true")).firstMatch
        wait(done, 5, "picker-done")
        done.tap()

        // The sheet prepares the video, queues both and closes; the grid
        // shows both once they've gone up.
        let items = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pix.item.'"))
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline, items.count < 2 { sleep(2) }
        shot("grid")
        XCTAssertEqual(items.count, 2, "items in the grid")
        XCTAssertFalse(app.descendants(matching: .any)["pix.add.problem"].exists)

        // The video plays (muted first).
        let v = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Video'")).firstMatch
        wait(v, 5, "video-tile")
        v.tap()
        wait(app.buttons["pix.video.mute"], 15, "video-mute")
        XCTAssertFalse(app.staticTexts["Can't play this video"].exists)
        shot("viewer-video")
        app.buttons["pix.viewer.close"].tap()

        // Delete the photo (ours), confirm, and the grid has one left.
        let p = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Photo'")).firstMatch
        wait(p, 5, "photo-tile")
        p.tap()
        wait(app.buttons["pix.viewer.delete"], 10, "delete")
        shot("viewer-photo")
        app.buttons["pix.viewer.delete"].tap()
        // The dialog's Delete, not the toolbar's (same label).
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Delete' AND identifier != 'pix.viewer.delete'")).firstMatch
        wait(confirm, 5, "confirm")
        confirm.tap()
        let gone = Date().addingTimeInterval(15)
        while Date() < gone, items.count != 1 { usleep(300_000) }
        if app.buttons["pix.viewer.close"].exists { app.buttons["pix.viewer.close"].tap() }
        XCTAssertEqual(items.count, 1, "after delete")

        // An audio clip: record two seconds and add it (the script grants the
        // microphone first, so no prompt).
        app.buttons["pix.space.add"].tap()
        wait(app.buttons["pix.add.clipRecord"], 5, "clip-record")
        app.buttons["pix.add.clipRecord"].tap()
        wait(app.buttons["pix.add.clipStop"], 5, "clip-stop")
        sleep(2)
        shot("recording")
        app.buttons["pix.add.clipStop"].tap()
        let clipTile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Voice clip'")).firstMatch
        wait(clipTile, 30, "clip-tile")
        XCTAssertEqual(items.count, 2, "photo deleted, video and clip left")
        clipTile.tap()
        wait(app.buttons["pix.audio.play"], 10, "clip-play")
        shot("viewer-clip")
        app.buttons["pix.viewer.close"].tap()

        // Sign out: nothing of the kit's is left on the device.
        app.tabBars.buttons["Settings"].tap()
        let files = app.buttons["lab.kitFiles"]
        wait(files, 10, "kit-files")
        files.tap()
        sleep(1)
        XCTAssertNotEqual(files.value as? String, "0", "the kit kept nothing while signed in?")
        app.buttons["Sign out"].tap()
        let empty = Date().addingTimeInterval(10)
        while Date() < empty, (files.value as? String) != "0" { usleep(300_000); if (files.value as? String) != "0" { files.tap() } }
        shot("signed-out")
        XCTAssertEqual(files.value as? String, "0", "kit files after sign-out")
    }
}
