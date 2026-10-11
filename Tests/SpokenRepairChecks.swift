import Foundation

@main
struct SpokenRepairChecks {
    @MainActor
    static func main() async throws {
        let now = Date(timeIntervalSince1970: 1791732000)
        var symbols: [String] = []

        let lookup = NativePublicLookup(now: { now }) { url in
            if url.absoluteString.contains("/v8/finance/chart/") {
                let symbol = url.lastPathComponent
                symbols.append(symbol)
                return chart(symbol: symbol, now: now)
            }
            if url.absoluteString.contains("/v1/finance/search") {
                return ["quotes": []]
            }
            throw URLError(.badURL)
        }

        func expect(_ phrase: String, _ symbol: String) async {
            symbols.removeAll()
            let answer = await lookup.answer(phrase) ?? ""
            precondition(symbols.last == symbol, "\(phrase) routed to \(symbols), expected \(symbol)")
            precondition(answer.contains(symbol), "\(phrase) answer did not mention \(symbol): \(answer)")
        }

        await expect("Qual a cotação da PETR quatro?", "PETR4.SA")
        await expect("Quanto está VALE três?", "VALE3.SA")
        await expect("Cotação da ITUB quatro", "ITUB4.SA")
        await expect("Preço do Banco do Brasil", "BBAS3.SA")
        await expect("Valor da Petrobras PN", "PETR4.SA")
        await expect("Valor da Petrobras ON", "PETR3.SA")
        await expect("Cotação da Magazine Luiza", "MGLU3.SA")
        await expect("Preço da Ambev", "ABEV3.SA")

        symbols.removeAll()
        let unrelated = await lookup.answer("Quanto vale três maçãs?")
        precondition(unrelated == nil && symbols.isEmpty, "Unrelated phrase must not route to stock quote: \(symbols)")

        print("PASS: spoken ticker repair")
    }

    static func chart(symbol: String, now: Date) -> [String: Any] {
        [
            "chart": [
                "error": NSNull(),
                "result": [[
                    "meta": [
                        "symbol": symbol,
                        "regularMarketPrice": NSNumber(value: 42.15),
                        "regularMarketTime": NSNumber(value: now.timeIntervalSince1970),
                        "currency": symbol.hasPrefix("^") ? "BRL" : "BRL",
                        "instrumentType": "EQUITY"
                    ]
                ]]
            ]
        ]
    }
}
