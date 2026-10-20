/// Derivative-free minimizer (Nelder–Mead downhill simplex). Used for camera
/// calibration, where the objective is a reprojection error with no handy gradient.
public enum NelderMead {
    public struct Result: Sendable {
        public var point: [Double]
        public var value: Double
        public var iterations: Int
    }

    /// Minimizes `objective` starting from `start`, with an initial simplex that
    /// steps each coordinate by `step`. Stops once every simplex vertex scores
    /// within `tolerance` of the best.
    public static func minimize(
        start: [Double],
        step: [Double],
        tolerance: Double = 1e-12,
        maxIterations: Int = 5000,
        _ objective: ([Double]) -> Double
    ) -> Result {
        precondition(start.count == step.count && !start.isEmpty)
        let n = start.count
        var simplex = [start] + (0..<n).map { i in
            var vertex = start
            vertex[i] += step[i]
            return vertex
        }
        var values = simplex.map(objective)
        var iterations = 0

        while iterations < maxIterations {
            iterations += 1
            let order = values.indices.sorted { values[$0] < values[$1] }
            simplex = order.map { simplex[$0] }
            values = order.map { values[$0] }
            if values[n] - values[0] <= tolerance { break }

            let centroid = (0..<n).map { j in simplex[0..<n].reduce(0) { $0 + $1[j] } / Double(n) }
            // Points on the line from the worst vertex through the centroid.
            func along(_ t: Double) -> [Double] {
                zip(centroid, simplex[n]).map { c, worst in c + t * (c - worst) }
            }

            let reflected = along(1)
            let reflectedValue = objective(reflected)
            if reflectedValue < values[0] {
                let expanded = along(2)
                let expandedValue = objective(expanded)
                (simplex[n], values[n]) = expandedValue < reflectedValue
                    ? (expanded, expandedValue)
                    : (reflected, reflectedValue)
            } else if reflectedValue < values[n - 1] {
                (simplex[n], values[n]) = (reflected, reflectedValue)
            } else {
                let contracted = reflectedValue < values[n] ? along(0.5) : along(-0.5)
                let contractedValue = objective(contracted)
                if contractedValue < min(reflectedValue, values[n]) {
                    (simplex[n], values[n]) = (contracted, contractedValue)
                } else {
                    for i in 1...n {
                        simplex[i] = zip(simplex[0], simplex[i]).map { best, p in best + 0.5 * (p - best) }
                        values[i] = objective(simplex[i])
                    }
                }
            }
        }

        let best = values.indices.min { values[$0] < values[$1] }!
        return Result(point: simplex[best], value: values[best], iterations: iterations)
    }
}
