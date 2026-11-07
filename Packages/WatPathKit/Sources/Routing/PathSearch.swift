import CampusGeo

/// One step of a walk: an edge, and which way along it.
struct Hop: Sendable {
    var edge: Int
    var isForward: Bool
    /// Storeys of stairs on the way onto this edge.
    var storeys = 0.0
}

/// The cheapest walk between two endpoints.
struct Walk: Sendable {
    /// Index into the start's attachments. Nil when the walk stays on one edge.
    var startAttachment: Int?
    var hops: [Hop]
    var endAttachment: Int?
    /// Storeys changed along the way.
    var storeys: Double
}

/// Dijkstra over (node, floor) rather than nodes alone. The map is flat, but the bridge
/// you leave a building by may be two floors above the one you came in on, so what a
/// corridor costs depends on how you got there. A corridor keeps the floor you're on;
/// an edge with `floors` charges for the stairs to reach it, then puts you on its far
/// side's floor. On the first edge of a walk, and after going outside, nobody knows the
/// floor, and unknown floors are free: the time is never padded with a guess.
struct PathSearch {
    let graph: WalkGraph
    let model: TimeModel
    /// Every storey in the graph. Index 0 is "unknown".
    private let levels: [Double?]
    private let levelIndex: [Double: Int]

    init(graph: WalkGraph, model: TimeModel) {
        self.graph = graph
        self.model = model
        let known = Set(graph.edges.flatMap { $0.floors ?? [] }.flatMap { [$0.enter, $0.exit] }.compactMap { $0 })
        levels = [nil] + known.sorted()
        levelIndex = Dictionary(uniqueKeysWithValues: known.sorted().enumerated().map { ($1, $0 + 1) })
    }

    private struct Back {
        /// The state before this one, or -1 at the start.
        var state: Int32 = -1
        /// The edge taken, or the attachment when `state` is -1.
        var via: Int32 = -1
        var isForward = true
        var climbed: Float = 0
    }

    /// The cheapest walk, where a second outside costs `outsideWeight` seconds inside.
    /// `direct` is the walk between the two endpoints when they're on the same edge.
    func cheapestWalk(from start: Endpoint, to end: Endpoint, direct: Endpoint.Attachment?, outsideWeight: Double) -> Walk? {
        let levelCount = levels.count
        let stateCount = graph.nodes.count * levelCount
        var best = [Double](repeating: .infinity, count: stateCount)
        var back = [Back](repeating: Back(), count: stateCount)
        var heap = MinHeap()

        func cost(of attachment: Endpoint.Attachment) -> Double {
            (attachment.inside + attachment.outside * outsideWeight) / model.walkingSpeed
        }

        for (index, attachment) in start.attachments.enumerated() {
            let state = attachment.node * levelCount
            let total = cost(of: attachment)
            if total < best[state] {
                best[state] = total
                back[state] = Back(state: -1, via: Int32(index))
                heap.push(total, state)
            }
        }

        var arrival = Double.infinity
        var arrivalState = -1
        var arrivalAttachment = -1
        if let direct {
            arrival = cost(of: direct)
        }
        var attachmentsAt: [Int: [Int]] = [:]
        for (index, attachment) in end.attachments.enumerated() {
            attachmentsAt[attachment.node, default: []].append(index)
        }

        while let (total, state) = heap.pop() {
            guard total <= best[state] else { continue }
            guard total < arrival else { break }
            let node = state / levelCount
            let levelNumber = state % levelCount

            for index in attachmentsAt[node] ?? [] {
                let finish = total + cost(of: end.attachments[index])
                if finish < arrival {
                    arrival = finish
                    arrivalState = state
                    arrivalAttachment = index
                }
            }

            for step in graph.steps[node] {
                let edge = graph.edges[step.edge]
                let walking = edge.length / model.walkingSpeed * (edge.kind.isInside ? 1 : outsideWeight)
                let base = total + walking + (edge.kind == .door ? model.doorSeconds : 0)

                func relax(_ next: Int, _ cost: Double, climbed: Double) {
                    guard cost < best[next] else { return }
                    best[next] = cost
                    back[next] = Back(state: Int32(state), via: Int32(step.edge), isForward: step.isForward, climbed: Float(climbed))
                    heap.push(cost, next)
                }

                guard let changes = edge.floors else {
                    relax(step.to * levelCount + levelNumber, base, climbed: 0)
                    continue
                }
                for change in changes {
                    let oriented = step.isForward ? change : change.reversed
                    let climbed = storeys(from: levels[levelNumber], to: oriented.enter)
                    let next = oriented.exit.flatMap { levelIndex[$0] } ?? 0
                    relax(step.to * levelCount + next, base + climbed * model.storeySeconds, climbed: climbed)
                }
            }
        }

        guard arrival < .infinity else { return nil }
        guard arrivalState >= 0 else { return Walk(startAttachment: nil, hops: [], endAttachment: nil, storeys: 0) }

        var hops: [Hop] = []
        var climbed = 0.0
        var state = arrivalState
        while back[state].state >= 0 {
            let step = back[state]
            hops.append(Hop(edge: Int(step.via), isForward: step.isForward, storeys: Double(step.climbed)))
            climbed += Double(step.climbed)
            state = Int(step.state)
        }
        return Walk(startAttachment: Int(back[state].via), hops: hops.reversed(), endAttachment: arrivalAttachment, storeys: climbed)
    }

    private func storeys(from: Double?, to: Double?) -> Double {
        guard let from, let to else { return 0 }
        return abs(from - to)
    }
}

/// A binary min-heap of (cost, state).
private struct MinHeap {
    private var items: [(cost: Double, state: Int)] = []

    mutating func push(_ cost: Double, _ state: Int) {
        items.append((cost, state))
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard items[child].cost < items[parent].cost else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> (Double, Int)? {
        guard let first = items.first else { return nil }
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var parent = 0
            while true {
                let left = 2 * parent + 1, right = left + 1
                var smallest = parent
                if left < items.count, items[left].cost < items[smallest].cost { smallest = left }
                if right < items.count, items[right].cost < items[smallest].cost { smallest = right }
                guard smallest != parent else { break }
                items.swapAt(parent, smallest)
                parent = smallest
            }
        }
        return (first.cost, first.state)
    }
}
