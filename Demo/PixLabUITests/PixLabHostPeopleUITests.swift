import XCTest

/// The "Host people" knob (MVCALE-123): the host's name and photo win in the
/// spaces list, a rename redraws the open screen, and off falls back to
/// mvPix's own. Read-only: it never writes to mvPix. Run by
/// ../scripts/ui-test.sh with a test account that has at least one space.
final class PixLabHostPeopleUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["PIX_DEV_TOKEN"], let user = env["PIX_DEV_USER"] else {
            throw XCTSkip("run through scripts/ui-test.sh")
        }
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment = ["PIX_DEV_TOKEN": token, "PIX_DEV_USER": user]
        app.launch()
    }

    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func waitLabel(_ e: XCUIElement, _ test: @escaping (String) -> Bool, _ what: String) {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !test(e.label) { usleep(200_000) }
        XCTAssert(test(e.label), "\(what): the title reads \"\(e.label)\"")
    }

    func testTheHostWinsARenameIsLiveAndOffFallsBack() throws {
        XCTAssert(app.navigationBars["Spaces"].waitForExistence(timeout: 15))
        let title = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'pix.space.title.'")).firstMatch
        guard title.waitForExistence(timeout: 15) else { throw XCTSkip("this account has no space to show") }
        let before = title.label
        XCTAssertFalse(before.hasPrefix("Host friend"))
        shot("host-off")

        let knob = app.switches["lab.hostPeople"]
        XCTAssert(knob.waitForExistence(timeout: 5))
        knob.switches.firstMatch.tap()
        waitLabel(title, { $0.hasPrefix("Host friend") }, "host on")
        XCTAssert(app.descendants(matching: .any)["lab.hostAvatar"].firstMatch.waitForExistence(timeout: 5), "the host's photo shows")
        let hosted = title.label
        shot("host-on")

        app.buttons["lab.hostRename"].tap()
        waitLabel(title, { $0 == hosted + " · 1" }, "after a rename, on the open screen")
        shot("host-renamed")

        knob.switches.firstMatch.tap()
        waitLabel(title, { $0 == before }, "host off")
        XCTAssertFalse(app.descendants(matching: .any)["lab.hostAvatar"].firstMatch.exists, "the host's photo went with it")
        shot("host-off-again")
    }
}
