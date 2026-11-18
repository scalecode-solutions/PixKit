import XCTest

/// Drives PixLab like a person, against the LOCAL mvPix, signed in through the
/// debug dev sign-in. Run by ../scripts/ui-test.sh (it mints the token).
final class PixLabShellUITests: XCTestCase {
    var app: XCUIApplication!
    var user = ""

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["PIX_DEV_TOKEN"], let user = env["PIX_DEV_USER"] else {
            throw XCTSkip("run through scripts/ui-test.sh")
        }
        self.user = user
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

    /// Signed in with the dev token, the server knows who we are.
    func testTheTokenIsAccepted() {
        app.tabBars.buttons["Settings"].tap()
        let who = app.descendants(matching: .any)["lab.whoAmI"]
        XCTAssert(who.waitForExistence(timeout: 10))
        let user = user
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !((who.label + (who.value as? String ?? "")).contains(user)) { usleep(200_000) }
        XCTAssert((who.label + (who.value as? String ?? "")).contains(user), "WhoAmI shows \(who.label) \(String(describing: who.value))")
        shot("settings")
    }

    /// The spaces list loads without an error, and + offers the friends.
    func testSpacesAndTheFriendPicker() {
        XCTAssert(app.navigationBars["Spaces"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["lab.error"].waitForExistence(timeout: 3))
        shot("spaces")
        app.buttons["lab.newSpace"].tap()
        XCTAssert(app.navigationBars["Share with"].waitForExistence(timeout: 5))
        shot("friends")
    }
}
