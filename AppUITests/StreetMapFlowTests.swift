import XCTest

/// End-to-end Street Map flows, driven through the real UI. Set
/// TEST_RUNNER_SCREENSHOT_DIR when running xcodebuild to also save screenshots.
final class StreetMapFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch() {
        app = XCUIApplication()
        app.launch()
        dismissLocationPromptIfShown()
    }

    @MainActor
    func testSearchingACodeOpensTheBuildingCard() {
        launch()
        search(for: "mc")
        tapResult(beginningWith: "Mathematics & Computer")
        XCTAssertEqual(cardTitle(), "Mathematics & Computer")
        XCTAssertTrue(app.staticTexts["Entrances (8)"].waitForExistence(timeout: 2))
        saveScreenshot("building-card")
    }

    @MainActor
    func testTyposStillFindTheBuilding() {
        launch()
        search(for: "libary")
        tapResult(beginningWith: "Dana Porter Library")
        XCTAssertEqual(cardTitle(), "Dana Porter Library")
    }

    @MainActor
    func testBuildingCardLeadsToADoorCard() {
        launch()
        search(for: "mc")
        tapResult(beginningWith: "Mathematics & Computer")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "North entrance")).firstMatch.tap()
        XCTAssertEqual(cardTitle(), "North entrance")
        XCTAssertTrue(app.staticTexts["No photos yet"].waitForExistence(timeout: 2))
        saveScreenshot("door-card")
    }

    @MainActor
    func testSelectedPlacesAppearInRecents() {
        launch()
        search(for: "davis")
        tapResult(beginningWith: "William G. Davis Computer Research Centre")
        _ = cardTitle()
        app.buttons["Close"].tap()
        app.buttons["Search"].tap()
        XCTAssertTrue(app.staticTexts["Recents"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "William G. Davis")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Popular Locations"].exists)
        saveScreenshot("search-empty")
    }

    @MainActor
    func testChoosingALocationOnTheMapDropsAPin() {
        launch()
        app.buttons["Search"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Choose location on map")).firstMatch.tap()
        let coordinate = app.staticTexts["pickerCoordinate"]
        XCTAssertTrue(coordinate.waitForExistence(timeout: 2))
        let before = coordinate.label
        app.swipeLeft()
        XCTAssertNotEqual(coordinate.label, before, "coordinates should follow the map")
        saveScreenshot("choose-on-map")
        app.buttons["Set Location"].tap()
        XCTAssertEqual(cardTitle(), "Dropped Pin")
    }

    // MARK: Helpers

    @MainActor
    private func search(for text: String) {
        app.buttons["Search"].tap()
        let field = app.textFields["searchText"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.typeText(text)
    }

    @MainActor
    private func tapResult(beginningWith title: String) {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3), "no result \(title)")
        row.tap()
    }

    @MainActor
    private func cardTitle() -> String {
        let title = app.staticTexts["placeTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 3), "place card didn't open")
        return title.label
    }

    @MainActor
    private func dismissLocationPromptIfShown() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    @MainActor
    private func saveScreenshot(_ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] else { return }
        sleep(1)  // let sheet and camera animations settle
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }
}
