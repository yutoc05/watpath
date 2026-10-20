import Foundation
import os

/// Spike results go to stdout as one JSON line per event, prefixed so they can be
/// grepped from `tools/run.sh` (simctl/devicectl console) output.
enum SpikeLog {
    private static let logger = Logger(subsystem: "ca.yutochau.watpath", category: "spike")

    static func emit(_ event: String, _ payload: some Encodable) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        print("WATPATH_SPIKE \(event) \(json)")
        logger.info("\(event, privacy: .public) \(json, privacy: .public)")
    }

    /// Writes `payload` as JSON into the app's Documents folder and returns its path.
    @discardableResult
    static func save(_ payload: some Encodable, as name: String) -> String? {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONEncoder().encode(payload)
        else { return nil }
        let url = directory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            logger.error("Could not save \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
