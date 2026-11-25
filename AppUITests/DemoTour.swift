import CoreLocation
import XCTest

/// The walkthroughs in the demo video and the README's feature clips, played by
/// `tools/demo/record.py` while the Simulator records. They aren't checks of anything: they
/// run only when DEMO_DIR is set (pass TEST_RUNNER_DEMO_DIR to xcodebuild), and they pause so
/// people can follow along. Each writes when its scenes start to DEMO_DIR, in scenes.json for
/// the tour and features.json for the clips, which the video and the clips are cut on.
final class DemoTour: XCTestCase {
    private var app: XCUIApplication!
    private var directory: URL!
    private var scenesFile = "scenes.json"
    private var scenes: [[String: Any]] = []

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["DEMO_DIR"] else {
            throw XCTSkip("Only plays when recording the demo video")
        }
        directory = URL(fileURLWithPath: path)
        continueAfterFailure = false
    }

    @MainActor
    func testTour() throws {
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 43.6426, longitude: -79.3871))
        app = XCUIApplication()
        app.launchArguments = ["-resetRecents", "-showTouches"]
        app.launch()
        XCTAssertTrue(app.buttons["Search"].waitForExistence(timeout: 10))
        pause(3)

        mark("street")
        pause(1.5)

        mark("search")
        app.buttons["Search"].tap()
        pause(0.8)
        type("mc")
        pause(1)
        choose("Mathematics & Computer")
        XCTAssertTrue(app.staticTexts["placeTitle"].waitForExistence(timeout: 5))
        mark("card")
        pause(3.5)
        app.buttons["Close"].tap()
        pause(1)

        mark("pathMap")
        app.segmentedControls["mapModePicker"].buttons["Path"].tap()
        pause(2)
        slowDrag(from: CGVector(dx: 0.5, dy: 0.32), to: CGVector(dx: 0.35, dy: 0.42))
        pause(1)
        app.pinch(withScale: 0.55, velocity: -0.6)
        pause(2.5)

        mark("directions")
        app.buttons["Search"].tap()
        pause(0.8)
        type("dc")
        pause(1)
        choose("William G. Davis")
        tap("directionsButton")
        pause(1.5)
        tap("inThePathButton")
        XCTAssertTrue(app.staticTexts["pickerCoordinate"].waitForExistence(timeout: 5))
        pause(1.5)
        let drag = pinDrag()
        slowDrag(from: drag.from, to: drag.to)
        pause(2)
        mark("pinPlaced")
        app.buttons["Set Location"].tap()
        XCTAssertTrue(app.buttons["route-0"].waitForExistence(timeout: 5))
        mark("routes")
        pause(2.5)
        // The route that stays inside, when there's a choice.
        let mostIndoor = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'route-' AND label CONTAINS 'Most indoor'")).firstMatch
        let indoor = mostIndoor.exists ? mostIndoor : app.buttons["route-0"]
        indoor.tap()
        pause(2.5)

        mark("navigation")
        let index = indoor.identifier.dropFirst("route-".count)
        tap("start-\(index)")
        XCTAssertTrue(app.descendants(matching: .any)["navigationProgress"].waitForExistence(timeout: 5))
        pause(2.2)
        // A short walk, a look around and a closer view, then on to the end.
        walk(from: 0.3, to: 0.58)
        pause(0.8)
        slowDrag(from: CGVector(dx: 0.82, dy: 0.42), to: CGVector(dx: 0.25, dy: 0.42))
        pause(2.2)
        app.pinch(withScale: 1.6, velocity: 0.8)
        pause(1.2)
        walk(from: 0.22, to: 0.62)
        pause(0.8)
        let arrived = app.staticTexts["You've arrived"]
        for _ in 0..<12 {
            flick()
            if arrived.waitForExistence(timeout: 2.5) { break }
        }
        XCTAssertTrue(arrived.exists)
        mark("arrived")
        pause(2.5)
        // Waiting for the app to settle can hold this tap for a while; the video cuts the wait.
        app.buttons["endNavigation"].tap()
        mark("done")
        pause(2.5)
        mark("end")
    }

    /// The README's feature clips, one after another: the x-ray switch in 3D, a search with a
    /// typo, the four routes from SLC to E5, and walking one with an outdoor stretch.
    @MainActor
    func testFeatures() throws {
        scenesFile = "features.json"
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 43.6426, longitude: -79.3871))
        app = XCUIApplication()
        app.launchArguments = ["-resetRecents", "-showTouches"]
        app.launch()
        XCTAssertTrue(app.buttons["Search"].waitForExistence(timeout: 10))
        pause(2)

        // Frame the middle of campus in 3D: open a building, close its card, step back, tilt.
        app.buttons["Search"].tap()
        type("c2")
        choose("Chemistry 2")
        XCTAssertTrue(app.staticTexts["placeTitle"].waitForExistence(timeout: 5))
        pause(1)
        app.buttons["Close"].tap()
        pause(1)
        app.pinch(withScale: Double(ProcessInfo.processInfo.environment["DEMO_XRAY_PINCH"] ?? "0.7") ?? 0.7, velocity: -0.5)
        pause(1)
        app.buttons["3D"].tap()
        pause(3)

        mark("xray")
        pause(1.2)
        mode("Path")
        pause(2.2)
        mode("Street")
        pause(1.8)
        mode("Path")
        pause(1)
        app.rotate(0.5, withVelocity: 0.4)
        pause(1.5)
        mode("Street")
        pause(2)
        mark("xrayEnd")
        app.buttons["2D"].tap()
        pause(1.5)

        mark("search")
        app.buttons["Search"].tap()
        pause(1.5)
        type("engineerign 5")
        pause(1.2)
        choose("Engineering 5")
        XCTAssertTrue(app.staticTexts["placeTitle"].waitForExistence(timeout: 5))
        pause(3)
        mark("searchEnd")

        mark("routes")
        tap("directionsButton")
        pause(1.5)
        tap("outsideButton")
        pause(0.8)
        type("slc")
        pause(0.8)
        choose("Student Life Centre")
        XCTAssertTrue(app.buttons["route-3"].waitForExistence(timeout: 5))
        pause(2.5)
        for index in [1, 2, 3, 1] {
            app.buttons["route-\(index)"].tap()
            pause(2)
        }
        mark("routesEnd")

        // Balanced: a bridge, a tunnel and another bridge, then 143 m outside to E5.
        mark("navigate")
        tap("start-1")
        let progress = app.descendants(matching: .any)["navigationProgress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        pause(2)
        walk(from: 0.3, to: 0.62)
        pause(0.6)
        slowDrag(from: CGVector(dx: 0.82, dy: 0.42), to: CGVector(dx: 0.3, dy: 0.42))
        pause(2)
        for _ in 0..<20 where percent(progress) < 64 {
            flick()
            pause(1.5)
        }
        mark("outdoors")
        let arrived = app.staticTexts["You've arrived"]
        for _ in 0..<30 {
            if arrived.waitForExistence(timeout: 0.5) { break }
            walk(from: 0.25, to: 0.6)
            pause(0.8)
        }
        XCTAssertTrue(arrived.exists)
        mark("arrived")
        pause(2.5)
        app.buttons["endNavigation"].tap()
        mark("navigateEnd")
        pause(1.5)
        mark("end")
    }

    // MARK: - Steps

    @MainActor
    private func mode(_ name: String) {
        app.segmentedControls["mapModePicker"].buttons[name].tap()
    }

    /// How far along the route navigation is, from its progress bar.
    @MainActor
    private func percent(_ progress: XCUIElement) -> Int {
        Int((progress.value as? String ?? "").dropLast()) ?? 0
    }

    /// Where to drag the map so the pin, which starts on DC, lands inside MC. Set
    /// DEMO_PIN_DRAG to "fromX,fromY,toX,toY" in shares of the screen to try another.
    @MainActor
    private func pinDrag() -> (from: CGVector, to: CGVector) {
        let values = (ProcessInfo.processInfo.environment["DEMO_PIN_DRAG"] ?? "0.08,0.5,0.91,0.45")
            .split(separator: ",").compactMap { Double($0) }
        return (CGVector(dx: values[0], dy: values[1]), CGVector(dx: values[2], dy: values[3]))
    }

    @MainActor
    private func type(_ text: String) {
        let field = app.textFields["searchText"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        for character in text {
            field.typeText(String(character))
            pause(0.15)
        }
    }

    @MainActor
    private func choose(_ name: String) {
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
    private func slowDrag(from: CGVector, to: CGVector) {
        app.coordinate(withNormalizedOffset: from)
            .press(forDuration: 0.15, thenDragTo: app.coordinate(withNormalizedOffset: to), withVelocity: .slow, thenHoldForDuration: 0.25)
    }

    /// A drag down the screen walks forward along the route.
    @MainActor
    private func walk(from: CGFloat, to: CGFloat) {
        slowDrag(from: CGVector(dx: 0.5, dy: from), to: CGVector(dx: 0.5, dy: to))
    }

    @MainActor
    private func flick() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)), withVelocity: .fast, thenHoldForDuration: 0)
    }

    private func pause(_ seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Notes when a scene starts, along with the pin, so a run can be checked afterwards.
    @MainActor
    private func mark(_ name: String) {
        var scene: [String: Any] = ["name": name, "time": Date().timeIntervalSince1970]
        let pin = app.staticTexts["pickerCoordinate"]
        if pin.exists { scene["pin"] = pin.label }
        scenes.append(scene)
        let data = try? JSONSerialization.data(withJSONObject: scenes, options: [.prettyPrinted])
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data?.write(to: directory.appendingPathComponent(scenesFile))
    }
}
