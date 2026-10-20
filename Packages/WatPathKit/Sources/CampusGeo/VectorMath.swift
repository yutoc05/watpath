// Small vector helpers. The simd module would provide these on Apple platforms,
// but it isn't available on Linux.

func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    (a * b).sum()
}

func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}

func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
    a.x * b.y - a.y * b.x
}

func length(_ v: SIMD2<Double>) -> Double {
    (v * v).sum().squareRoot()
}
