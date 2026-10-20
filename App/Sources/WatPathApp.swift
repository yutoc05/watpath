import SwiftUI

@main
struct WatPathApp: App {
    var body: some Scene {
        WindowGroup {
            // Phase 0: the app is the camera-sync spike until Street Map lands (docs/PLAN.md §8).
            CameraSpikeView()
        }
    }
}
