import CoreLocation
import XCTest

/// Getting directions, driven through the real UI. Set TEST_RUNNER_SCREENSHOT_DIR
/// when running xcodebuild to also save screenshots.
final class DirectionsFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// How each flow ended, which is the first thing to see when one fails.
    @MainActor
    override func tearDown() async throws {
        if app != nil { save("end-\(name.replacingOccurrences(of: " ", with: "-"))") }
        try await super.tearDown()
    }

    /// `location` is where the simulated phone is, if anywhere.
    @MainActor
    private func launch(at location: CLLocation? = nil) {
        // Off campus unless a test says otherwise: a simulated location outlives the test that set it.
        XCUIDevice.shared.location = XCUILocation(location: location ?? CLLocation(latitude: 43.6426, longitude: -79.3871))
        app = XCUIApplication()
        app.launchArguments = ["-resetRecents"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    /// The pin's coordinate, as the picker shows it.
    @MainActor
    private func pinned() -> (latitude: Double, longitude: Double) {
        let parts = app.staticTexts["pickerCoordinate"].label.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        XCTAssertEqual(parts.count, 2)
        return (parts[0], parts[1])
    }

    @MainActor
    private func openBuilding(_ query: String, named name: String) {
        app.buttons["Search"].tap()
        let field = app.textFields["searchText"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(query)
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()
        XCTAssertTrue(app.buttons["directionsButton"].waitForExistence(timeout: 5))
    }

    /// Starting from `from`, picked in the search.
    @MainActor
    private func startOutside(from query: String, named name: String) {
        tap("outsideButton")
        let field = app.textFields["searchText"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(query)
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()
    }

    @MainActor
    private func tap(_ identifier: String) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(identifier) never appeared")
        button.tap()
    }

    @MainActor
    private func save(_ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: url)
    }

    @MainActor
    func testEveryPlaceCardOffersDirections() {
        launch()
        openBuilding("dana", named: "Dana Porter Library")
        save("place-card-directions")
        tap("directionsButton")
        XCTAssertTrue(app.buttons["inThePathButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["outsideButton"].exists)
        XCTAssertEqual(app.staticTexts["directionsTitle"].label, "To Dana Porter Library")
        save("origin-prompt")
    }

    @MainActor
    func testOutsideRouteListShowsChoicesWithTheirNumbers() {
        launch()
        openBuilding("davis", named: "William G. Davis Computer Research Centre")
        tap("directionsButton")
        startOutside(from: "mc", named: "Mathematics & Computer")

        let fastest = app.buttons["route-0"]
        XCTAssertTrue(fastest.waitForExistence(timeout: 5))
        XCTAssertTrue(fastest.label.hasPrefix("Fastest,"), fastest.label)
        let indoor = app.buttons["route-1"]
        XCTAssertTrue(indoor.exists)
        XCTAssertTrue(indoor.label.hasPrefix("Most indoor,"), indoor.label)
        XCTAssertTrue(indoor.label.hasSuffix("100% inside"), indoor.label)
        XCTAssertEqual(app.staticTexts["directionsSubtitle"].label, "From Mathematics & Computer")
        saveAfterTheMapSettles("routes-street")

        indoor.tap()
        XCTAssertTrue(app.buttons["route-1"].isSelected)
        saveAfterTheMapSettles("routes-second-selected")

        app.segmentedControls["mapModePicker"].buttons["Path"].tap()
        saveAfterTheMapSettles("routes-path")
    }

    @MainActor
    func testInThePathGoesThroughThePin() {
        launch()
        openBuilding("slc", named: "Student Life Centre")
        tap("directionsButton")
        tap("inThePathButton")
        XCTAssertTrue(app.staticTexts["Where are you?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["pickerCoordinate"].waitForExistence(timeout: 5))
        saveAfterTheMapSettles("origin-pin")
        app.buttons["Set Location"].tap()
        XCTAssertTrue(app.buttons["route-0"].waitForExistence(timeout: 5))
        saveAfterTheMapSettles("routes-from-pin")
    }

    @MainActor
    func testThePinSlidesOutOfTheBlackToSomewhereWalkable() {
        launch()
        openBuilding("slc", named: "Student Life Centre")
        tap("directionsButton")
        tap("inThePathButton")
        XCTAssertTrue(app.staticTexts["pickerCoordinate"].waitForExistence(timeout: 5))
        sleep(2)
        // The ground south of SLC is empty, so drag the map up until the pin is over it,
        // past 43.4710. Left there it would stay; SLC's lines end north of 43.4712.
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        from.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        sleep(2)
        XCTAssertGreaterThan(pinned().latitude, 43.4712, "the pin stayed in the black")
        saveAfterTheMapSettles("origin-pin-snapped")
        app.buttons["Set Location"].tap()
        XCTAssertTrue(app.buttons["route-0"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testTheStartCanBeChosenOnTheMap() {
        launch()
        openBuilding("slc", named: "Student Life Centre")
        tap("directionsButton")
        tap("outsideButton")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Choose location on map")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.staticTexts["Where are you?"].waitForExistence(timeout: 5))
        sleep(1)
        app.buttons["Set Location"].tap()
        XCTAssertTrue(app.buttons["route-0"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["directionsSubtitle"].label, "From Dropped Pin")
    }

    @MainActor
    func testCurrentLocationIsAStart() {
        launch(at: CLLocation(latitude: 43.4695, longitude: -80.5445))  // outside, south of QNC
        openBuilding("davis", named: "William G. Davis Computer Research Centre")
        tap("directionsButton")
        tap("outsideButton")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Current Location")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.isEnabled)
        row.tap()
        XCTAssertTrue(app.buttons["route-0"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["directionsSubtitle"].label, "From Current Location")
        saveAfterTheMapSettles("routes-from-current-location")
    }

    @MainActor
    func testInThePathStartsWhereYouAreIfThatsInABuilding() {
        launch(at: CLLocation(latitude: 43.47216, longitude: -80.54396))  // inside MC
        openBuilding("slc", named: "Student Life Centre")
        tap("directionsButton")
        tap("inThePathButton")
        XCTAssertTrue(app.staticTexts["pickerCoordinate"].waitForExistence(timeout: 5))
        sleep(3)
        let pin = pinned()
        XCTAssertEqual(pin.latitude, 43.47216, accuracy: 0.0002)
        XCTAssertEqual(pin.longitude, -80.54396, accuracy: 0.0002)
    }

    @MainActor
    func testAPlaceTooFarFromCampusHasNoRoute() {
        launch()
        openBuilding("slc", named: "Student Life Centre")
        tap("directionsButton")
        tap("outsideButton")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Current Location")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.staticTexts["noRoutesMessage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["noRoutesMessage"].label.hasPrefix("That's too far"))
        app.buttons["Choose Another Start"].tap()
        XCTAssertTrue(app.buttons["outsideButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testTheToggleTakesTheSearchBarsPlaceThroughoutDirections() {
        launch()
        let toggle = app.segmentedControls["mapModePicker"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let usual = toggle.frame
        let searchBar = app.buttons["Search"].frame
        XCTAssertGreaterThan(usual.minY, searchBar.maxY)

        openBuilding("davis", named: "William G. Davis Computer Research Centre")
        tap("directionsButton")
        XCTAssertTrue(app.buttons["outsideButton"].waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertEqual(toggle.frame.midY, searchBar.midY, accuracy: 1)

        startOutside(from: "mc", named: "Mathematics & Computer")
        XCTAssertTrue(app.buttons["route-0"].waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertEqual(toggle.frame.midY, searchBar.midY, accuracy: 1)
        saveAfterTheMapSettles("toggle-over-routes")

        // Changing the start is still directions, so it stays up there.
        app.buttons["Change Start"].tap()
        XCTAssertTrue(app.buttons["outsideButton"].waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertEqual(toggle.frame.midY, searchBar.midY, accuracy: 1)

        // Closing directions brings the search bar back, with the toggle below it.
        app.buttons["Close Directions"].tap()
        XCTAssertTrue(app.buttons["directionsButton"].waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertEqual(toggle.frame.minY, usual.minY, accuracy: 1)
    }

    @MainActor
    func testRoutesScrollInsideTheCard() {
        launch()
        openBuilding("e5", named: "Engineering 5")
        tap("directionsButton")
        startOutside(from: "slc", named: "Student Life Centre")
        let last = app.buttons["route-3"]
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        sleep(1)
        let title = app.staticTexts["directionsTitle"]
        let cardTop = title.frame.minY
        let before = last.frame.minY
        app.buttons["route-1"].swipeUp()
        sleep(1)
        XCTAssertEqual(title.frame.minY, cardTop, accuracy: 1, "the card moved instead of its routes")
        XCTAssertLessThan(last.frame.minY, before, "the routes didn't scroll")
        save("routes-scrolled")

        // The header still resizes the card, but dragging it down never closes it.
        for _ in 0..<2 {
            let header = title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            header.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1)), withVelocity: .fast, thenHoldForDuration: 0)
            sleep(1)
        }
        XCTAssertTrue(title.exists, "dragging closed the card")
        XCTAssertGreaterThan(title.frame.minY, cardTop, "the card didn't shrink")
        save("routes-smallest")
    }

    @MainActor
    func testGoingBackAndOut() {
        launch()
        openBuilding("slc", named: "Student Life Centre")
        tap("directionsButton")
        tap("outsideButton")
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["outsideButton"].waitForExistence(timeout: 5))
        app.buttons["Close Directions"].tap()
        // Back at the place card, with the place still selected.
        XCTAssertTrue(app.buttons["directionsButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testTheSamePlaceTwiceHasNoRoute() {
        launch()
        openBuilding("mc", named: "Mathematics & Computer")
        tap("directionsButton")
        startOutside(from: "mc", named: "Mathematics & Computer")
        XCTAssertTrue(app.staticTexts["noRoutesMessage"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["noRoutesMessage"].label, "You're already there.")
    }

    @MainActor
    func testTappingTheMapDoesntChangeTheDestination() {
        launch()
        openBuilding("davis", named: "William G. Davis Computer Research Centre")
        tap("directionsButton")
        startOutside(from: "mc", named: "Mathematics & Computer")
        XCTAssertTrue(app.buttons["route-0"].waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        sleep(1)
        XCTAssertTrue(app.buttons["route-0"].exists)
        XCTAssertEqual(app.staticTexts["directionsTitle"].label, "To William G. Davis Computer Research Centre")
    }

    @MainActor
    private func saveAfterTheMapSettles(_ name: String) {
        sleep(2)
        save(name)
    }
}
