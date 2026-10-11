import Foundation

@MainActor final class UnavailableMac: TARSRuntime {
    var conversations = 0
    func hud() async throws -> HUDSnapshot { throw TARSClientError.unavailable }
    func command(_ action: String, params: TARSCommandParameters?) async throws -> TARSCommandReply { throw TARSClientError.unavailable }
    func telemetry() async throws -> TARSTelemetry { throw TARSClientError.unavailable }
    func recover() async throws { throw TARSClientError.unavailable }
    func describeImage(png: Data, source: String, question: String, history: [[String: String]]) async throws -> VisionReply { throw TARSClientError.unavailable }
    func transcribe(data: Data) async throws -> String { throw TARSClientError.unavailable }
    func synthesize(text: String) async throws -> Data { throw TARSClientError.unavailable }
    func converse(text: String, language: String, context: [String: Any]?) async throws -> String { conversations += 1; throw TARSClientError.unavailable }
    func streamSpeech(text: String, receive: @escaping @MainActor (Data) throws -> Void) async throws { throw TARSClientError.unavailable }
    func streamConversation(text: String, receive: @escaping @MainActor (Data) throws -> Void, receiveText: @escaping @MainActor (String) -> Void) async throws { throw TARSClientError.unavailable }
}
@main struct NativeWeatherChecks {
    @MainActor static func main() async throws {
        let zone = TimeZone(identifier: "America/Sao_Paulo")!
        let clock = ISO8601DateFormatter().date(from: "2026-10-08T15:00:00Z")!
        var stamp = clock
        var calls = [URL]()
        var invalid = false
        var currentTime = "2026-10-08T12:00"
        let service = NativeWeatherLookup(now: { stamp }, zone: zone) { url in
            calls.append(url)
            if invalid { throw NativeWeatherLookup.Failure.invalid }
            if url.host == "geocoding-api.open-meteo.com" {
                let name = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "name" }!.value!
                return ["results": [["name": name, "admin1": "São Paulo", "latitude": -21.0, "longitude": -47.0, "timezone": zone.identifier]]]
            }
            return ["timezone": zone.identifier,
                    "current": ["time":currentTime, "temperature_2m":22.5], "current_units":["temperature_2m":"°C"],
                    "daily": ["time":["2026-10-08","2026-10-09"], "temperature_2m_min":[17,17], "temperature_2m_max":[30,30], "precipitation_probability_max":[32,32]],
                    "daily_units":["temperature_2m_min":"°C", "temperature_2m_max":"°C", "precipitation_probability_max":"%"],
                    "hourly": ["time": (0..<24).map { String(format: "2026-10-09T%02d:00", $0) }, "temperature_2m": Array(repeating: 24.0, count:24), "precipitation_probability":Array(repeating:32, count:24)],
                    "hourly_units":["temperature_2m":"°C","precipitation_probability":"%"]]
        }
        precondition(NativeWeatherLookup.location("Ribeirão Preto estado de São Paulo").0 == "Ribeirão Preto")
        precondition(NativeWeatherLookup.location("Americana, SP").1 == "São Paulo")
        let mac = UnavailableMac()
        let runtime = MigratingTARSRuntime(remaining: mac, weather: service)
        let average = try await runtime.converse(text: "Qual a temperatura média amanhã em Altinópolis, estado de São Paulo?", language:"pt-BR", context:nil)
        precondition(average.contains("24,0") && average.contains("9 de outubro") && mac.conversations == 0)
        let current = await service.answer("Qual a temperatura em Ribeirão Preto agora?")!
        precondition(current.contains("22,5") && current.contains("Ribeirão Preto"))
        _ = await service.answer("Never mind")
        let query = await service.answer("Vai chover amanhã?")!
        precondition(query.contains("Em qual cidade"))
        let followup = await service.answer("Americana, São Paulo")!
        precondition(followup.contains("32 por cento") && followup.contains("9 de outubro") && followup.contains("maior chance por hora"))
        let switched = await service.answer("E em Americana, no estado de São Paulo?")!
        precondition(switched.contains("Americana") && switched.contains("9 de outubro"))
        let there = await service.answer("Qual vai ser a temperatura média amanhã lá?")!
        precondition(there.contains("Americana") && there.contains("24,0"))
        _ = await service.answer("Never mind")
        _ = await service.answer("Vai chover amanhã?")
        let beforeCancel = calls.count
        let cancel = await service.answer("Never mind")
        precondition(cancel == nil && calls.count == beforeCancel)
        for unrelated in ["Can you move forward?", "Você consegue andar pra frente?", "Estou falando do ESP32", "Stop", "Para"] {
            _ = await service.answer("Vai chover amanhã?")
            let before = calls.count
            let answer = await service.answer(unrelated)
            precondition(answer == nil && calls.count == before)
        }
        let dated = await service.answer("Vai chover em Americana, SP no dia 9/10?")!
        precondition(dated.contains("9 de outubro"))
        let impossible = await service.answer("Vai chover em Americana em 31/02?")!
        precondition(impossible.contains("não existe"))
        let music = await service.answer("Toca Chuva de Prata")
        precondition(music == nil)
        currentTime = "2026-10-07T12:00"
        let stale = await service.answer("Temperatura em Americana agora")!
        precondition(stale.contains("Não consegui confirmar"))
        invalid = true
        let failed = try await runtime.converse(text:"Vai chover amanhã em Americana?", language:"pt", context:nil)
        precondition(failed.contains("Não consegui confirmar") && mac.conversations == 0)
        _ = await service.answer("Never mind")
        _ = await service.answer("Vai chover amanhã?")
        stamp = clock.addingTimeInterval(121)
        let expired = await service.answer("Americana, SP")
        precondition(expired == nil)
        do { _ = try await runtime.command("MOVE", params:nil); preconditionFailure() } catch TARSClientError.unavailable {}
        do { _ = try await runtime.converse(text:"Quem é a Daniela?", language:"pt", context:nil); preconditionFailure() } catch TARSClientError.unavailable {}
        precondition(mac.conversations == 1)
        precondition(calls.allSatisfy { $0.scheme == "https" && ["api.open-meteo.com","geocoding-api.open-meteo.com"].contains($0.host!) })
        print("PASS: native weather, real hourly mean, current/stale values, dates, city clarification/expiry, no remote Core lookup, unchanged motion delegation")
    }
}
