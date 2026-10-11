import Foundation
import CoreFoundation

/// First migrated Core service. Owns clarification on the XR, never sends weather to the Mac.
@MainActor final class NativeWeatherLookup {
    typealias Fetch = @MainActor (URL) async throws -> [String: Any]
    private let fetch: Fetch
    private let now: () -> Date
    private let zone: TimeZone
    private var pending: (text: String, deadline: Date)?
    private var recent: (query: String, city: String, deadline: Date)?
    init(now: @escaping () -> Date = Date.init, zone: TimeZone = .current, fetch: @escaping Fetch = NativeWeatherLookup.fetchJSON) {
        self.now = now; self.zone = zone; self.fetch = fetch
    }
    static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR")).lowercased()
    }
    static func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }
    static func isWeather(_ raw: String) -> Bool {
        let n = normalize(raw)
        if matches(n, #"\b(toca|toque|play|musica|filme|livro|nao|nunca)\b"#) { return false }
        return matches(n, #"\b(chover|chove|chovera|chuva|previsao do tempo|temperatura|clima|quantos graus|sensacao termica)\b"#)
            || matches(n, #"\b(como|qual).*\btempo\b.*\b(hoje|amanha|em)\b"#)
    }
    static let states = Dictionary(uniqueKeysWithValues: zip(
        "AC AL AP AM BA CE DF ES GO MA MT MS MG PA PB PR PE PI RJ RN RS RO RR SC SP SE TO".split(separator: " ").map(String.init),
        "Acre|Alagoas|Amapá|Amazonas|Bahia|Ceará|Distrito Federal|Espírito Santo|Goiás|Maranhão|Mato Grosso|Mato Grosso do Sul|Minas Gerais|Pará|Paraíba|Paraná|Pernambuco|Piauí|Rio de Janeiro|Rio Grande do Norte|Rio Grande do Sul|Rondônia|Roraima|Santa Catarina|São Paulo|Sergipe|Tocantins".split(separator: "|").map(String.init)))
    static func location(_ text: String) -> (String, String?) {
        let clean = text.trimmingCharacters(in: CharacterSet(charactersIn: " ?!.,;"))
        let parts = clean.components(separatedBy: ",")
        if parts.count > 1 {
            let region = normalize(parts.dropFirst().joined(separator: ",")).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"^(no estado de|estado de|estado do)\s+"#, with: "", options: .regularExpression)
            return (parts[0], states[region.uppercased()] ?? region)
        }
        let words = clean.split(separator: " ").map(String.init)
        if words.count > 1 {
            for i in 1..<words.count {
                let suffix = normalize(words[i...].joined(separator: " ")).replacingOccurrences(of: #"^(no estado de|estado de|estado do|no|na|de)\s+"#, with: "", options: .regularExpression)
                for (code, state) in states where suffix == normalize(code) || suffix == normalize(state) {
                    return (words[..<i].joined(separator: " "), state)
                }
            }
        }
        return (clean, nil)
    }
    private static func capture(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
    private func formatter(_ format: String, zone: TimeZone? = nil) -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = zone ?? self.zone; f.dateFormat = format; f.isLenient = false; return f
    }
    private static func url(_ base: String, _ params: [String: String]) -> URL {
        var u = URLComponents(string: base)!; u.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }; return u.url!
    }
    enum Failure: Error { case invalid }
    static func fetchJSON(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 8); request.setValue("TARS-XR/1.0", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw Failure.invalid }
        var data = Data()
        for try await byte in bytes { data.append(byte); guard data.count <= 400000 else { throw Failure.invalid } }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["error"] == nil else { throw Failure.invalid }
        return json
    }
    private static func number(_ value: Any?, min: Double, max: Double) throws -> Double {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, (min...max).contains(n.doubleValue) else { throw Failure.invalid }
        return n.doubleValue
    }
    func answer(_ raw: String) async -> String? {
        var text = SpokenRequest.clean(raw)
        let normalized = Self.normalize(text)
        if Self.matches(normalized, #"^(never mind|nevermind|esquece|deixa pra la|cancela|cancelar|cancel|para|pare|stop|nao)([ !.,?].*)?$"#) {
            pending = nil; recent = nil
            return nil
        }
        if recent?.deadline ?? .distantPast <= now() { recent = nil }
        if pending?.deadline ?? .distantPast <= now() { pending = nil }
        let otherIntent = Self.matches(normalized, #"\b(move|forward|backward|andar|ande|anda|frente|tras|movimentar|movimento|esp32|comandos|consegue|can|you|toca|toque|play|pause|stop|email|musica|quem|aniversario|horas|obrigado)\b"#)
        if otherIntent { pending = nil; recent = nil; return nil }
        if !Self.isWeather(text) {
            let followCity = Self.capture(text, #"^e\s+(?:em|na cidade de)\s+(.+)"#)
            let candidate = followCity ?? text
            let looksLikeCity = candidate.count < 100 && Self.matches(candidate, #"^[\p{L} ,.-]+[?!.]?$"#)
                && !Self.matches(Self.normalize(candidate), #"\b(qual|como|quero|entendi|fala|me|voce|sim|what|the|is|my)\b"#)
            if let old = recent, let city = followCity, looksLikeCity {
                text = old.query + " em " + city
            } else if let p = pending, looksLikeCity {
                text = p.text + " em " + candidate
            } else { pending = nil; recent = nil; return nil }
        }
        let n = Self.normalize(text)
        let offset = n.contains("depois de amanha") ? 2 : n.contains("amanha") ? 1 : n.contains("ontem") ? -1 : 0
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let today = calendar.startOfDay(for: now())
        var day = calendar.date(byAdding: .day, value: offset, to: today)!
        if let numeric = Self.capture(text, #"(?<!\d)(\d{1,2}/\d{1,2}(?:/\d{4})?)(?!\d)"#) {
            let dated = numeric.split(separator: "/").count == 3 ? numeric : numeric + "/" + formatter("yyyy").string(from: today)
            guard let date = formatter("d/M/yyyy").date(from: dated) else { return "Essa data não existe no calendário. Qual dia você quer consultar?" }; day = date
        } else if let words = Self.capture(n, #"\b(\d{1,2} de (?:janeiro|fevereiro|marco|abril|maio|junho|julho|agosto|setembro|outubro|novembro|dezembro)(?: de \d{4})?)\b"#) {
            let dated = Self.matches(words, #"\d{4}$"#) ? words : words + " de " + formatter("yyyy").string(from: today)
            guard let date = formatter("d 'de' MMMM 'de' yyyy").date(from: dated.replacingOccurrences(of: "marco", with: "março")) else { return "Essa data não existe no calendário. Qual dia você quer consultar?" }; day = date
        } else if Self.matches(n, #"\b(semana|segunda|terca|quarta|quinta|sexta|sabado|domingo)\b"#) {
            return "Diga o dia da previsão: hoje, amanhã ou uma data como 8 de outubro."
        }
        guard let distance = calendar.dateComponents([.day], from: today, to: day).day, (0..<16).contains(distance) else { return "Consigo consultar a previsão de hoje até os próximos quinze dias. Qual data você quer?" }
        let found = Self.capture(text, #"\b(?:em|na cidade de|para a cidade de)\s+(.+)"#) ?? Self.capture(text, #"\b(?:tempo|clima|temperatura)\s+(?:de|para)\s+(.+)"#) ?? ""
        var city = found.replacingOccurrences(of: #"(?i)\b(?:agora|neste momento|atualmente|hoje|amanh[ãa]|depois de amanh[ãa]|ontem|no dia|dia \d|por favor|por gentileza|vai chover|qual|como|ser[aá]|previs[aã]o do tempo)\b.*|\d{1,2}/\d{1,2}.*"#, with: "", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: " ?!.,;"))
        if city.isEmpty || ["la", "ai", "nessa cidade", "nesta cidade"].contains(Self.normalize(city)) {
            if let old = recent { city = old.city }
        }
        guard !city.isEmpty, !["aqui", "casa", "que horario", "que horas"].contains(Self.normalize(city)) else {
            pending = (text.replacingOccurrences(of: #"\s+em\s*$"#, with: "", options: .regularExpression), now().addingTimeInterval(120))
            return "Em qual cidade você quer consultar a previsão?"
        }
        pending = nil
        let (name, region) = Self.location(city)
        let mean = Self.matches(n, #"\bmedia\b"#)
        let current = !mean && Self.matches(n, #"\b(temperatura|graus|sensacao termica)\b"#) && !Self.matches(n, #"\b(amanha|ontem|depois|maxima|minima|previsao)\b|\d{1,2}/\d{1,2}|\d{1,2} de "#)
        do {
            let geo = try await fetch(Self.url("https://geocoding-api.open-meteo.com/v1/search", ["name":name, "count":"10", "language":"pt", "format":"json"]))
            let places = (geo["results"] as? [[String: Any]] ?? []).filter { place in
                Self.normalize(place["name"] as? String ?? "") == Self.normalize(name) && (region == nil || ["admin1", "country", "country_code"].contains { Self.normalize(place[$0] as? String ?? "") == Self.normalize(region!) })
            }
            guard places.count == 1, let place = places.first else {
                pending = (text.components(separatedBy: " em ").first ?? text, now().addingTimeInterval(120))
                return places.isEmpty ? "Não localizei \(city) com segurança. Diga a cidade e o estado." : "Encontrei mais de uma cidade chamada \(name). Diga também o estado ou país."
            }
            let query = text.replacingOccurrences(of: #"(?i)\s+em\s+.+$"#, with: "", options: .regularExpression)
            recent = (query, city, now().addingTimeInterval(120))
            let lat = try Self.number(place["latitude"], min: -90, max: 90), lon = try Self.number(place["longitude"], min: -180, max: 180)
            guard let tz = place["timezone"] as? String, let cityZone = TimeZone(identifier: tz) else { throw Failure.invalid }
            var params = ["latitude":"\(lat)", "longitude":"\(lon)", "timezone":tz, "forecast_days":"16", "daily":"precipitation_probability_max,temperature_2m_min,temperature_2m_max", "hourly":"temperature_2m,precipitation_probability", "temperature_unit":"celsius"]
            if current { params["current"] = "temperature_2m" }
            let data = try await fetch(Self.url("https://api.open-meteo.com/v1/forecast", params))
            guard data["timezone"] as? String == tz else { throw Failure.invalid }
            let label = [place["name"] as? String, place["admin1"] as? String].compactMap { $0 }.joined(separator: ", ")
            if current {
                guard let values = data["current"] as? [String: Any], let units = data["current_units"] as? [String: String], units["temperature_2m"] == "°C",
                      let stamp = values["time"] as? String, let observed = formatter("yyyy-MM-dd'T'HH:mm", zone: cityZone).date(from: stamp), (-300...5400).contains(now().timeIntervalSince(observed)) else { throw Failure.invalid }
                let value = try Self.number(values["temperature_2m"], min: -100, max: 70)
                return "Em \(label), a temperatura atual estimada pela Open-Meteo é de \(String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")) graus Celsius. Dado de \(formatter("d 'de' MMMM 'de' yyyy 'às' HH:mm", zone: cityZone).string(from: observed)), no horário da cidade."
            }
            let date = formatter("yyyy-MM-dd").string(from: day), spoken = formatter("d 'de' MMMM 'de' yyyy").string(from: day)
            guard let daily = data["daily"] as? [String: Any], let dates = daily["time"] as? [String], let index = dates.firstIndex(of: date), let units = data["daily_units"] as? [String: String] else { throw Failure.invalid }
            func value(_ key: String, _ unit: String, _ min: Double, _ max: Double) throws -> Double {
                guard units[key] == unit, let values = daily[key] as? [Any], values.indices.contains(index) else { throw Failure.invalid }
                return try Self.number(values[index], min: min, max: max)
            }
            let low = try value("temperature_2m_min", "°C", -100, 70), high = try value("temperature_2m_max", "°C", -100, 70), rain = try value("precipitation_probability_max", "%", 0, 100)
            guard low <= high else { throw Failure.invalid }
            if mean {
                guard let hourly = data["hourly"] as? [String: Any], let times = hourly["time"] as? [String], let values = hourly["temperature_2m"] as? [Any], (data["hourly_units"] as? [String: String])?["temperature_2m"] == "°C", times.count == values.count else { throw Failure.invalid }
                let indices = times.indices.filter { times[$0].hasPrefix(date + "T") }
                guard (23...25).contains(indices.count), Set(indices.map { times[$0] }).count == indices.count else { throw Failure.invalid }
                let temperatures = try indices.map { try Self.number(values[$0], min: -100, max: 70) }
                let average = temperatures.reduce(0, +) / Double(temperatures.count)
                return "Em \(label), para \(spoken), a temperatura média prevista é de \(String(format: "%.1f", average).replacingOccurrences(of: ".", with: ",")) graus Celsius, calculada a partir das temperaturas horárias da Open-Meteo. Mínima de \(Int(low.rounded())) e máxima de \(Int(high.rounded())) graus."
            }
            var speech = "Em \(label), para \(spoken), a previsão da Open-Meteo indica chance de chuva de até \(Int(rain.rounded())) por cento. Temperatura entre \(Int(low.rounded())) e \(Int(high.rounded())) graus Celsius."
            if let hourly = data["hourly"] as? [String: Any], let times = hourly["time"] as? [String], let values = hourly["precipitation_probability"] as? [Any], (data["hourly_units"] as? [String: String])?["precipitation_probability"] == "%", times.count == values.count {
                let candidates = times.indices.compactMap { i -> (String, Double)? in
                    guard times[i].hasPrefix(date + "T"), Self.matches(times[i], #"T(?:[01]\d|2[0-3]):00$"#), let probability = try? Self.number(values[i], min: 0, max: 100) else { return nil }
                    return (String(times[i].suffix(5)), probability)
                }
                if candidates.count >= 23, let peak = candidates.map({ $0.1 }).max(), peak > 0, let hour = candidates.first(where: { $0.1 == peak })?.0 {
                    speech += " A maior chance por hora é de \(Int(peak.rounded())) por cento, por volta de \(hour), no horário da cidade."
                }
            }
            return speech + " É uma previsão, não uma certeza de chuva."
        } catch { return "Não consegui confirmar a previsão para essa cidade e data agora. Tente novamente em instantes." }
    }
}
