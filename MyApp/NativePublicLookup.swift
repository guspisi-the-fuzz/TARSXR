import Foundation
import CoreFoundation

@MainActor final class NativePublicLookup {
    private let fetch: NativeWeatherLookup.Fetch
    private let now: () -> Date
    private var pendingTeam: (query:String, deadline:Date)?
    private var lastSports: Date?
    init(now:@escaping () -> Date = Date.init, fetch:@escaping NativeWeatherLookup.Fetch = NativeWeatherLookup.fetchJSON) { self.now=now; self.fetch=fetch }
    static let teams:[String:(String,String)] = ["athletico pr":("3458","Athletico-PR"),
"atletico mg":("7632","Atlético-MG"),
"bahia":("9967","Bahia"),
"botafogo":("6086","Botafogo"),
"chapecoense":("9318","Chapecoense"),
"corinthians":("874","Corinthians"),
"coritiba":("3456","Coritiba"),
"cruzeiro":("2022","Cruzeiro"),
"flamengo":("819","Flamengo"),
"fluminense":("3445","Fluminense"),
"gremio":("6273","Grêmio"),
"internacional":("1936","Internacional"),
"mirassol":("9169","Mirassol"),
"palmeiras":("2029","Palmeiras"),
"bragantino":("6079","Red Bull Bragantino"),
"remo":("4936","Remo"),
"santos":("2674","Santos"),
"sao paulo":("2026","São Paulo"),
"vasco":("3454","Vasco da Gama"),
"vitoria":("3457","Vitória")]
    static let aliases:[String:String] = ["atletico mineiro":"atletico mg","galo":"atletico mg","athletico paranaense":"athletico pr","atletico paranaense":"athletico pr","red bull bragantino":"bragantino","vasco da gama":"vasco"]
    private func match(_ text:String,_ regex:String)->Bool { NativeWeatherLookup.matches(text,regex) }
    private func date(_ format:String)->DateFormatter { let f=DateFormatter(); f.locale=Locale(identifier:"pt_BR"); f.timeZone = .current; f.dateFormat=format; f.isLenient=false; return f }
    private func number(_ value:Any?) -> Double? { guard let v=value as? NSNumber,CFGetTypeID(v) != CFBooleanGetTypeID(),v.doubleValue.isFinite else {return nil}; return v.doubleValue }
    private func url(_ base:String,_ values:[String:String])->URL { var c=URLComponents(string:base)!;c.queryItems=values.map { URLQueryItem(name:$0.key,value:$0.value) };return c.url! }
    func answer(_ raw:String) async -> String? {
        var text=SpokenRequest.clean(raw)
        let repairedTicker = Self.spokenTicker(in: text)
        if let repairedTicker {
            let plain = repairedTicker.replacingOccurrences(of: ".SA", with: "")
            if !text.uppercased().contains(plain) {
                text += " " + plain
            }
        }
        var n=NativeWeatherLookup.normalize(text)
        if let last = lastSports, now().timeIntervalSince(last) < 120,
           match(n, #"\b(espn|fonte|fontes)\b"#) {
            return "Para a agenda de futebol, esta versão consulta apenas a ESPN. Uma busca sem resultado não prova que não haverá jogo."
        }
        if let pending = pendingTeam, pending.deadline > now(),
           Self.teams[n.trimmingCharacters(in:CharacterSet(charactersIn:" ?!."))] != nil {
            text = pending.query + " " + text
            n = NativeWeatherLookup.normalize(text)
        } else { pendingTeam = nil }
        if match(n,#"\b(toca|toque|play|musica|comprar|compre|vender|venda|invista)\b"#) { return nil }
        let hasTicker = repairedTicker != nil || match(text,#"(?i)\b[A-Z]{4}\s?\d{1,2}(?:\.SA)?\b"#)
        if match(n,#"\b(cotacao|acoes|acao|stocks|ticker|bolsa)\b"#)
            || (match(n,#"\b(dolar|euro|bitcoin|ethereum|ibovespa)\b"#) && match(n,#"\b(quanto|preco|valor|vale|esta|ta)\b"#))
            || (hasTicker && match(n,#"\b(cotacao|preco|valor|acoes|acao|stocks|ticker|bolsa|esta|ta)\b"#)) {
            return await quote(text,n)
        }
        if match(n,#"\b(joga|jogam|jogo|jogos|partida|partidas|enfrenta)\b"#) { return await schedule(text,n) }
        return nil
    }
    private static func spokenTicker(in raw:String) -> String? {
        let n = NativeWeatherLookup.normalize(SpokenRequest.clean(raw))
        let rules: [(String,String)] = [
            (#"\bp\s*e\s*t\s*r\s*(?:4|quatro)\b"#, "PETR4"),
            (#"\bpetr\s*(?:4|quatro)\b"#, "PETR4"),
            (#"\bpetrobras\s*(?:pn|preferencial|4|quatro)\b"#, "PETR4"),
            (#"\bpetrobras\s*(?:on|ordinaria|ordinarias|3|tres)\b"#, "PETR3"),

            (#"\bv\s*a\s*l\s*e\s*(?:3|tres)\b"#, "VALE3"),
            (#"\bvale\s*(?:3|tres)\b"#, "VALE3"),

            (#"\bi\s*t\s*u\s*b\s*(?:4|quatro)\b"#, "ITUB4"),
            (#"\bitub\s*(?:4|quatro)\b"#, "ITUB4"),
            (#"\bitau\s*(?:unibanco)?\s*(?:pn|preferencial|4|quatro)?\b"#, "ITUB4"),

            (#"\bb\s*b\s*a\s*s\s*(?:3|tres)\b"#, "BBAS3"),
            (#"\bbbas\s*(?:3|tres)\b"#, "BBAS3"),
            (#"\bbanco do brasil\b"#, "BBAS3"),

            (#"\bb\s*b\s*d\s*c\s*(?:4|quatro)\b"#, "BBDC4"),
            (#"\bbbdc\s*(?:4|quatro)\b"#, "BBDC4"),
            (#"\bbradesco\s*(?:pn|preferencial|4|quatro)?\b"#, "BBDC4"),

            (#"\bw\s*e\s*g\s*e\s*(?:3|tres)\b"#, "WEGE3"),
            (#"\bwege\s*(?:3|tres)\b"#, "WEGE3"),
            (#"\bweg\b"#, "WEGE3"),

            (#"\bm\s*g\s*l\s*u\s*(?:3|tres)\b"#, "MGLU3"),
            (#"\bmglu\s*(?:3|tres)\b"#, "MGLU3"),
            (#"\bmagalu\b"#, "MGLU3"),
            (#"\bmagazine luiza\b"#, "MGLU3"),

            (#"\ba\s*b\s*e\s*v\s*(?:3|tres)\b"#, "ABEV3"),
            (#"\babev\s*(?:3|tres)\b"#, "ABEV3"),
            (#"\bambev\b"#, "ABEV3"),

            (#"\bi\s*t\s*s\s*a\s*(?:4|quatro)\b"#, "ITSA4"),
            (#"\bitsa\s*(?:4|quatro)\b"#, "ITSA4")
        ]
        for (pattern, symbol) in rules {
            if NativeWeatherLookup.matches(n, pattern) { return symbol }
        }
        return nil
    }

    private func quote(_ text:String,_ n:String) async -> String {
        if match(n,#"\b(ontem|amanha|semana|mes|historico)\b"#) { return "Por enquanto consulto a última cotação disponível. Qual ativo você quer?" }
        let regex=try! NSRegularExpression(pattern:#"\b[A-Za-z]{4}\s?\d{1,2}(?:\.SA)?\b"#,options:.caseInsensitive)
        let b3=regex.matches(in:text,range:NSRange(text.startIndex...,in:text)).compactMap { Range($0.range,in:text).map { String(text[$0]).uppercased().replacingOccurrences(of:" ",with:"").replacingOccurrences(of:".SA",with:"")+".SA" } }
        let aliases=["dolar":"USDBRL=X","euro":"EURBRL=X","bitcoin":"BTC-USD","ethereum":"ETH-USD","ibovespa":"^BVSP","apple":"AAPL","microsoft":"MSFT"]
        var choices=Set(b3)
        if choices.isEmpty { choices=Set(aliases.filter { match(n,"\\b"+$0.key+"\\b") }.map(\.value)) }
        if choices.count>1 { return "Diga um ativo de cada vez, como PETR4 ou AAPL." }
        var symbol=choices.first ?? ""
        if symbol.isEmpty {
            let r=try! NSRegularExpression(pattern:#"\b[A-Z]{1,5}(?:\.[A-Z]{1,3})?\b"#)
            let candidates=r.matches(in:text,range:NSRange(text.startIndex...,in:text)).compactMap { Range($0.range,in:text).map { String(text[$0]) } }.filter { !["TARS","USD","BRL","EUR"].contains($0) }
            if candidates.count==1 { symbol=candidates[0] }
        }
        do {
            if symbol.isEmpty {
                let target=n.replacingOccurrences(of:#"^(?:(?:qual|quanto|como|me|mostre|mostra|consulte|consulta|pesquisa|veja|ve|o|a|as|os|e|esta|estao|ta|hoje|agora|cotacao|preco|valor|das|dos|da|do|de|acoes|acao|bolsa|stocks|ticker)\s+)+"#,with:"",options:.regularExpression).trimmingCharacters(in:CharacterSet(charactersIn:" ?!."))
                guard (2...60).contains(target.count) else { return "Qual ativo você quer consultar? Diga um código, como PETR4 ou AAPL." }
                let search=try await fetch(url("https://query1.finance.yahoo.com/v1/finance/search",["q":target,"quotesCount":"8","newsCount":"0"]))
                let found=Set((search["quotes"] as? [[String:Any]] ?? []).filter { ["EQUITY","ETF","INDEX","CRYPTOCURRENCY"].contains($0["quoteType"] as? String ?? "") }.compactMap { $0["symbol"] as? String }.filter { match($0,#"^[A-Z^][A-Z0-9.=-]{0,19}$"#) })
                guard found.count==1 else { return "Preciso do código para não consultar o ativo errado. Diga, por exemplo, PETR4 ou AAPL." }; symbol=found.first!
            }
            let endpoint=URL(string:"https://query1.finance.yahoo.com/v8/finance/chart")!.appendingPathComponent(symbol)
            let data=try await fetch(url(endpoint.absoluteString,["interval":"1d","range":"5d"]))
            guard let chart=data["chart"] as? [String:Any], chart["error"] == nil || chart["error"] is NSNull,
                  let result=(chart["result"] as? [[String:Any]])?.first, let meta=result["meta"] as? [String:Any],
                  (meta["symbol"] as? String)?.uppercased()==symbol.uppercased(), let price=number(meta["regularMarketPrice"]), price>0,
                  let stamp=number(meta["regularMarketTime"]), stamp>0, stamp-now().timeIntervalSince1970<=300 else { throw NativeWeatherLookup.Failure.invalid }
            let currencies=["BRL":"reais","USD":"dólares americanos","EUR":"euros","GBP":"libras esterlinas","JPY":"ienes"]
            guard let currency=currencies[meta["currency"] as? String ?? ""] else { throw NativeWeatherLookup.Failure.invalid }
            let unit=meta["instrumentType"] as? String == "INDEX" ? "pontos" : currency
            let amount=String(format:symbol.hasSuffix("=X") ? "%.4f" : "%.2f",price).replacingOccurrences(of:".",with:",")
            let observed=Date(timeIntervalSince1970:stamp)
            let stale=now().timeIntervalSince(observed)>604800 ? " O registro tem mais de sete dias e pode estar desatualizado." : ""
            return "A última cotação disponível de \(symbol), no Yahoo Finance, é \(amount) \(unit). Registro de \(date("d 'de' MMMM 'de' yyyy 'às' HH:mm").string(from:observed)), no horário do aparelho. A cotação pode ter atraso."+stale
        } catch { return "Não consegui confirmar a cotação desse ativo agora. Tente novamente em instantes." }
    }
    private func kickoffDate(_ stamp:String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let parsed = iso.date(from:stamp) { return parsed }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = iso.date(from:stamp) { return parsed }
        // ESPN also emits UTC timestamps with minute precision.
        if match(stamp, #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}Z$"#) {
            return ISO8601DateFormatter().date(from:String(stamp.dropLast()) + ":00Z")
        }
        return nil
    }
    private func schedule(_ text:String,_ input:String) async -> String {
        lastSports = now()
        var n=input
        for (alias,canonical) in Self.aliases.sorted(by:{$0.key.count>$1.key.count}) { n=n.replacingOccurrences(of:"\\b"+alias+"\\b",with:canonical,options:.regularExpression) }
        let teams=Self.teams.filter { match(n,"\\b"+$0.key+"\\b") }
        guard teams.count==1,let team=teams.first?.value else {
            pendingTeam = (text, now().addingTimeInterval(120))
            return "Ainda não consulto uma lista geral de jogos. De qual time você quer consultar a agenda?"
        }
        pendingTeam = nil
        if match(n,#"\b(sub|feminino|placar|resultado)\b"#) { return "Essa consulta cobre a agenda masculina principal. Não confirmei esse resultado ou categoria." }
        let today=Calendar.current.startOfDay(for:now())
        var target:Date? = match(n,#"\bhoje\b"#) ? today : n.contains("amanha") ? Calendar.current.date(byAdding:.day,value:1,to:today) : n.contains("ontem") ? Calendar.current.date(byAdding:.day,value:-1,to:today) : nil
        let pattern=#"(?<!\d)\d{1,2}/\d{1,2}(?:/\d{4})?(?!\d)"#
        if let range=text.range(of:pattern,options:.regularExpression) {
            let value=String(text[range]); target=date("d/M/yyyy").date(from:value.split(separator:"/").count==3 ? value : value+"/"+date("yyyy").string(from:now()))
            if target==nil { return "Essa data não existe. Qual dia você quer consultar?" }
        } else if let range=n.range(of:#"\b\d{1,2} de (?:janeiro|fevereiro|marco|abril|maio|junho|julho|agosto|setembro|outubro|novembro|dezembro)(?: de \d{4})?\b"#,options:.regularExpression) {
            var value=String(n[range]).replacingOccurrences(of:"marco",with:"março")
            if !match(value,#"\d{4}$"#) { value += " de "+date("yyyy").string(from:now()) }
            target=date("d 'de' MMMM 'de' yyyy").date(from:value)
            if target==nil { return "Essa data não existe. Qual dia você quer consultar?" }
        }
        do {
            let data=try await fetch(url("https://site.api.espn.com/apis/site/v2/sports/soccer/all/teams/\(team.0)/schedule",["fixture":"true","season":date("yyyy").string(from:target ?? now())]))
            guard data["status"] as? String == "success", (data["team"] as? [String:Any])?["id"] as? String == team.0 else { throw NativeWeatherLookup.Failure.invalid }
            var fixtures=[(Date,String,Bool)]()
            for event in data["events"] as? [[String:Any]] ?? [] {
                guard let competition=(event["competitions"] as? [[String:Any]])?.first, let status=(competition["status"] as? [String:Any])?["type"] as? [String:Any], status["name"] as? String == "STATUS_SCHEDULED", status["completed"] as? Bool != true,
                      let stamp=event["date"] as? String, let kickoff=kickoffDate(stamp),
                      let competitors=competition["competitors"] as? [[String:Any]], competitors.count==2 else { continue }
                let clubs=competitors.compactMap { $0["team"] as? [String:Any] }
                guard clubs.contains(where:{$0["id"] as? String == team.0}), let opponent=clubs.first(where:{$0["id"] as? String != team.0})?["displayName"] as? String else { continue }
                if let target { guard Calendar.current.isDate(kickoff,inSameDayAs:target) else {continue} } else if kickoff<=now() {continue}
                fixtures.append((kickoff,opponent,event["timeValid"] as? Bool == true && competition["timeValid"] as? Bool == true))
            }
            guard let fixture=fixtures.sorted(by:{$0.0<$1.0}).first else { return target == nil ? "A agenda da ESPN não retornou o próximo jogo confirmado do \(team.1). Isso não significa que não haja partida marcada." : "Não encontrei uma partida confirmada do \(team.1) para a data consultada na agenda da ESPN. Isso não confirma ausência de jogo." }
            let hour=fixture.2 ? " às "+date("HH:mm").string(from:fixture.0) : ", ainda sem horário confirmado"
            return "Segundo a agenda da ESPN, \(target == nil ? "o próximo jogo do" : "o") \(team.1) \(target == nil ? "é" : "joga") contra \(fixture.1), em \(date("d 'de' MMMM 'de' yyyy").string(from:fixture.0))\(hour), no horário do aparelho."
        } catch { return "Não consegui confirmar a agenda desse time agora." }
    }
}
