/// Most-recent-first list without duplicates, capped at `capacity`.
public struct RecentList<Element: Hashable & Codable & Sendable>: Codable, Sendable, Equatable {
    public private(set) var items: [Element] = []
    public let capacity: Int

    public init(capacity: Int = 20) {
        self.capacity = capacity
    }

    /// Moves `element` to the front, adding it if new and dropping the oldest past capacity.
    public mutating func add(_ element: Element) {
        items.removeAll { $0 == element }
        items.insert(element, at: 0)
        if items.count > capacity {
            items.removeLast(items.count - capacity)
        }
    }

    public mutating func remove(_ element: Element) {
        items.removeAll { $0 == element }
    }

    public mutating func removeAll() {
        items.removeAll()
    }
}
