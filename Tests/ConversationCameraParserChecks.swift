import Foundation
@main struct ConversationCameraParserChecks {
    static func main() {
        for request in ["O que você está enxergando?", "Descreva os objetos que você vê", "Você vê um notebook?", "Leia o código na tela", "Procura um gato na imagem"] {
            precondition(VoiceCameraCommand.parse(request)?.kind == .describe, request)
        }
        let reading = VoiceCameraCommand.parse("TARS, leia o código na tela")!
        precondition(VisualQuestionPolicy.needsTextDetail(reading.question))
        precondition(VoiceCameraCommand.parse("TARS, tira uma foto para ler o código")?.kind == .photo)
        precondition(VoiceCameraCommand.parse("TARS, tira uma selfie")?.kind == .selfie)
        precondition(VoiceCameraCommand.parse("TARS, você está vendo a Mel?")?.kind == .findMel)
        precondition(VoiceCameraCommand.parse("TARS, procura a Mel")?.kind == .findMel)
        precondition(VoiceCameraCommand.parse("TARS, procure a Mel")?.kind == .findMel)
        for request in ["O que você viu?", "O que você estava vendo?", "Leia meu email", "Não leia o código na tela", "Quem é a Mel?", "Qual é a capital da França?"] {
            precondition(VoiceCameraCommand.parse(request) == nil, request)
        }
        print("PASS: actual camera parser preserves photo/selfie/Mel routing, explicit text detail, historical and nonvisual boundaries; no camera/API")
    }
}
