import Foundation
import AVFoundation
import Combine

enum BluetoothState: Equatable {
    case unavailable
    case disconnected
    case connecting
    case connected(device: String)
    case error(String)
}

final class BluetoothManager: ObservableObject {

    @Published private(set) var state: BluetoothState = .disconnected
    @Published private(set) var currentRoute: AVAudioSessionRouteDescription?

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )

        refresh()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func refresh() {
        let session = AVAudioSession.sharedInstance()

        currentRoute = session.currentRoute

        guard let output = session.currentRoute.outputs.first else {
            state = .unavailable
            return
        }

        switch output.portType {

        case .bluetoothA2DP,
             .bluetoothLE,
             .bluetoothHFP:

            state = .connected(device: output.portName)

        default:

            state = .disconnected
        }
    }

    func connect() {
        refresh()
    }

    func disconnect() {
        refresh()
    }

    func reconnect() {
        refresh()
    }

    var isConnected: Bool {
        if case .connected = state {
            return true
        }

        return false
    }

    var deviceName: String {

        if case let .connected(device) = state {
            return device
        }

        return "None"
    }

    @objc
    private func handleRouteChange(_ notification: Notification) {
        refresh()
    }
}
