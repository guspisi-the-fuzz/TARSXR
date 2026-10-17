import Foundation

@main struct XRMemoryReasonerChecks {
    @MainActor static func main() async throws {
        let source=XRMemoryFact(key:"f1",subject:"entity-a",statement:"entity-a lives with entity-b",source:"user",scope:"xr",createdAt:0,updatedAt:0)
        let doc=XRMemoryDocument(schemaVersion:1,ownerID:"synthetic",revision:"r1",facts:[source],forgotten:[])
        let query=XRLogic.Query(mode:"select",clauses:[.init(relation:"lives",terms:["?x","entity-b"],negative:false)],different:[],select:"?x")
        var mode="valid"
        var receivedHistory=[Int]()
        let reasoner=XRMemoryReasoner { payload in
            let json=try JSONSerialization.jsonObject(with:Data(payload.utf8)) as! [String:Any]
            receivedHistory.append((json["recent_questions"] as! [String]).count)
            return XRLogic.Plan(intent:mode == "unrelated" ? "unrelated" : "query",
                facts:[.init(relation:"lives",terms:[mode == "invented" ? "phantom" : "entity-a","entity-b"],negative:false,source:mode == "bad-source" ? "absent" : "f1")],query:query)
        }
        let first=try await reasoner.answer("Who lives with entity-b?",document:doc)
        precondition(first == "Pelos fatos registrados: entity-a.")
        _=try await reasoner.answer("Who else?",document:doc)
        precondition(receivedHistory == [0,1])
        for invalid in ["invented","bad-source"] {
            mode=invalid
            do { _=try await reasoner.answer("Who?",document:doc);preconditionFailure() } catch XRLogic.Failure.invalid {}
        }
        mode="unrelated"
        let skipped=try await reasoner.answer("Play music",document:doc)
        precondition(skipped == nil)
        mode="valid"
        _=try await reasoner.answer("Who?",document:doc)
        precondition(receivedHistory.last == 0)
        var revised=doc;revised.revision="r2"
        _=try await reasoner.answer("Who?",document:revised)
        precondition(receivedHistory.last == 0)
        var repairCalls=0
        let repair=XRMemoryReasoner { _ in
            repairCalls += 1
            let terms = repairCalls == 1 ? ["entity-b","?x"] : ["?x","entity-b"]
            return XRLogic.Plan(intent:"query",facts:[.init(relation:"lives",terms:["entity-a","entity-b"],negative:false,source:"f1")],
                query:.init(mode:"select",clauses:[.init(relation:"lives",terms:terms,negative:false)],different:[],select:"?x"))
        }
        let repaired=try await repair.answer("Who?",document:doc)
        precondition(repaired?.contains("entity-a") == true && repairCalls == 2)
        var badCalls=0
        let bad=XRMemoryReasoner { _ in
            badCalls += 1
            return XRLogic.Plan(intent:"query",facts:[.init(relation:"lives",terms:["entity-a","entity-b"],negative:false,source:"f1")],
                query:.init(mode:"select",clauses:[.init(relation:"lives",terms:["entity-b","?x"],negative:false)],different:[],select:"?x"))
        }
        do { _=try await bad.answer("Who?",document:doc);preconditionFailure() } catch XRLogic.Failure.invalid {}
        precondition(badCalls == 2)
        var predicateCalls=0
        let predicateRepair=XRMemoryReasoner { _ in
            predicateCalls += 1
            return XRLogic.Plan(intent:"query",facts:[.init(relation:"lives",terms:["entity-a","entity-b"],negative:false,source:"f1")],
                query:.init(mode:"select",clauses:[.init(relation:predicateCalls == 1 ? "resides" : "lives",terms:["?x","entity-b"],negative:false)],different:[],select:"?x"))
        }
        let predicateResult=try await predicateRepair.answer("Who?",document:doc)
        precondition(predicateCalls == 2 && predicateResult?.contains("entity-a") == true)
        var ambiguousCalls=0
        let clarify=XRMemoryReasoner { payload in
            ambiguousCalls += 1
            let json=try JSONSerialization.jsonObject(with:Data(payload.utf8)) as! [String:Any]
            let exchanges=json["recent_exchanges"] as! [[String:String]]
            precondition(exchanges.first?["answer"] == "entity-a lives with entity-b")
            return XRLogic.Plan(intent:ambiguousCalls==1 ? "ambiguous" : "query",facts:[.init(relation:"lives",terms:["entity-a","entity-b"],negative:false,source:"f1")],query:query)
        }
        clarify.observe("Who is entity-a?",answer:"entity-a lives with entity-b",document:doc)
        let clarified=try await clarify.answer("Who lives there?",document:doc)
        precondition(ambiguousCalls==2 && clarified?.contains("entity-a")==true)
        let evidence = try await reasoner.resolve("Who lives with entity-b?", document: doc)
        precondition(evidence?.sourceKeys == ["f1"] && evidence?.ownerID == doc.ownerID && evidence?.revision == doc.revision)
        precondition(evidence?.answer == first)
        precondition(doc.facts == [source])
        print("PASS: synthetic interpreter contract, cited sources, invented-entity rejection, context isolation/revision reset; no writes or API")
    }
}
