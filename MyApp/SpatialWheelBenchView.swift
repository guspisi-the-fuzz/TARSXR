#if canImport(UIKit)
import SwiftUI

/// Explicit calculation panel. The values do not configure firmware or physical calibration.
struct SpatialWheelBenchView: View {
    @State private var wheelbase=""
    @State private var track=""
    @State private var speedLimit=""
    @State private var forward="0"
    @State private var right="0"
    @State private var yaw="0"
    @State private var angles: [SpatialWheel:String]=[:]
    @State private var plan: SpatialFourWheelPlan?
    @State private var message="Informe geometria e limites por roda. Cálculo independente do percurso; nenhum comando físico."
    private var inputs: [String] { [wheelbase,track,speedLimit,forward,right,yaw]+SpatialWheel.allCases.map { angles[$0] ?? "" } }
    var body: some View {
        Section("4C · Cálculo de quatro rodas direcionais") {
            Text("Quatro motores de tração + quatro servos de direção. Os dois servos do pescoço não fazem parte deste cálculo.")
            Group {
                field("Entre eixos (m)",text:$wheelbase)
                field("Bitola entre rodas (m)",text:$track)
                field("Limite de velocidade linear (m/s)",text:$speedLimit)
            }
            ForEach(SpatialWheel.allCases,id:\.self) { wheel in
                field("Limite ± da direção \(label(wheel)) (graus)",text:Binding(get:{angles[wheel] ?? ""},set:{angles[wheel]=$0}))
            }
            Group {
                field("Velocidade para frente (m/s)",text:$forward)
                field("Velocidade para direita (m/s)",text:$right)
                field("Giro para esquerda (rad/s)",text:$yaw)
            }
            Button("Calcular conjunto simulado") { calculate() }
            Text(message).font(.caption)
            if let plan {
                ForEach(plan.targets,id:\.wheel) { target in
                    Text(String(format:"%@: direção %.1f° · velocidade %.3f m/s",label(target.wheel),target.steeringLeftRadians*180/Double.pi,target.signedLinearMPS))
                }
                Text(String(format:"Redução comum: %.3f · somente simulação",plan.commonSpeedScale))
            }
            Text("Ângulos relativos à frente calibrada, esquerda positiva. Não são graus absolutos de servo. Falta mapear sinais, centros, reversões, dinâmica e confirmar estado físico. Valores digitados não certificam calibração.").font(.caption)
        }
        .onChange(of:inputs) { _,_ in plan=nil }
    }
    private func field(_ name: String,text: Binding<String>) -> some View {
        HStack { Text(name); TextField("Obrigatório",text:text).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing) }
    }
    private func number(_ text: String) throws -> Double {
        guard let n=Double(text.replacingOccurrences(of:",",with:".")), n.isFinite else { throw SpatialFourWheelError.invalidInput }; return n
    }
    private func label(_ wheel: SpatialWheel) -> String {
        switch wheel { case .frontLeft:return "dianteira esquerda"; case .frontRight:return "dianteira direita"; case .rearLeft:return "traseira esquerda"; case .rearRight:return "traseira direita" }
    }
    private func calculate() {
        do {
            var limits=[SpatialWheel:Double]()
            for w in SpatialWheel.allCases { limits[w]=try number(angles[w] ?? "")*Double.pi/180 }
            let geometry=SpatialWheelGeometry(wheelbase:try number(wheelbase),track:try number(track),maxLinearMPS:try number(speedLimit),maxSteeringRadians:limits)
            plan=try SpatialFourWheelPlan.make(twist:SpatialBodyTwist(rightMPS:try number(right),forwardMPS:try number(forward),yawLeftRPS:try number(yaw)),geometry:geometry,now:ProcessInfo.processInfo.systemUptime)
            message="Conjunto geométrico calculado. Não conectado ao percurso, à visão ou ao ESP32; sem teste de aderência, aceleração ou frenagem."
        } catch { plan=nil; message=error.localizedDescription }
    }
}
#endif
