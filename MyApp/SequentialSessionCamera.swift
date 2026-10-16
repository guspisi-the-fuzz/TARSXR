import Foundation

/// No queue of frames: exactly one fresh sample may satisfy an explicit request.
struct VideoFrameGate: Sendable {
    private(set) var ticket: UUID?
    private(set) var closed = false
    private var lastTimestamp: Double?
    mutating func begin() -> UUID? {
        guard !closed, ticket == nil else { return nil }
        let id = UUID(); ticket = id; return id
    }
    mutating func consume(timestamp: Double) -> Bool {
        guard !closed, ticket != nil, timestamp.isFinite, timestamp >= 0,
              lastTimestamp.map({ timestamp > $0 }) ?? true else { return false }
        ticket = nil; lastTimestamp = timestamp; return true
    }
    mutating func cancel() { ticket = nil }
    mutating func close() { closed = true; ticket = nil }
}

#if canImport(UIKit)
import UIKit
import AVFoundation
import CoreImage

/// Low-rate video acquisition, no recording, microphone, still shutter or network.
/// All mutable camera state and delegate delivery share one serial queue.
final class SequentialSessionCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "tars.xr.sequential.video")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var configured = false
    private var pending: CheckedContinuation<UIImage, Error>?
    private var gate = VideoFrameGate()
    private var observers: [NSObjectProtocol] = []

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func capture() async throws -> UIImage {
        try Task.checkCancellation()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw VoiceCameraError.denied }
        default: throw VoiceCameraError.denied
        }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard self.pending == nil, let id = self.gate.begin() else {
                        continuation.resume(throwing: VoiceCameraError.captureFailed); return
                    }
                    self.pending = continuation
                    do {
                        if !self.configured { try self.configure(); self.configured = true }
                        if !self.session.isRunning {
                            print("[TARS_CAMERA] video start BEGIN", ProcessInfo.processInfo.systemUptime)
                            self.session.startRunning()
                            print("[TARS_CAMERA] video start END", ProcessInfo.processInfo.systemUptime)
                        }
                        guard self.session.isRunning, !self.session.isInterrupted else { throw VoiceCameraError.captureFailed }
                        print("[TARS_CAMERA] video sample REQUEST", ProcessInfo.processInfo.systemUptime)
                        self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                            guard let self, self.gate.ticket == id else { return }
                            print("[TARS_CAMERA] video sample TIMEOUT")
                            self.finish(.failure(VoiceCameraError.captureFailed))
                        }
                    } catch { self.finish(.failure(error)) }
                }
            }
        }, onCancel: {
            self.queue.async { self.close() }
        })
    }
    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { self.close(); continuation.resume() }
        }
    }
    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw VoiceCameraError.unavailable }
        session.beginConfiguration()
        do {
        guard session.canSetSessionPreset(.vga640x480) else { throw VoiceCameraError.unavailable }
        session.sessionPreset = .vga640x480
        let input = try AVCaptureDeviceInput(device: device)
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddInput(input), session.canAddOutput(output) else { throw VoiceCameraError.unavailable }
        session.addInput(input); session.addOutput(output)
        guard let connection = output.connection(with: .video), connection.isVideoOrientationSupported else { throw VoiceCameraError.unavailable }
        // XR is mounted vertically. AVFoundation rotates the delivered pixel buffers.
        connection.videoOrientation = .portrait
        } catch {
            session.commitConfiguration()
            throw error
        }
        session.commitConfiguration()

        // Request 5 fps when supported; otherwise use the lowest supported rate
        // above 5. Only one frame per policy request is converted/normalized.
        let rates = device.activeFormat.videoSupportedFrameRateRanges
        guard let range = rates.min(by: { max(5, $0.minFrameRate) < max(5, $1.minFrameRate) }) else { throw VoiceCameraError.unavailable }
        let fps = min(range.maxFrameRate, max(5, range.minFrameRate))
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        let interval = CMTime(seconds: 1 / fps, preferredTimescale: 60000)
        device.activeVideoMinFrameDuration = interval
        device.activeVideoMaxFrameDuration = interval
        print("[TARS_CAMERA] video configured 640x480 portrait; fps", fps)
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] notification in
                let message = String(describing: notification.userInfo?[AVCaptureSessionErrorKey])
                self?.queue.async {
                    guard let self else { return }
                    print("[TARS_CAMERA] video unavailable", message)
                    self.close()
                }
            })
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard pending != nil, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard timestamp.isValid, !timestamp.isIndefinite,
              gate.consume(timestamp: CMTimeGetSeconds(timestamp)) else { return }
        autoreleasepool {
            guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                finish(.failure(VoiceCameraError.invalidImage)); return
            }
            let image = CIImage(cvPixelBuffer: buffer)
            guard let cg = context.createCGImage(image, from: image.extent) else {
                finish(.failure(VoiceCameraError.invalidImage)); return
            }
            print("[TARS_CAMERA] video sample RECEIVED", ProcessInfo.processInfo.systemUptime)
            finish(.success(UIImage(cgImage: cg, scale: 1, orientation: .up)))
        }
    }
    private func finish(_ result: Result<UIImage, Error>) {
        let continuation = pending; pending = nil; gate.cancel()
        continuation?.resume(with: result)
    }
    private func close() {
        gate.close()
        if session.isRunning {
            print("[TARS_CAMERA] video stop BEGIN", ProcessInfo.processInfo.systemUptime)
            session.stopRunning()
            print("[TARS_CAMERA] video stop END", ProcessInfo.processInfo.systemUptime)
        }
        finish(.failure(CancellationError()))
    }
}
#endif
