import Foundation

@main struct XRLogicChecks {
    static func main() throws {
        var checks = 0
        func check(_ value:Bool) { precondition(value); checks += 1 }
        func fact(_ r:String,_ t:[String],_ source:String,_ negative:Bool=false) -> XRLogic.Fact {
            .init(relation:r,terms:t,negative:negative,source:source)
        }
        func atom(_ r:String,_ t:[String],_ negative:Bool=false) -> XRLogic.Atom {
            .init(relation:r,terms:t,negative:negative)
        }
        // Rename every entity on each run: the rules cannot depend on personal names.
        for i in 0..<100 {
            let a="entity-\(i)-a", b="entity-\(i)-b", owner="entity-\(i)-owner"
            let facts=[fact("related",[a,owner],"f1"),fact("related",[b,owner],"f2")]
            let all=XRLogic.Query(mode:"select",clauses:[atom("related",["?x",owner])],different:[],select:"?x")
            let result=try XRLogic.evaluate(all,facts:facts)
            check(result.rows.map(\.value)==[a,b])
            let other=XRLogic.Query(mode:"select",clauses:all.clauses,different:[.init(left:"?x",right:a)],select:"?x")
            let filtered=try XRLogic.evaluate(other,facts:facts)
            check(filtered.rows == [.init(value:b,sources:["f2"])])
            let count=XRLogic.Query(mode:"count",clauses:all.clauses,different:[],select:"?x")
            check(XRLogic.render(try XRLogic.evaluate(count,facts:facts),mode:"count").contains("2"))
        }
        let facts=[fact("inside",["item","box"],"1"),fact("inside",["box","room"],"2"),
                   fact("color",["item","blue"],"3"),fact("color",["other","blue"],"4")]
        let join=XRLogic.Query(mode:"select",clauses:[atom("inside",["?item","?container"]),
             atom("inside",["?container","room"]),atom("color",["?item","blue"])],different:[],select:"?item")
        let linked=try XRLogic.evaluate(join,facts:facts.reversed())
        check(linked.rows == [.init(value:"item",sources:["1","2","3"])])
        let missing=XRLogic.Query(mode:"exists",clauses:[atom("inside",["item","room"])],different:[],select:"")
        check(try XRLogic.evaluate(missing,facts:facts).status == .unknown) // no implicit transitivity
        let negative=XRLogic.Query(mode:"exists",clauses:[atom("inside",["item","room"],true)],different:[],select:"")
        check(try XRLogic.evaluate(negative,facts:facts).status == .unknown)
        let denied=facts+[fact("inside",["item","room"],"5",true)]
        check(try XRLogic.evaluate(negative,facts:denied).status == .supported)
        check(try XRLogic.evaluate(missing,facts:denied+[fact("inside",["item","room"],"6")]).status == .contradiction)
        let duplicate=facts+[fact("color",["item","blue"],"7")]
        check(try XRLogic.evaluate(join,facts:duplicate).rows.count == 1)
        let invalid=XRLogic.Query(mode:"execute",clauses:join.clauses,different:[],select:"?item")
        do { _=try XRLogic.evaluate(invalid,facts:facts);preconditionFailure() } catch {}
        do { _=try XRLogic.evaluate(join,facts:[fact("color",["?injected","blue"],"bad")]);preconditionFailure() } catch {}
        check(XRLogic.render(.init(status:.unknown,rows:[]),mode:"count").contains("não são suficientes"))
        print("PASS: \(checks) generic logic checks; renamed entities, exclusion, count, joins, negative evidence, contradictions, provenance and invalid plans")
    }
}
