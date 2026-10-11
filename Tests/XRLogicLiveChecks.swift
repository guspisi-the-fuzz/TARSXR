// Manual opt-in API check. Synthetic fixtures only; credential supplied in process environment.
import Foundation
@main struct XRLogicLiveChecks {
 @MainActor static func main() async {
 do { try await run() } catch { print("FAIL:", String(describing:error)) }
 }
 @MainActor static func run() async throws {
  let key=ProcessInfo.processInfo.environment["TARS_LOGIC_TEST_KEY"] ?? ""
  guard !key.isEmpty else { fatalError("Missing test configuration") }
  let ai=NativeAIService { (key,"gpt-5.4-mini") }
  let reasoner=XRMemoryReasoner { try await ai.interpretMemory($0) }
  let facts=[("a","Ivo é meu irmão"),("b","Rui é meu irmão"),("c","A caixa azul está na sala"),("d","O livro está na caixa azul")]
  let doc=XRMemoryDocument(schemaVersion:1,ownerID:"synthetic-test",revision:"test-1",facts:facts.map { XRMemoryFact(key:$0.0,subject:$0.0,statement:$0.1,source:"user",scope:"xr",createdAt:0,updatedAt:0) },forgotten:[])
  for (question,expected) in [
   ("Qual é o nome dos meus dois irmãos?",["Ivo","Rui"]),
   ("Ivo é um deles. Qual é o nome do meu outro irmão?",["Rui"]),
   ("Qual objeto está dentro da caixa que fica na sala?",["livro"])] {
    let result=try await reasoner.answer(question,document:doc) ?? ""
    guard expected.allSatisfy({ result.contains($0) }) else { print("FAIL: synthetic inference:",question,"RESULT:",result); return }
    if expected == ["Rui"] && result.contains("Ivo") { print("FAIL: exclusion"); return }
    print("PASS: synthetic inference:",question)
  }
  let skip=try await reasoner.answer("Qual a previsão do tempo amanhã?",document:doc)
  guard skip == nil else { print("FAIL: unrelated routing"); return }
  print("PASS: real model interpretation + local deductions; synthetic data only; no device install")
 }
}
