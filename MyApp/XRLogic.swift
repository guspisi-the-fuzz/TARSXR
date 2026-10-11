import Foundation

/// Small, bounded relational evaluator. No names, network, writes or action authority.
enum XRLogic {
    struct Fact: Codable, Equatable {
        let relation: String
        let terms: [String]
        let negative: Bool
        let source: String
    }
    struct Atom: Codable { let relation: String; let terms: [String]; let negative: Bool }
    struct Difference: Codable { let left: String; let right: String }
    struct Query: Codable {
        let mode: String // select, count, exists
        let clauses: [Atom]
        let different: [Difference]
        let select: String
    }
    struct Plan: Codable {
        let intent: String // query, unrelated, ambiguous
        let facts: [Fact]
        let query: Query
    }
    struct Row: Equatable { let value: String; let sources: [String] }
    struct Result: Equatable {
        enum Status { case supported, unknown, contradiction }
        let status: Status
        let rows: [Row]
    }
    enum Failure: Error { case invalid, limit }
    private struct Binding { var values: [String:String]; var sources: Set<String>; var conflict = false }
    private struct Signature: Hashable { let relation:String; let terms:[String] }
    static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive,.diacriticInsensitive], locale:Locale(identifier:"pt_BR"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator:" ")
    }
    private static func variable(_ s:String) -> Bool { s.hasPrefix("?") }
    private static func resolve(_ s:String, _ values:[String:String]) -> String? {
        variable(s) ? values[s] : s
    }
    /// An absent fact is unknown, never false. Every result retains source IDs.
    static func evaluate(_ query:Query, facts:[Fact]) throws -> Result {
        guard facts.count <= 256, (1...6).contains(query.clauses.count),
              query.different.count <= 8, ["select","count","exists"].contains(query.mode) else { throw Failure.invalid }
        let atoms = query.clauses + facts.map { Atom(relation:$0.relation,terms:$0.terms,negative:$0.negative) }
        guard atoms.allSatisfy({ !$0.relation.isEmpty && $0.relation.count <= 60 && (1...3).contains($0.terms.count) && $0.terms.allSatisfy { !$0.isEmpty && $0.count <= 120 } }),
              facts.allSatisfy({ !$0.source.isEmpty && !$0.terms.contains(where:variable) }) else { throw Failure.invalid }
        let variables = Set(query.clauses.flatMap(\.terms).filter(variable))
        guard query.mode == "exists" || variables.contains(query.select),
              query.different.allSatisfy({ (!variable($0.left) || variables.contains($0.left)) && (!variable($0.right) || variables.contains($0.right)) }) else { throw Failure.invalid }
        var bindings = [Binding(values:[:],sources:[])]
        func signature(_ f:Fact) -> Signature { Signature(relation:key(f.relation),terms:f.terms.map(key)) }
        let positives = Set(facts.filter { !$0.negative }.map(signature))
        let negatives = Set(facts.filter(\.negative).map(signature))
        let conflicts = positives.intersection(negatives)
        for clause in query.clauses {
            var next = [Binding]()
            for binding in bindings {
                for fact in facts where key(fact.relation) == key(clause.relation) && fact.terms.count == clause.terms.count && fact.negative == clause.negative {
                    var candidate = binding
                    var matches = true
                    for (term,value) in zip(clause.terms,fact.terms) {
                        if let existing = resolve(term,candidate.values) {
                            if key(existing) != key(value) { matches = false; break }
                        } else { candidate.values[term] = value }
                    }
                    guard matches else { continue }
                    // Never silently select a side of inconsistent premises.
                    if conflicts.contains(signature(fact)) { candidate.conflict = true }
                    candidate.sources.insert(fact.source); next.append(candidate)
                    guard next.count <= 2048 else { throw Failure.limit }
                }
            }
            bindings = next
        }
        bindings = bindings.filter { b in query.different.allSatisfy {
            guard let a=resolve($0.left,b.values), let c=resolve($0.right,b.values) else { return false }
            return key(a) != key(c)
        }}
        if bindings.contains(where: \.conflict) { return Result(status:.contradiction,rows:[]) }
        guard !bindings.isEmpty else { return Result(status:.unknown,rows:[]) }
        var rows = [String:Row]()
        for binding in bindings {
            let value = query.mode == "exists" ? "confirmado" : binding.values[query.select]!
            let id = key(value), previous = rows[id]?.sources ?? []
            rows[id] = Row(value:rows[id]?.value ?? value, sources:Array(Set(previous).union(binding.sources)).sorted())
        }
        return Result(status:.supported,rows:rows.values.sorted { key($0.value) < key($1.value) })
    }
    static func render(_ result:Result, mode:String) -> String {
        switch result.status {
        case .unknown: return "Os fatos disponíveis não são suficientes para concluir isso."
        case .contradiction: return "Há informações contraditórias na memória. Preciso esclarecer isso antes de concluir."
        case .supported:
            if mode == "count" { return "Encontrei \(result.rows.count) nos fatos registrados. Isso não garante que o registro esteja completo." }
            if mode == "exists" { return "Sim, essa conclusão é sustentada pelos fatos registrados." }
            return "Pelos fatos registrados: " + result.rows.map { $0.value == "@user" ? "você" : $0.value }.joined(separator:", ") + "."
        }
    }
}
