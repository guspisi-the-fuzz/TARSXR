import Foundation

/// Shared admission only; releasing a lease happens after its session stops.
@MainActor final class CameraOwnership {
    enum Mode: String { case vision, photo, spatial }
    struct Lease: Equatable { let id: UUID; let mode: Mode }
    static let shared = CameraOwnership()
    private(set) var lease: Lease?
    func acquire(_ mode: Mode) -> Lease? {
        guard lease == nil else { return nil }
        let next=Lease(id:UUID(),mode:mode); lease=next; return next
    }
    func release(_ token: Lease) { if lease==token { lease=nil } }
}
