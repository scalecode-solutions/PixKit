import SwiftUI

/// PixLab — the harness app for PixKit. Logs into mvServer (real JWT via
/// MvAuth), then hosts the kit the way a production host does: an injected
/// token provider, a blank screen in the app switcher, and (once the engine
/// is wired in) everything the kit kept wiped on sign-out. All PixKit UI development happens here.
@main
struct PixLabApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(.teal)
        }
    }
}
