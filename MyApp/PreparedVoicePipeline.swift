import Foundation

/// Each part is fully downloaded and validated before playback. At most one next
/// synthesis is in flight; cancellation never repeats a spoken prefix.
@MainActor enum PreparedVoicePipeline {
    static func run(text: String, segmented: Bool = true,
                    synthesize: @escaping @MainActor (String) async throws -> Data,
                    play: @escaping @MainActor (Data) async throws -> Void) async throws {
        try Task.checkCancellation()
        let parts = segmented ? ConversationPolicy.speechParts(text) : [text]
        var next = Task { @MainActor in try await synthesize(parts[0]) }
        for index in parts.indices {
            let current = next
            let data = try await withTaskCancellationHandler(operation: {
                try await current.value
            }, onCancel: { current.cancel() })
            try Task.checkCancellation()
            let upcoming: Task<Data, Error>? = index + 1 < parts.count
                ? Task { @MainActor in try await synthesize(parts[index + 1]) } : nil
            do {
                try await withTaskCancellationHandler(operation: {
                    try await play(data)
                }, onCancel: { upcoming?.cancel() })
                try Task.checkCancellation()
            } catch { upcoming?.cancel(); throw error }
            if let upcoming { next = upcoming }
        }
    }
}
