import Foundation

/// Interpretation is proposed by the model; deductions are executed by XRLogic.
/// Grounding checks validate provenance, not the semantic truth of an extraction.
@MainActor final class XRMemoryReasoner {
    typealias Interpreter = @MainActor (String) async throws -> XRLogic.Plan
    private let interpret: Interpreter
    private var recent: [(text:String, time:Date)] = []
    private var revision: String?
    init(interpret:@escaping Interpreter) { self.interpret=interpret }
    private static func misaligned(_ plan:XRLogic.Plan) -> Bool {
        guard plan.intent == "query" else { return false }
        for atom in plan.query.clauses {
            let sameRelation = plan.facts.filter { XRLogic.key($0.relation) == XRLogic.key(atom.relation) }
            if sameRelation.isEmpty && !plan.facts.isEmpty { return true }
            if sameRelation.contains(where: { $0.terms.count != atom.terms.count }) { return true }
            let matching = sameRelation
            for (index,term) in atom.terms.enumerated() where !term.hasPrefix("?") {
                if !matching.contains(where:{ XRLogic.key($0.terms[index]) == XRLogic.key(term) }),
                   matching.contains(where:{ $0.terms.contains { XRLogic.key($0) == XRLogic.key(term) } }) { return true }
            }
        }
        return false
    }
    func answer(_ text:String, document:XRMemoryDocument) async throws -> String? {
        guard !document.facts.isEmpty, text.count <= 2000 else { return nil }
        let identity = document.ownerID + "/" + document.revision
        if revision != identity { recent=[]; revision=identity }
        recent.removeAll { Date().timeIntervalSince($0.time)>120 }
        let facts = document.facts.map { ["id":$0.key,"statement":$0.statement] }
        var payload:[String:Any] = ["question":text,"recent_questions":recent.suffix(4).map(\.text),"facts":facts]
        var plan = try await interpret(String(decoding:JSONSerialization.data(withJSONObject:payload),as:UTF8.self))
        if Self.misaligned(plan) {
            payload["repair"] = "The query and facts disagree about relation identifiers, argument count or order. Use exactly the same predicate signature in facts and query. Recheck argument order. Do not invent facts to satisfy the query."
            payload["previous_plan"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(plan))
            plan = try await interpret(String(decoding:JSONSerialization.data(withJSONObject:payload),as:UTF8.self))
            guard !Self.misaligned(plan) else { throw XRLogic.Failure.invalid }
        }
        try Task.checkCancellation()
        guard plan.intent != "unrelated" else { recent=[]; return nil }
        guard plan.intent == "query" else { return "A qual pessoa, objeto ou relação você está se referindo?" }
        let known = Dictionary(uniqueKeysWithValues:document.facts.map { ($0.key,$0.statement) })
        guard plan.facts.count <= 256, plan.facts.allSatisfy({ fact in
            guard let statement=known[fact.source] else { return false }
            return fact.terms.allSatisfy { term in
                term == "@user" || XRLogic.key(statement).contains(XRLogic.key(term))
            }
        }) else { throw XRLogic.Failure.invalid }
        let result = try XRLogic.evaluate(plan.query,facts:plan.facts)
        recent.append((text,Date())); recent=Array(recent.suffix(4))
        return XRLogic.render(result,mode:plan.query.mode)
    }
}
