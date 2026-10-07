import SwiftUI
import UIKit

@main
struct MyApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private var coreURL: URL {
        #if targetEnvironment(simulator)
        return URL(string: "http://127.0.0.1:8770")!
        #else
        return URL(string: "http://127.0.0.1:8765")!
        #endif
    }

    private func makeRuntime() -> any TARSRuntime {
        let baseURL: URL
        let pairingSecret: String
        #if DEBUG
        baseURL = ProcessInfo.processInfo.environment["TARS_CORE_URL"].flatMap(URL.init(string:)) ?? coreURL
        pairingSecret = ProcessInfo.processInfo.environment["TARS_PAIRING_SECRET"] ?? "tars-xr-local-test"
        #else
        baseURL = coreURL
        pairingSecret = "tars-xr-local-test"
        #endif
        return MemoryTARSRuntime(underlying: RemoteTARSRuntime(
            client: TARSClient(baseURL: baseURL),
            pairingSecret: pairingSecret
        ))
    }

    var body: some Scene {
        WindowGroup {
            TarsHUDView(
                model: TarsHUDViewModel(
                    runtime: makeRuntime()
                )
            )
            // TARS is a continuously visible robot display, not a touch-driven app.
            // This prevents idle auto-lock only; manual lock and backgrounding remain.
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = scenePhase == .active
            }
            .onChange(of: scenePhase) { _, phase in
                UIApplication.shared.isIdleTimerDisabled = phase == .active
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }
}
