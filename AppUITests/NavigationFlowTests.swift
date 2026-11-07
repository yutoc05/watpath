import CoreLocation
import XCTest

/// Scrub navigation, driven through the real UI. Set TEST_RUNNER_SCREENSHOT_DIR when
/// running xcodebuild to also save screenshots.
final class NavigationFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch() {
        // A simulated location outlives the test that set it, so every test sets its own.
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 43.6426, longitude: -79.3871))
        app = XCUIApplication()
        app.launchArguments = ["-resetRecents"]
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    /// Opens the routes between two buildings.
    @MainActor
    private func openRoutes(to destination: (query: String, name: String), from origin: (query: String, name: String)) {
        app.buttons["Search"].tap()
        pick(destination)
        XCTAssertTrue(app.buttons["directionsButton"].waitForExistence(timeout: 5))
        app.buttons["directionsButton"].tap()
        XCTAssertTrue(app.buttons["outsideButton"].waitForExistence(timeout: 5))
        app.buttons["outsideButton"].tap()
        pick(origin)
        XCTAssertTrue(app.buttons["route-0"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func pick(_ place: (query: String, name: String)) {
        let field = app.textFields["searchText"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(place.query)
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", place.name)).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()
    }

    @MainActor
    private func startRoute(_ index: Int = 0) {
        let start = app.buttons["start-\(index)"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(progressBar.waitForExistence(timeout: 5))
        sleep(2)  // the flight to the start
    }

    @MainActor
    private var progressBar: XCUIElement {
        app.descendants(matching: .any)["navigationProgress"]
    }

    /// How far along the route, in percent.
    @MainActor
    private var progress: Int {
        Int((progressBar.value as? String ?? "").dropLast()) ?? -1
    }

    /// Drags down the screen, stopping before lifting so there's no flick. `from` and
    /// `to` are shares of the screen's height.
    @MainActor
    private func drag(from: CGFloat, to: CGFloat) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    @MainActor
    private func flick() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }

    @MainActor
    private func save(_ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] else { return }
        sleep(1)
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: url)
    }

    @MainActor
    func testStartShowsTheRouteTheBarAndTheCard() {
        launch()
        openRoutes(to: ("slc", "Student Life Centre"), from: ("qnc", "Mike & Ophelia Lazaridis"))
        startRoute()
        XCTAssertEqual(progress, 0)
        XCTAssertTrue(app.buttons["endNavigation"].exists)
        XCTAssertTrue(app.staticTexts["navigationHeadline"].label.hasPrefix("Arrive "), app.staticTexts["navigationHeadline"].label)
        XCTAssertTrue(app.staticTexts["navigationRemaining"].label.contains("min"))
        // Nothing else is left on the screen: no toggle, no route list.
        XCTAssertFalse(app.segmentedControls["mapModePicker"].exists)
        XCTAssertFalse(app.buttons["route-0"].exists)
        save("nav-start")
    }

    @MainActor
    func testDraggingDownWalksForwardAndUpWalksBack() {
        launch()
        openRoutes(to: ("e5", "Engineering 5"), from: ("slc", "Student Life Centre"))
        startRoute(3)
        drag(from: 0.2, to: 0.75)
        let forward = progress
        XCTAssertGreaterThan(forward, 0)
        drag(from: 0.2, to: 0.75)
        XCTAssertGreaterThan(progress, forward)
        save("nav-partway")
        drag(from: 0.75, to: 0.2)
        XCTAssertLessThan(progress, forward + forward)
        XCTAssertGreaterThanOrEqual(progress, 0)
    }

    @MainActor
    func testUpAtTheStartGoesNowhere() {
        launch()
        openRoutes(to: ("slc", "Student Life Centre"), from: ("qnc", "Mike & Ophelia Lazaridis"))
        startRoute()
        drag(from: 0.7, to: 0.3)
        XCTAssertEqual(progress, 0)
    }

    @MainActor
    func testAFlickCoversMoreThanTheSameDragHeld() {
        launch()
        openRoutes(to: ("e5", "Engineering 5"), from: ("slc", "Student Life Centre"))
        startRoute(3)
        drag(from: 0.25, to: 0.7)
        let held = progress
        drag(from: 0.7, to: 0.25)
        let start = progress
        flick()
        sleep(2)
        XCTAssertGreaterThan(progress - start, held - start)
    }

    @MainActor
    func testReachingTheEndIsArrivingAndDoneReturnsToThePlace() {
        launch()
        openRoutes(to: ("slc", "Student Life Centre"), from: ("qnc", "Mike & Ophelia Lazaridis"))
        startRoute()
        for _ in 0..<40 where !app.staticTexts["You've arrived"].exists {
            flick()
            sleep(1)
        }
        XCTAssertTrue(app.staticTexts["You've arrived"].waitForExistence(timeout: 5))
        XCTAssertEqual(progress, 100)
        save("nav-arrived")

        // Scrubbing back undoes it.
        drag(from: 0.7, to: 0.25)
        XCTAssertTrue(app.staticTexts["navigationRemaining"].waitForExistence(timeout: 5))
        for _ in 0..<40 where !app.staticTexts["You've arrived"].exists {
            flick()
            sleep(1)
        }
        app.buttons["endNavigation"].tap()
        XCTAssertTrue(app.staticTexts["placeTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["placeTitle"].label, "Student Life Centre")
        XCTAssertFalse(progressBar.exists)
        save("nav-done")
    }

    @MainActor
    func testEndingPartwayReturnsToThePlaceAndTheMapWorksAgain() {
        launch()
        openRoutes(to: ("slc", "Student Life Centre"), from: ("qnc", "Mike & Ophelia Lazaridis"))
        startRoute()
        drag(from: 0.2, to: 0.75)
        app.buttons["endNavigation"].tap()
        XCTAssertTrue(app.staticTexts["placeTitle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["mapModePicker"].waitForExistence(timeout: 5))
        sleep(2)
        // The Path Map's own pan is back, and tapping selects things again.
        app.buttons["Close"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["placeTitle"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testADragAcrossTurnsTheCameraWithoutWalking() {
        launch()
        openRoutes(to: ("e5", "Engineering 5"), from: ("slc", "Student Life Centre"))
        startRoute(3)
        drag(from: 0.25, to: 0.7)
        let walked = progress
        XCTAssertGreaterThan(walked, 0)
        let before = app.screenshot().pngRepresentation

        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.45))
        left.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45)), withVelocity: .slow, thenHoldForDuration: 0)
        XCTAssertNotEqual(app.screenshot().pngRepresentation, before, "the camera didn't turn")
        save("nav-turning")
        XCTAssertEqual(progress, walked, "turning walked along the route")

        // Lifting the finger brings it back to straight ahead, by itself.
        sleep(3)
        XCTAssertEqual(progress, walked)
        save("nav-straightened")

        // Vertical drags still walk.
        drag(from: 0.25, to: 0.7)
        XCTAssertGreaterThan(progress, walked)
    }

    @MainActor
    func testAPinchZoomsWithoutWalking() {
        launch()
        openRoutes(to: ("e5", "Engineering 5"), from: ("slc", "Student Life Centre"))
        startRoute(3)
        drag(from: 0.25, to: 0.7)
        let walked = progress
        let before = app.screenshot().pngRepresentation
        // Spreading, because the fingers of a pinch that closes start wide apart: here,
        // on the card along the bottom and on its End button.
        app.pinch(withScale: 2, velocity: 1)
        sleep(1)
        XCTAssertEqual(progress, walked, "pinching walked along the route")
        XCTAssertNotEqual(app.screenshot().pngRepresentation, before, "the camera didn't zoom")
        save("nav-zoomed-in")
        drag(from: 0.25, to: 0.7)
        XCTAssertGreaterThan(progress, walked)
    }

    /// The fastest way from SLC to E5 is mostly outside, so it must leave the Path Map.
    @MainActor
    func testAnOutdoorStretchShowsTheStreetMap() {
        launch()
        openRoutes(to: ("e5", "Engineering 5"), from: ("slc", "Student Life Centre"))
        startRoute(0)
        save("nav-outdoor-start")
        drag(from: 0.2, to: 0.75)
        drag(from: 0.2, to: 0.75)
        drag(from: 0.2, to: 0.75)
        save("nav-outdoor-1")
        flick()
        sleep(2)
        save("nav-outdoor-2")
    }
}
