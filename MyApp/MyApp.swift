import SwiftUI

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            TarsHUDView(
                model: TarsHUDViewModel(
                    baseURL: URL(string: "http://127.0.0.1:8765")!,
                    pairingSecret: "tars-xr-local-test"
                )
            )
        }
    }
}
