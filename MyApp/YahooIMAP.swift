import Foundation
import Network

/// Literal-aware, bounded IMAP framing. Message bytes never count as protocol replies.
enum YahooWire {
    enum Failure: Error { case invalid, rejected, timeout, closed, server(String) }
    // Only fixed protocol codes leave this parser, never the server's free-form text.
    static func rejection(_ line: String) -> Failure {
        let upper = line.uppercased()
        for code in ["AUTHENTICATIONFAILED", "AUTHORIZATIONFAILED", "UNAVAILABLE", "PRIVACYREQUIRED", "ALERT", "CANNOT", "NONEXISTENT"] {
            if upper.contains("[" + code + "]") { return .server(code) }
        }
        let status = upper.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        return .server(["NO", "BAD", "BYE"].contains(status) ? status : "REJECTED")
    }
    static func quoted(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count < 512, !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw Failure.invalid }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    struct Frame { var lines: [String]; var literals: [Data]; var consumed: Int }
    static func frame(_ data: Data, tag: String?) throws -> Frame? {
        let bytes = Array(data); var offset = 0; var lines: [String] = []; var literals: [Data] = []
        while offset < bytes.count {
            guard let end = (offset..<max(offset, bytes.count - 1)).first(where: { bytes[$0] == 13 && bytes[$0+1] == 10 }) else { return nil }
            let line = String(decoding: bytes[offset..<end], as: UTF8.self)
            offset = end + 2; lines.append(line)
            if let range = line.range(of: #"\{[0-9]+\}$"#, options: .regularExpression) {
                guard let count = Int(line[range].dropFirst().dropLast()), count <= 262144 else { throw Failure.invalid }
                guard bytes.count - offset >= count else { return nil }
                literals.append(Data(bytes[offset..<offset+count])); offset += count
            }
            if let tag {
                if line.hasPrefix(tag + " ") {
                    guard line == tag + " OK" || line.hasPrefix(tag + " OK ") else { throw rejection(line) }
                    return Frame(lines: lines, literals: literals, consumed: offset)
                }
            } else {
                guard line == "* OK" || line.hasPrefix("* OK ") else { throw rejection(line) }
                return Frame(lines: lines, literals: literals, consumed: offset)
            }
        }
        return nil
    }
    static func ids(_ frame: Frame) -> [Int] {
        frame.lines.filter { $0.hasPrefix("* SEARCH") }.flatMap { $0.split(separator: " ").dropFirst(2).compactMap { Int($0) } }.filter { $0 > 0 }.sorted()
    }
}

/// A single serial session. TLS uses the system trust store and Yahoo hostname verification.
final class YahooIMAP: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tars.yahoo.imap")
    private let connection = NWConnection(host: "imap.mail.yahoo.com", port: 993, using: .tls)
    private var buffer = Data()
    private var number = 0
    private(set) var stage = "connection"
    func close() { connection.cancel() }
    func open() async throws {
        stage = "connection"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var done = false
            let finish: (Error?) -> Void = { error in
                guard !done else { return }; done = true
                self.connection.stateUpdateHandler = nil
                if let error { self.connection.cancel(); continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
            connection.stateUpdateHandler = { state in
                switch state { case .ready: finish(nil); case .failed(let error): finish(error); case .cancelled: finish(YahooWire.Failure.closed); default: break }
            }
            queue.asyncAfter(deadline: .now() + 12) { finish(YahooWire.Failure.timeout) }
            connection.start(queue: queue)
        }
        stage = "greeting"
        _ = try await response(tag: nil)
    }
    func command(_ command: String) async throws -> YahooWire.Frame {
        number += 1; let tag = "T\(number)"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data("\(tag) \(command)\r\n".utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
        return try await response(tag: tag)
    }
    private func response(tag: String?) async throws -> YahooWire.Frame {
        // Cancelling the connection unblocks a stalled receive; the timer is removed on completion.
        let timer = DispatchWorkItem { self.connection.cancel() }
        queue.asyncAfter(deadline: .now() + 12, execute: timer)
        defer { timer.cancel() }
        while true {
            if let frame = try YahooWire.frame(buffer, tag: tag) {
                buffer.removeFirst(frame.consumed); return frame
            }
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: YahooWire.Failure.closed) }
                }
            }
            buffer.append(data)
            guard buffer.count <= 524288 else { throw YahooWire.Failure.invalid }
        }
    }
    func login(email: String, password: String) async throws {
        stage = "authentication"
        _ = try await command("LOGIN \(YahooWire.quoted(email)) \(YahooWire.quoted(password))")
        stage = "inbox"
        _ = try await command("EXAMINE INBOX") // Read-only mailbox, no flag mutations.
    }
}
