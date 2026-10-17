import Foundation

/// Interpretation is proposed by the model; deductions are executed by XRLogic.
/// Grounding checks validate provenance, not the semantic truth of an extraction.
@MainActor final class XRMemoryReasoner {
    typealias Interpreter = @MainActor (String) async throws -> XRLogic.Plan
    private let interpret: Interpreter
    private var recent: [(text:String, answer:String, time:Date)] = []
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
    /// Dialogue is reference context only. It never becomes saved evidence.
    func observe(_ text:String, answer:String, document:XRMemoryDocument) {
        synchronize(document)
        guard text.count <= 2000, answer.count <= 2000 else { return }
        if recent.last?.text == text { recent.removeLast() }
        recent.append((text,answer,Date())); recent=Array(recent.suffix(4))
    }
    private func synchronize(_ document:XRMemoryDocument) {
        let identity = document.ownerID + "/" + document.revision
        if revision != identity { recent=[]; revision=identity }
        recent.removeAll { Date().timeIntervalSince($0.time)>120 }
    }
    func answer(_ text:String, document:XRMemoryDocument) async throws -> String? {
        try await resolve(text, document: document)?.answer
    }
    func resolve(_ text: String, document: XRMemoryDocument) async throws -> MemoryRecallEvidence? {
        guard !document.facts.isEmpty, text.count <= 2000 else { return nil }
        synchronize(document)
        let facts = document.facts.map { ["id":$0.key,"statement":$0.statement] }
        var payload:[String:Any] = ["question":text,"recent_questions":recent.map(\.text),
            "recent_exchanges":recent.map { ["question":$0.text,"answer":$0.answer] },"facts":facts]
        var plan = try await interpret(String(decoding:JSONSerialization.data(withJSONObject:payload),as:UTF8.self))
        let explicitEntity = document.facts.contains { fact in
            let subject = XRLogic.key(fact.subject)
            return !subject.isEmpty && XRLogic.key(text).contains(subject)
        }
        if Self.misaligned(plan) || (plan.intent == "ambiguous" && (explicitEntity || !recent.isEmpty)) {
            payload["repair"] = "Recheck whether the named entity or recent exchanges resolve the reference before marking it ambiguous. An answer in recent_exchanges may identify the subject/filter but is never evidence; cite only saved facts. The query and facts must agree about relation identifiers, argument count and order. Use exactly the same predicate signature in facts and query. Recheck argument order. Do not invent facts to satisfy the query."
            payload["previous_plan"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(plan))
            plan = try await interpret(String(decoding:JSONSerialization.data(withJSONObject:payload),as:UTF8.self))
            guard !Self.misaligned(plan) else { throw XRLogic.Failure.invalid }
        }
        try Task.checkCancellation()
        guard plan.intent != "unrelated" else { recent=[]; return nil }
        guard plan.intent == "query" else {
            return MemoryRecallEvidence(answer: "A qual pessoa, objeto ou relação você está se referindo?", sourceKeys: [], ownerID: document.ownerID, revision: document.revision)
        }
        let known = Dictionary(uniqueKeysWithValues:document.facts.map { ($0.key,$0.statement) })
        guard plan.facts.count <= 256, plan.facts.allSatisfy({ fact in
            guard let statement=known[fact.source] else { return false }
            return fact.terms.allSatisfy { term in
                term == "@user" || XRLogic.key(statement).contains(XRLogic.key(term))
            }
        }) else { throw XRLogic.Failure.invalid }
        // Explicit speaker exclusions are enforced even if interpretation omitted them.
        let normalized = XRLogic.key(text)
        let excludesSpeaker = normalized.range(of: #"\b(?:alem de mim|fora eu|exceto eu|besides me|other than me)\b"#, options:.regularExpression) != nil
        let query = XRLogic.Query(mode:plan.query.mode, clauses:plan.query.clauses,
            different:plan.query.different + (excludesSpeaker && plan.query.mode == "select" ? [.init(left:plan.query.select,right:"@user")] : []), select:plan.query.select)
        let result = try XRLogic.evaluate(query,facts:plan.facts)
        let answer = XRLogic.render(result,mode:plan.query.mode)
        observe(text,answer:answer,document:document)
        return MemoryRecallEvidence(answer: answer, sourceKeys: Array(Set(result.rows.flatMap(\.sources))).sorted(), ownerID: document.ownerID, revision: document.revision)
    }
}
