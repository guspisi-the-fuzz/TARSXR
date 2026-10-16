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
        #if DEBUG
        try? NativeAIKeychain.importProvisioning()
        #endif
        let remote = RemoteTARSRuntime(client: TARSClient(baseURL: baseURL), pairingSecret: pairingSecret)
        let services: any TARSRuntime
        var observeRecall: (@MainActor (String, String, XRMemoryDocument) -> Void)? = nil
        var logicalRecall: (@MainActor (String, XRMemoryDocument) async throws -> String?)? = nil
        if (try? NativeAIKeychain.load()) != nil {
            services = NativeAIRuntime(body: remote, ai: NativeAIRuntime.service)
            let reasoner = XRMemoryReasoner { try await NativeAIRuntime.service.interpretMemory($0) }
            logicalRecall = { try await reasoner.answer($0,document:$1) }
            observeRecall = { reasoner.observe($0,answer:$1,document:$2) }
        } else {
            // Provisioning must succeed before replacing the validated voice/vision path.
            services = remote
        }
        let weather = NativeWeatherLookup()
        return MemoryTARSRuntime(underlying: MigratingTARSRuntime(remaining: services, weather: weather), logicalRecall:logicalRecall, observeRecall:observeRecall, prepareConversation:{ weather.observeInput($0) })
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
