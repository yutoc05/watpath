import SwiftUI

@main
struct WatPathApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
            #if DEBUG
                .task { TouchIndicators.installIfRequested() }
            #endif
        }
    }
}
