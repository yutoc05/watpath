import CampusGeo
import Testing

struct TriangulationTests {
    func area(of triangles: [Int], in ring: [SIMD2<Double>]) -> Double {
        stride(from: 0, to: triangles.count, by: 3).reduce(0) { sum, i in
            sum + Triangulation.signedArea([ring[triangles[i]], ring[triangles[i + 1]], ring[triangles[i + 2]]])
        }
    }

    @Test func squareMakesTwoTriangles() {
        let square: [SIMD2<Double>] = [[0, 0], [1, 0], [1, 1], [0, 1]]
        let triangles = Triangulation.triangulate(square)
        #expect(triangles.count == 6)
        #expect(abs(area(of: triangles, in: square) - 1) < 1e-12)
    }

    @Test func concaveLShapeKeepsItsArea() {
        let shape: [SIMD2<Double>] = [[0, 0], [2, 0], [2, 1], [1, 1], [1, 2], [0, 2]]
        let triangles = Triangulation.triangulate(shape)
        #expect(triangles.count == 12)
        #expect(abs(area(of: triangles, in: shape) - 3) < 1e-12)
    }

    @Test func clockwiseInputStillGivesCounterClockwiseTriangles() {
        let clockwise: [SIMD2<Double>] = [[0, 0], [0, 1], [1, 1], [1, 0], [0, 0]]  // closed, CW
        let triangles = Triangulation.triangulate(clockwise)
        #expect(abs(area(of: triangles, in: clockwise) - 1) < 1e-12)
        #expect(triangles.allSatisfy { $0 < 4 })  // closing duplicate unused
    }

    @Test func collinearVertexIsHandled() {
        let shape: [SIMD2<Double>] = [[0, 0], [1, 0], [2, 0], [2, 1], [0, 1]]
        #expect(abs(area(of: Triangulation.triangulate(shape), in: shape) - 2) < 1e-12)
    }
}
