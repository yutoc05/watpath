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
        app.launchArguments = ["-resetRecents"]
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

    @MainActor
    func testPathMapIsFlatButCardsKeepEveryFloor() {
        launch()
        search(for: "mc")
        tapResult(beginningWith: "Mathematics & Computer")
        _ = cardTitle()
        // The card lists every floor MC has...
        XCTAssertTrue(app.staticTexts["Basement, 1–6, Penthouse"].waitForExistence(timeout: 2))
        saveScreenshot("path-card-street")
        app.segmentedControls.buttons["Path"].tap()
        XCTAssertTrue(pathLabel().waitForExistence(timeout: 3))
        sleep(1)
        // ...and still does in Path mode, where the map has no floors to pick.
        XCTAssertTrue(app.staticTexts["Basement, 1–6, Penthouse"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'MC floor'")).firstMatch.exists, "no floor picker")
        saveScreenshot("path-selected")
    }

    @MainActor
    func testBridgesAndTunnelsShowTheirFloorsAtEachEnd() {
        launch()
        showMCInPathMode()
        // The MC–C2 tunnel: MC floor 1 at one end, C2's basement at the other.
        let mc = app.staticTexts["floorBadge-conn-w183247348-0"]
        let c2 = app.staticTexts["floorBadge-conn-w183247348-1"]
        XCTAssertTrue(mc.waitForExistence(timeout: 2))
        XCTAssertEqual(mc.label, "MC floor 1")
        XCTAssertEqual(c2.label, "C2 floor B")
        saveScreenshot("path-mode")
    }

    @MainActor
    func testDraggingFromADoorMarkerStillMovesThePathMap() {
        launch()
        showMCInPathMode()
        let door = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'door-MC-'")).firstMatch
        XCTAssertTrue(door.waitForExistence(timeout: 2), "MC's doors should show in Path mode")
        let label = pathLabel()
        let before = label.frame
        let start = door.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -120, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertLessThan(label.frame.midX - before.midX, -80, "the map should follow a drag that starts on a door")

        // A plain tap on a door still selects it.
        let tapped = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'door-MC-'")).firstMatch
        let name = tapped.label
        // Markers don't take touches themselves (the map does), so tap the spot rather than the element.
        tapped.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(cardTitle(), name)
    }

    @MainActor
    func testPathMapStopsWhenTheFingerLiftsButStreetMapGlides() {
        launch()
        showMCInPathMode()
        let travel = 140.0
        let pathMoved = horizontalShiftAfterFling(of: pathLabel(), travel: travel)
        XCTAssertEqual(pathMoved, -travel, accuracy: 25, "Path mode should stop where the finger lifts")

        app.segmentedControls.buttons["Street"].tap()
        let door = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'door-'")).firstMatch
        XCTAssertTrue(door.waitForExistence(timeout: 2))
        let streetMoved = horizontalShiftAfterFling(of: door, travel: travel)
        XCTAssertLessThan(streetMoved, -travel - 40, "Street mode should keep MapKit's glide")
    }

    @MainActor
    func testChoosingALocationInsideThePathDropsAPin() {
        launch()
        app.buttons["Search"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Choose location inside the path")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Choose location inside the path"].waitForExistence(timeout: 2))
        sleep(2)  // let the pin snap into a building
        saveScreenshot("choose-inside-path")
        app.buttons["Set Location"].tap()
        XCTAssertEqual(cardTitle(), "Dropped Pin")
    }

    // MARK: Helpers

    /// Selects MC (which frames it close enough for doors), closes its card and
    /// switches to the Path Map.
    @MainActor
    private func showMCInPathMode() {
        search(for: "mc")
        tapResult(beginningWith: "Mathematics & Computer")
        _ = cardTitle()
        app.buttons["Close"].tap()
        app.segmentedControls.buttons["Path"].tap()
        XCTAssertTrue(pathLabel().waitForExistence(timeout: 3))
        sleep(1)  // let the cross-fade finish
    }

    @MainActor
    private func pathLabel() -> XCUIElement {
        app.staticTexts["pathLabel-MC"]
    }

    /// Flings the map left from the middle of the screen and reports how far
    /// `element` ended up moving, in points, once everything settled.
    @MainActor
    private func horizontalShiftAfterFling(of element: XCUIElement, travel: Double) -> Double {
        let identifier = element.identifier
        let before = element.frame.midX
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -travel, dy: 0)), withVelocity: .fast, thenHoldForDuration: 0)
        sleep(2)
        let after = app.descendants(matching: .any)[identifier]
        guard after.exists else { return -.infinity }  // glided clean off screen
        return after.frame.midX - before
    }

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
    private func assertSwipingDownLeavesTheCardOpen(titled title: String) {
        // A real drag, from the card's top to the bottom of the screen: a plain swipe on
        // the title scrolls the card's contents and leaves the card alone.
        for _ in 0..<2 {
            let grabber = app.staticTexts["placeTitle"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            grabber.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1)), withVelocity: .fast, thenHoldForDuration: 0)
            sleep(1)
        }
        XCTAssertEqual(cardTitle(), title)
    }

    @MainActor
    func testSwipingDownNeverClosesACard() {
        launch()
        search(for: "mc")
        tapResult(beginningWith: "Mathematics & Computer")
        assertSwipingDownLeavesTheCardOpen(titled: "Mathematics & Computer")

        let door = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "North entrance")).firstMatch
        XCTAssertTrue(door.waitForExistence(timeout: 3))
        door.tap()
        // From the card's smallest size, scrolling the row into view can use up the tap.
        if cardTitle() != "North entrance" { door.tap() }
        assertSwipingDownLeavesTheCardOpen(titled: "North entrance")

        app.buttons["Close"].tap()
        XCTAssertFalse(app.staticTexts["placeTitle"].waitForExistence(timeout: 1))

        app.buttons["Search"].tap()
        let chooseOnMap = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Choose location on map")).firstMatch
        XCTAssertTrue(chooseOnMap.waitForExistence(timeout: 3))
        chooseOnMap.tap()
        XCTAssertTrue(app.buttons["Set Location"].waitForExistence(timeout: 3))
        sleep(1)
        app.buttons["Set Location"].tap()
        assertSwipingDownLeavesTheCardOpen(titled: "Dropped Pin")

        app.buttons["Close"].tap()
        XCTAssertFalse(app.staticTexts["placeTitle"].waitForExistence(timeout: 1))
    }

    /// Needs Apple's search to answer, so it steps aside when there's no network.
    @MainActor
    func testSwipingDownDoesntCloseAnAppleMapsPlaceCard() throws {
        launch()
        search(for: "tim hortons")
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Tim Hortons")).firstMatch
        try XCTSkipUnless(result.waitForExistence(timeout: 10), "Apple's search didn't answer")
        result.tap()
        let title = cardTitle()
        assertSwipingDownLeavesTheCardOpen(titled: title)
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
