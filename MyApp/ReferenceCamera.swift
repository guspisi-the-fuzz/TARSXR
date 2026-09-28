import SwiftUI
import UIKit
import AVFoundation

/// One explicit still-photo capture. No recording, library save or network access.
struct ReferenceCamera: UIViewControllerRepresentable {
    let complete: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(complete: complete) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private var completed = false
        let complete: (UIImage?) -> Void
        init(complete: @escaping (UIImage?) -> Void) { self.complete = complete }
        private func finish(_ image: UIImage?) {
            guard !completed else { return }
            completed = true; complete(image)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { finish(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            finish(info[.originalImage] as? UIImage)
        }
    }
}

/// Reject callbacks from a cancelled or replaced capture, including permission waits.
struct ReferenceCaptureGate {
    private(set) var ticket: UUID?
    mutating func begin() -> UUID { let id = UUID(); ticket = id; return id }
    mutating func cancel() { ticket = nil }
    func accepts(_ id: UUID) -> Bool { ticket == id }
    mutating func consume(_ id: UUID) -> Bool {
        guard accepts(id) else { return false }
        ticket = nil; return true
    }
}

@MainActor
enum ReferenceCameraAccess {
    enum Result { case ready, unavailable, denied }
    static func check(available: () -> Bool = { UIImagePickerController.isSourceTypeAvailable(.camera) },
                      status: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .video) },
                      request: () async -> Bool = { await AVCaptureDevice.requestAccess(for: .video) }) async -> Result {
        guard available() else { return .unavailable }
        let allowed: Bool
        switch status() {
        case .authorized: allowed = true
        case .notDetermined: allowed = await request()
        default: allowed = false
        }
        guard allowed else { return .denied }
        return available() ? .ready : .unavailable
    }
}

@MainActor
enum ReferencePhoto {
    static func normalize(_ input: UIImage) -> (image: UIImage, png: Data)? {
        let width = input.size.width, height = input.size.height
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let ratio = min(1, 480 / max(width, height))
        let size = CGSize(width: max(1, floor(width*ratio)), height: max(1, floor(height*ratio)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.preferredRange = .standard; format.opaque = true
        let clean = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            input.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let png = clean.pngData(), png.count <= 1_000_000 else { return nil }
        return (clean, png)
    }
}

#if DEBUG
@MainActor
enum ReferenceCameraChecks {
    static func run() async throws {
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: message, code: 1) }
        }
        var requests = 0
        for status: AVAuthorizationStatus in [.denied, .restricted, .authorized] {
            let result = await ReferenceCameraAccess.check(available: { true }, status: { status }, request: { requests += 1; return true })
            try check(result == (status == .authorized ? .ready : .denied), "Camera authorization route")
        }
        let missing = await ReferenceCameraAccess.check(available: { false }, status: { .notDetermined }, request: { requests += 1; return true })
        try check(missing == .unavailable && requests == 0, "Unavailable/denied camera requested permission")
        for granted in [false, true] {
            let result = await ReferenceCameraAccess.check(available: { true }, status: { .notDetermined }, request: { requests += 1; return granted })
            try check(result == (granted ? .ready : .denied), "Camera permission answer ignored")
        }
        var connected = true
        let disconnected = await ReferenceCameraAccess.check(available: { connected }, status: { .notDetermined }, request: { connected = false; return true })
        try check(disconnected == .unavailable, "Camera disappeared while authorizing")
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let large = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800), format: format).image { c in
            UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        }
        guard let photo = ReferencePhoto.normalize(large) else { throw NSError(domain: "Photo normalization failed", code: 1) }
        try check(photo.image.size == CGSize(width: 480, height: 320) && photo.image.imageOrientation == .up, "Photo resolution/orientation")
        try check(ReferencePhoto.normalize(UIImage()) == nil, "Empty photo accepted")
        try photo.png.write(to: URL.documentsDirectory.appendingPathComponent("normalized-camera-check.png"), options: .atomic)
        var callbacks = 0
        let coordinator = ReferenceCamera.Coordinator { image in callbacks += 1; assert(image != nil) }
        let picker = UIImagePickerController()
        coordinator.imagePickerController(picker, didFinishPickingMediaWithInfo: [.originalImage: large])
        coordinator.imagePickerControllerDidCancel(picker)
        try check(callbacks == 1, "Camera emitted duplicate result")
        var cancelled = false
        let cancel = ReferenceCamera.Coordinator { cancelled = $0 == nil }
        cancel.imagePickerControllerDidCancel(picker)
        try check(cancelled, "Camera cancel did not return empty result")
    }
}
#endif
