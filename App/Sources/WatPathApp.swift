import SwiftUI

@main
struct WatPathApp: App {
    /// Launch with `-spike` (or `-autoSpike`) to open the Phase 0 camera-sync spike.
    private static let showsSpike = ProcessInfo.processInfo.arguments.contains { $0 == "-spike" || $0 == "-autoSpike" }

    var body: some Scene {
        WindowGroup {
            if Self.showsSpike {
                CameraSpikeView()
            } else {
                RootView()
            }
        }
    }
}
