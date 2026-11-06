import CampusGeo
import Testing

struct PolygonGeometryTests {
    let square: [[SIMD2<Double>]] = [[[0, 0], [10, 0], [10, 10], [0, 10]]]
    /// An L: a 30×10 bar along the bottom and a 10×30 bar up the left side.
    let lShape: [[SIMD2<Double>]] = [[[0, 0], [30, 0], [30, 10], [10, 10], [10, 30], [0, 30]]]
    /// A 20×20 square with a 10×10 courtyard in the middle.
    let courtyard: [[SIMD2<Double>]] = [[[0, 0], [20, 0], [20, 20], [0, 20]], [[5, 5], [15, 5], [15, 15], [5, 15]]]

    @Test func containmentHandlesHoles() {
        #expect(PolygonGeometry.contains(courtyard, [2, 2]))
        #expect(!PolygonGeometry.contains(courtyard, [10, 10]))
        #expect(!PolygonGeometry.contains(courtyard, [25, 10]))
    }

    @Test func pointsInsideStayPut() {
        #expect(PolygonGeometry.nearestPointInside(square, [3, 4], inset: 2) == [3, 4])
    }

    @Test func outsidePointsSnapInsideThePolygon() {
        let snapped = PolygonGeometry.nearestPointInside(square, [5, -7], inset: 2)
        #expect(abs(snapped.x - 5) < 1e-9 && abs(snapped.y - 2) < 1e-9)
        #expect(PolygonGeometry.contains(lShape, PolygonGeometry.nearestPointInside(lShape, [25, 25], inset: 1)))
    }

    @Test func pointsInACourtyardSnapIntoTheBuilding() {
        let snapped = PolygonGeometry.nearestPointInside(courtyard, [10, 8], inset: 1)
        #expect(PolygonGeometry.contains(courtyard, snapped))
        #expect(abs(snapped.y - 4) < 1e-9)  // out through the courtyard's south wall
    }

    @Test func labelPointIsTheMiddleOfASquare() {
        let point = PolygonGeometry.labelPoint(square)
        #expect(abs(point.x - 5) < 0.2 && abs(point.y - 5) < 0.2)
    }

    @Test func labelPointStaysInsideConcaveShapes() {
        for shape in [lShape, courtyard] {
            let point = PolygonGeometry.labelPoint(shape)
            #expect(PolygonGeometry.contains(shape, point))
            #expect(PolygonGeometry.distanceToEdges(shape, point) >= 2.4, "label too close to a wall: \(point)")
        }
    }

    @Test func windingPutsOutlinesAndHolesOppositeWays() {
        let clockwise: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(0, 10), SIMD2(10, 10), SIMD2(10, 0)]
        let counterClockwise = Array(clockwise.reversed())
        func isCounterClockwise(_ ring: [SIMD2<Double>]) -> Bool {
            zip(ring, ring.dropFirst() + ring.prefix(1)).reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y } > 0
        }
        let wound = PolygonGeometry.wound(outline: clockwise, holes: [counterClockwise])
        #expect(isCounterClockwise(wound[0]) && !isCounterClockwise(wound[1]))
        let same = PolygonGeometry.wound(outline: counterClockwise, holes: [clockwise])
        #expect(same[0] == counterClockwise && same[1] == clockwise)
    }
}
