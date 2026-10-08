import Foundation

struct YouTubeTrack: Equatable {
    let id: String
    let title: String
}

enum MusicCommand: Equatable {
    case play(String), pause, resume, restart, stop
    static func parse(_ raw: String, mediaActive: Bool = false) -> MusicCommand? {
        var text = SpokenRequest.clean(raw)
        text = text.replacingOccurrences(of: #"(?i)^\s*(?:ei[, ]+)?tars\b[, :]*"#, with: "", options: .regularExpression)
        // Strip conversational lead-ins, preserving song titles and negations.
        text = text.replacingOccurrences(of: #"(?i)^(?:(?:ent[aã]o|t[aá] bom|okay|ok|por favor)[,\s]+)+"#, with: "", options: .regularExpression)
        let normalized = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR")).lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        if mediaActive {
            if ["pause", "pausa", "pausar"].contains(normalized) { return .pause }
            if ["play", "start", "continue", "continua", "resume"].contains(normalized) { return .resume }
            if ["stop", "pare", "para"].contains(normalized) { return .stop }
        }
        if normalized.range(of: #"^reinici[ae]\s+(?:(?:a|essa|esta)\s+)?(?:faixa|musica)(?:,?\s+(?:vai|por favor))?$"#, options: .regularExpression) != nil { return .restart }
        if ["comeca de novo", "comece de novo", "comeca do inicio", "comece do inicio", "toca de novo", "toque de novo", "restart", "start over", "restart the music"].contains(normalized) { return .restart }
        if ["pause a musica", "pausa a musica", "pausar musica", "pause the music", "pause music"].contains(normalized) { return .pause }
        if ["continue a musica", "continua a musica", "continua com a musica", "continue com a musica", "retome a musica", "retoma a musica", "play the music", "resume the music", "continue the music", "play it"].contains(normalized) { return .resume }
        if ["pare a musica", "para a musica", "parar a musica", "encerre a musica", "stop the music", "stop music"].contains(normalized) { return .stop }
        // Explicit Deezer requests keep their existing handoff until authenticated playback exists.
        if normalized.contains("deezer") { return nil }
        guard let range = text.range(of: #"(?i)^(?:por favor[, ]+)?(?:(?:toque|toca|tocar|reproduza|reproduzir|coloque|coloca|play)[,\s]+)+"#, options: .regularExpression) else { return nil }
        var query = String(text[range.upperBound...])
        query = query.replacingOccurrences(of: #"(?i)^(?:(?:a|uma|essa|aquela)\s+)?m[uú]sica\s*"#, with: "", options: .regularExpression)
        query = query.replacingOccurrences(of: #"(?i)\s+(?:no|pelo|via)\s+you\s*tube\s*[.!?]*$"#, with: "", options: .regularExpression)
        query = query.replacingOccurrences(of: #"(?i)[, ]+por favor[.!?]*$"#, with: "", options: .regularExpression)
        // Keep title articles intact; they may be part of a song name.
        query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count <= 200 else { return nil }
        return .play(query)
    }
}

enum YouTubeSearch {
    static func searchURL(_ query: String) -> URL {
        var url = URLComponents(string: "https://www.youtube.com/results")!
        url.queryItems = [URLQueryItem(name: "search_query", value: query)]
        return url.url!
    }

    static func firstTrack(in html: String) -> YouTubeTrack? {
        guard let marker = html.range(of: #"(?:var\s+)?ytInitialData\s*=\s*"#, options: .regularExpression),
              let start = html[marker.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        var end: String.Index?
        for i in html[start...].indices {
            let c = html[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" { inString = true }
            else if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { end = html.index(after: i); break }
            }
        }
        guard let end, let bytes = String(html[start..<end]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: bytes) else { return nil }
        func find(_ object: Any) -> YouTubeTrack? {
            if let array = object as? [Any] {
                for child in array { if let result = find(child) { return result } }
            } else if let dict = object as? [String: Any] {
                if let video = dict["videoRenderer"] as? [String: Any],
                   let id = video["videoId"] as? String,
                   id.range(of: #"^[a-zA-Z0-9_-]{11}$"#, options: .regularExpression) != nil,
                   let title = video["title"] as? [String: Any],
                   let runs = title["runs"] as? [[String: Any]] {
                    let text = runs.compactMap { $0["text"] as? String }.joined()
                    if !text.isEmpty { return YouTubeTrack(id: id, title: String(text.prefix(300))) }
                }
                // Only traverse organic search contents, not ads, metadata or side panels.
                for key in ["contents", "twoColumnSearchResultsRenderer", "primaryContents", "sectionListRenderer", "itemSectionRenderer"] {
                    if let child = dict[key], let result = find(child) { return result }
                }
            }
            return nil
        }
        return find(root)
    }

    static func find(_ query: String) async throws -> YouTubeTrack {
        var request = URLRequest(url: searchURL(query), timeoutInterval: 12)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("pt-BR,pt;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              data.count <= 3_000_000 else { throw URLError(.badServerResponse) }
        guard let html = String(data: data, encoding: .utf8), let track = firstTrack(in: html) else { throw URLError(.cannotParseResponse) }
        return track
    }
}


/// Music lyrics must not become conversational questions while the robot is awake.
/// Direct media controls remain usable without a repeated wake word.
enum MusicSpeechPolicy {
    static func accepts(_ text: String, musicActive: Bool) -> Bool {
        !musicActive || MusicCommand.parse(text, mediaActive: musicActive) != nil ||
        text.range(of: #"(?i)\b(?:tars|wake\s+up)\b"#, options: .regularExpression) != nil
    }
}


/// A media stop must not wait for silence while the loudspeaker is playing.
/// Ignore words embedded in lyrics unless addressed explicitly to TARS.
enum MusicInterruption {
    static func phrase(in text: String, mediaActive: Bool) -> String? {
        guard mediaActive else { return nil }
        var candidate = text
        if let range = text.range(of: #"(?i)\btars[\s,.:;!?—-]+(?:pause|pausa|pausar|stop|pare|para)(?:\s+(?:a\s+m[uú]sica|(?:the\s+)?music))?[\s.!?,]*$"#, options: .regularExpression) {
            candidate = String(text[range])
        }
        switch MusicCommand.parse(candidate, mediaActive: true) {
        case .pause: return "TARS, pause a música"
        case .stop: return "TARS, pare a música"
        case .restart: return "TARS, começa de novo"
        default: return nil
        }
    }
}
