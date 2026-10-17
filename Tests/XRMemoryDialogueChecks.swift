import Foundation

@MainActor
private final class DialogueFixtureRuntime: TARSRuntime {
    var calls = 0
    var spoken: [String] = []
    var contexts: [[String: Any]] = []
    var response = "fixture response; never used as a source of saved facts"
    var paused = false
    var waiting: CheckedContinuation<String, Error>?
    func hud() async throws -> HUDSnapshot { throw TARSClientError.unavailable }
    func command(_ action: String, params: TARSCommandParameters?) async throws -> TARSCommandReply { preconditionFailure("memory must not send motion commands") }
    func telemetry() async throws -> TARSTelemetry { throw TARSClientError.unavailable }
    func recover() async throws { preconditionFailure("memory must not recover safety") }
    func describeImage(png: Data, source: String, question: String, history: [[String: String]]) async throws -> VisionReply { throw TARSClientError.unavailable }
    func transcribe(data: Data) async throws -> String { preconditionFailure("test uses text, never microphone") }
    func synthesize(text: String) async throws -> Data { preconditionFailure("test never calls voice provider") }
    func streamSpeech(text: String, receive: @escaping @MainActor (Data) throws -> Void) async throws { spoken.append(text) }
    func streamConversation(text: String, receive: @escaping @MainActor (Data) throws -> Void, receiveText: @escaping @MainActor (String) -> Void) async throws { throw TARSClientError.unavailable }
    func converse(text: String, language: String, context: [String: Any]?) async throws -> String {
        calls += 1; contexts.append(context ?? [:])
        if paused { return try await withCheckedThrowingContinuation { waiting = $0 } }
        return response
    }
    var selected: [[String: Any]] { (contexts.last?["xr_memory"] as? [String: Any])?["facts"] as? [[String: Any]] ?? [] }
}


@main struct XRMemoryDialogueChecks {
 @MainActor static func main() async throws {
  precondition(XRMemoryIntent.isQuestionLike("Em que ano ele nasceu"))
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at:root) }
  let store=XRPersistentMemory(url:root.appendingPathComponent("memory.json"))
  _=try store.save(subject:"Luma",statement:"Luma é uma gata que mora comigo e com Nora",correction:false)
  _=try store.save(subject:"Nora",statement:"Nora mora comigo",correction:false)
  let datesStore=XRPersistentMemory(url:root.appendingPathComponent("dates.json"))
  for (subject,statement) in [("meu pai", "Nilo é meu pai"),
    ("meu pai nascimento", "Meu pai nasceu em 6 de setembro de 1940"),
    ("meu pai aniversario", "Meu pai nasceu em dia 6 de setembro de 1940"),
    ("meu pai data", "A data de nascimento do meu pai é 6 de setembro de 1940")] {
      _=try datesStore.save(subject:subject,statement:statement,correction:false)
  }
  let datesRuntime=MemoryTARSRuntime(underlying:DialogueFixtureRuntime(),memory:{datesStore},pendingState:XRMemoryPendingState())
  let dateReply=try await datesRuntime.converse(text:"Em que ano meu pai nasceu",language:"pt-BR",context:nil)
  precondition(dateReply.contains("1940") && !dateReply.contains("possibilidade"), dateReply)
  let before=try store.load()
  let base=DialogueFixtureRuntime()
  let online=ProcessInfo.processInfo.environment["TARS_TEST_ONLINE"] == "1"
  var calls=0, exchanges=0
  #if canImport(ImageIO)
  let ai=NativeAIService {
    guard let key=ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty else { throw TARSClientError.ai("AI_UNCONFIGURED") }
    return (key,ProcessInfo.processInfo.environment["OPENAI_MODEL"] ?? "gpt-5.4-mini")
  }
  #endif
  let reasoner=XRMemoryReasoner { payload in
    calls += 1
    let json=try JSONSerialization.jsonObject(with:Data(payload.utf8)) as! [String:Any]
    let recent=json["recent_exchanges"] as! [[String:String]]
    exchanges=recent.count
    precondition(recent.contains { ($0["answer"] ?? "").contains("Luma") })
    #if canImport(ImageIO)
    if online { return try await ai.interpretMemory(payload) }
    #else
    precondition(!online, "Online checks require the native Apple provider")
    #endif
    return XRLogic.Plan(intent:"query",facts:[
      .init(relation:"lives",terms:["Luma","@user"],negative:false,source:"luma"),
      .init(relation:"lives",terms:["Luma","Nora"],negative:false,source:"luma")],
      query:.init(mode:"select",clauses:[.init(relation:"lives",terms:["Luma","?x"],negative:false)],different:(payload.contains("além de mim") ? [] : [.init(left:"?x",right:"@user")]),select:"?x"))
  }
  let runtime=MemoryTARSRuntime(underlying:base,memory:{store},pendingState:XRMemoryPendingState(),
    evidenceRecall:{try await reasoner.resolve($0,document:$1)},
    observeRecall:{reasoner.observe($0,answer:$1,document:$2)})
  let nora=try await runtime.converse(text:"TARS, quem é a Nora?",language:"pt-BR",context:nil)
  precondition(nora.contains("Nora") && calls==0)
  let luma=try await runtime.converse(text:"TARS, quem é a Luma?",language:"pt-BR",context:nil)
  precondition(luma.contains("Luma") && luma.contains("Nora") && calls==0)
  for question in ["Se a Luma é uma gata que mora comigo, com quem mais ela mora?", "E além de mim, com quem ela mora?"] {
    let answer=try await runtime.converse(text:question,language:"pt-BR",context:nil)
    print("Q: \(question)\nA: \(answer)")
    precondition(answer == "Pelos fatos registrados: Nora.")
  }
  precondition(exchanges >= 2 && base.calls==0)
  var streamed = ""
  try await runtime.streamConversation(text:"Quem é a Luma?",receive:{ _ in },receiveText:{streamed += $0})
  precondition(streamed.contains("Luma") && streamed.contains("Nora") && base.spoken == [streamed])
  precondition(base.calls == 0)
  let after=try store.load();precondition(before.revision==after.revision && before.facts==after.facts)
  print("PASS: local identity -> model follow-up, exclusions, no memory writes; online=\(online), calls=\(calls)")
 }
}
