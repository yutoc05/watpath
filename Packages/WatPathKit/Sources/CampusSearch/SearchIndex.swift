import CampusModel
import Foundation

public struct SearchResult: Hashable, Sendable {
    public var place: PlaceReference
    public var title: String
    public var subtitle: String
    /// 0...1; higher is better.
    public var score: Double
}

/// Offline, typo-tolerant search over campus buildings and doors.
///
/// Scoring, best first:
/// - A building code typed exactly ("mc", "e 7" → "E7" alias handled as a phrase) wins outright.
/// - Every query word must match a word of a name or alias: exactly, as a prefix
///   (so results appear while typing), or within a small edit distance (typos).
/// - Buildings outrank doors at equal match quality.
public struct SearchIndex: Sendable {
    private struct Entry: Sendable {
        var place: PlaceReference
        var title: String
        var subtitle: String
        /// Normalized building codes; matched only exactly or by prefix, never fuzzily,
        /// so "e" doesn't drag in every E-building through typos.
        var codes: [String]
        /// Normalized names and aliases, as word lists.
        var phrases: [[String]]
        var weight: Double
    }

    private static let minimumScore = 0.5
    private let entries: [Entry]

    public init(campus: CampusBundle) {
        var entries: [Entry] = []
        for building in campus.buildings {
            entries.append(Entry(
                place: .building(code: building.code),
                title: building.name,
                subtitle: building.code,
                codes: [Self.compact(building.code)],
                phrases: ([building.name] + building.aliases).map(Self.words),
                weight: 1
            ))
        }
        for door in campus.doors {
            guard let building = campus.building(code: door.building) else { continue }
            entries.append(Entry(
                place: .door(id: door.id),
                title: door.name,
                subtitle: "\(building.code) · \(building.name)",
                codes: [],
                phrases: [Self.words("\(building.code) \(door.name)"), Self.words("\(building.name) \(door.name)")],
                weight: 0.9
            ))
        }
        self.entries = entries
    }

    public func search(_ query: String, limit: Int = 25) -> [SearchResult] {
        let queryWords = Self.words(query)
        guard !queryWords.isEmpty else { return [] }
        let compactQuery = queryWords.joined()
        return entries
            .compactMap { entry -> SearchResult? in
                let score = Self.score(entry, queryWords: queryWords, compactQuery: compactQuery)
                guard score >= Self.minimumScore else { return nil }
                return SearchResult(place: entry.place, title: entry.title, subtitle: entry.subtitle, score: score)
            }
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                if a.title.count != b.title.count { return a.title.count < b.title.count }
                return a.title < b.title
            }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: Scoring

    private static func score(_ entry: Entry, queryWords: [String], compactQuery: String) -> Double {
        var best = 0.0
        for code in entry.codes {
            if code == compactQuery {
                best = 1
            } else if code.hasPrefix(compactQuery) {
                best = max(best, 0.7 + 0.2 * Double(compactQuery.count) / Double(code.count))
            }
        }
        for phrase in entry.phrases {
            best = max(best, phraseScore(queryWords, phrase))
        }
        return best * entry.weight
    }

    /// 0 unless every query word matches some word of the phrase.
    static func phraseScore(_ query: [String], _ phrase: [String]) -> Double {
        if query == phrase { return 0.98 }
        var total = 0.0
        var matched = Set<Int>()
        for word in query {
            var bestScore = 0.0
            var bestIndex: Int?
            for (index, candidate) in phrase.enumerated() where !matched.contains(index) {
                let score = wordScore(word, candidate)
                if score > bestScore {
                    bestScore = score
                    bestIndex = index
                }
            }
            guard let bestIndex else { return 0 }
            matched.insert(bestIndex)
            total += bestScore
        }
        // Prefer phrases the query covers more fully, and ones that start the same way.
        let coverage = Double(matched.count) / Double(phrase.count)
        let startsTogether = matched.contains(0) ? 0.03 : 0
        return min(0.97, total / Double(query.count) * (0.8 + 0.2 * coverage) + startsTogether)
    }

    static func wordScore(_ word: String, _ candidate: String) -> Double {
        if word == candidate { return 1 }
        if candidate.hasPrefix(word) {
            return 0.75 + 0.2 * Double(word.count) / Double(candidate.count)
        }
        // Typos: compare against the candidate's start, since the user may still be typing.
        guard word.count >= 4 else { return 0 }
        let allowed = word.count >= 8 ? 2 : 1
        let distance = [word.count - 1, word.count, word.count + 1]
            .filter { $0 > 0 && $0 <= candidate.count }
            .map { editDistance(word, String(candidate.prefix($0))) }
            .min() ?? .max
        return distance <= allowed ? 0.6 - 0.15 * Double(distance - 1) : 0
    }

    /// Optimal string alignment distance: Levenshtein plus adjacent transpositions.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { table[i][0] = i }
        for j in 0...b.count { table[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1, table[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    table[i][j] = min(table[i][j], table[i - 2][j - 2] + 1)
                }
            }
        }
        return table[a.count][b.count]
    }

    // MARK: Normalization

    /// Lowercased, accent-free words; "&" reads as "and".
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private static func compact(_ text: String) -> String {
        words(text).joined()
    }
}
