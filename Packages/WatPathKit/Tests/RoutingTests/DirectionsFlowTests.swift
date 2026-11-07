import Testing

@testable import Routing

struct DirectionsFlowTests {
    private typealias Flow = DirectionsFlow<String>

    private func route(_ id: Int) -> Route {
        var route = Route(spans: [], distance: 100, insideLength: 100, outsideLength: 0, seconds: 77, storeys: 0, buildings: [], edges: [])
        route.id = id
        return route
    }

    private func flow(_ events: Flow.Event...) -> Flow {
        var flow = Flow()
        for event in events { flow.send(event) }
        return flow
    }

    @Test func startsIdle() {
        #expect(Flow().step == .idle)
        #expect(!Flow().isActive)
    }

    @Test func choosingADestinationAsksWhereYouAre() {
        let flow = flow(.chooseDestination("DC"))
        #expect(flow.step == .originPrompt)
        #expect(flow.destination == "DC")
        #expect(flow.isActive)
    }

    @Test func inThePathGoesThroughThePin() {
        let flow = flow(.chooseDestination("DC"), .chooseInPath)
        #expect(flow.step == .pickingOriginInPath)
    }

    @Test func outsideGoesThroughTheSearch() {
        #expect(flow(.chooseDestination("DC"), .chooseOutside).step == .searchingOrigin)
        #expect(flow(.chooseDestination("DC"), .chooseOutside, .chooseOriginOnMap).step == .pickingOriginOnMap)
    }

    @Test func settingTheOriginFindsRoutesFromAnyWayOfChoosingIt() {
        for path in [[Flow.Event.chooseInPath], [.chooseOutside], [.chooseOutside, .chooseOriginOnMap]] {
            var flow = flow(.chooseDestination("DC"))
            path.forEach { flow.send($0) }
            flow.send(.setOrigin("MC"))
            #expect(flow.step == .findingRoutes)
            #expect(flow.origin == "MC")
        }
    }

    @Test func routesShowWithTheFirstOneSelected() {
        let routes = [route(0), route(1)]
        let flow = flow(.chooseDestination("DC"), .chooseOutside, .setOrigin("MC"), .found(routes, from: "MC"))
        #expect(flow.step == .routes(routes, selected: 0))
        #expect(flow.selectedRoute == routes[0])
    }

    @Test func selectingARouteShowsIt() {
        let routes = [route(0), route(1)]
        var flow = flow(.chooseDestination("DC"), .chooseOutside, .setOrigin("MC"), .found(routes, from: "MC"))
        flow.send(.selectRoute(1))
        #expect(flow.selectedRoute == routes[1])
        flow.send(.selectRoute(7))
        #expect(flow.selectedRoute == routes[1])
    }

    @Test func noRoutesIsItsOwnStep() {
        #expect(flow(.chooseDestination("DC"), .chooseOutside, .setOrigin("MC"), .found([], from: "MC")).step == .noRoutes)
    }

    @Test func routesForAnOldOriginAreIgnored() {
        var flow = flow(.chooseDestination("DC"), .chooseOutside, .setOrigin("MC"), .back, .chooseOutside, .setOrigin("SLC"))
        flow.send(.found([route(0)], from: "MC"))
        #expect(flow.step == .findingRoutes)
        flow.send(.found([route(0)], from: "SLC"))
        #expect(flow.selectedRoute != nil)
    }

    @Test func routesArrivingAfterLeavingAreIgnored() {
        var flow = flow(.chooseDestination("DC"), .chooseOutside, .setOrigin("MC"), .cancel)
        flow.send(.found([route(0)], from: "MC"))
        #expect(flow.step == .idle)
    }

    @Test func backGoesOneStepAtATime() {
        #expect(flow(.chooseDestination("DC"), .chooseOutside, .chooseOriginOnMap, .back).step == .searchingOrigin)
        #expect(flow(.chooseDestination("DC"), .chooseOutside, .back).step == .originPrompt)
        #expect(flow(.chooseDestination("DC"), .chooseInPath, .back).step == .originPrompt)
        #expect(flow(.chooseDestination("DC"), .back).step == .idle)
    }

    @Test func backFromRoutesForgetsTheOriginButNotTheDestination() {
        let flow = flow(.chooseDestination("DC"), .chooseOutside, .setOrigin("MC"), .found([route(0)], from: "MC"), .back)
        #expect(flow.step == .originPrompt)
        #expect(flow.origin == nil)
        #expect(flow.destination == "DC")
    }

    @Test func cancelLeavesFromAnywhere() {
        let flow = flow(.chooseDestination("DC"), .chooseOutside, .setOrigin("MC"), .found([route(0)], from: "MC"), .cancel)
        #expect(flow == Flow())
    }

    private func navigating() -> Flow {
        flow(.chooseDestination("DC"), .chooseOutside, .setOrigin("MC"), .found([route(0), route(1)], from: "MC"), .startRoute(1))
    }

    @Test func startingARouteNavigatesThatRoute() {
        let flow = navigating()
        #expect(flow.step == .navigating(route(1)))
        #expect(flow.activeRoute == route(1))
        #expect(flow.destination == "DC")
    }

    @Test func aRouteThatIsntOnTheListDoesntStart() {
        var flow = flow(.chooseDestination("DC"), .chooseOutside, .setOrigin("MC"), .found([route(0)], from: "MC"))
        flow.send(.startRoute(9))
        #expect(flow.activeRoute == nil)
    }

    @Test func reachingTheEndArrivesAndScrubbingBackUndoesIt() {
        var flow = navigating()
        flow.send(.reachedEnd)
        #expect(flow.step == .arrived(route(1)))
        #expect(flow.activeRoute == route(1))
        flow.send(.leftEnd)
        #expect(flow.step == .navigating(route(1)))
    }

    @Test func endingLeavesFromNavigatingOrArrived() {
        var flow = navigating()
        flow.send(.cancel)
        #expect(flow == Flow())
        flow = navigating()
        flow.send(.reachedEnd)
        flow.send(.cancel)
        #expect(flow == Flow())
    }

    @Test func thereIsNoGoingBackFromNavigationExceptByEnding() {
        var flow = navigating()
        flow.send(.back)
        #expect(flow.activeRoute != nil)
    }

    @Test func eventsThatMakeNoSenseAreIgnored() {
        #expect(flow(.chooseInPath).step == .idle)
        #expect(flow(.setOrigin("MC")).step == .idle)
        #expect(flow(.back).step == .idle)
        #expect(flow(.chooseDestination("DC"), .setOrigin("MC")).step == .originPrompt)
        #expect(flow(.chooseDestination("DC"), .chooseDestination("MC")).destination == "DC")
        #expect(flow(.chooseDestination("DC"), .chooseInPath, .chooseOriginOnMap).step == .pickingOriginInPath)
        #expect(flow(.chooseDestination("DC"), .startRoute(0)).step == .originPrompt)
        #expect(flow(.reachedEnd).step == .idle)
    }
}
