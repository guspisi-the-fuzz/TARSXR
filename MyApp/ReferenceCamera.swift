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
