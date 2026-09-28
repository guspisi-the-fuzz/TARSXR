import SwiftUI

@main
struct MyApp: App {
    private var coreURL: URL {
        #if targetEnvironment(simulator)
        return URL(string: "http://127.0.0.1:8770")!
        #else
        return URL(string: "http://127.0.0.1:8765")!
        #endif
    }

    var body: some Scene {
        WindowGroup {
            TarsHUDView(
                model: TarsHUDViewModel(
                    baseURL: coreURL,
                    pairingSecret: "tars-xr-local-test"
                )
            )
        }
    }
}
