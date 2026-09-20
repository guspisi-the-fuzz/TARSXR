import SwiftUI

struct TarsHUDView: View {
    @StateObject var model: TarsHUDViewModel
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                CognitiveDisplay(state: model.voiceState)
                    .frame(maxHeight: .infinity)
                Rectangle().frame(height: 1).foregroundStyle(.green)
                EngineeringPanel(model: model)
                    .frame(maxHeight: .infinity)
            }
            .foregroundStyle(.green)
            .fontDesign(.monospaced)
        }
        .task { await model.run() }
    }
}

struct CognitiveDisplay: View {
    let state: String
    @State private var phase = false
    var body: some View {
        GeometryReader { g in
            ZStack {
                ForEach(0..<5, id: \.self) { i in
                    Circle().stroke(.green.opacity(0.18 + Double(i) * 0.08), lineWidth: 1)
                        .frame(width: CGFloat(90 + i*34), height: CGFloat(90 + i*34))
                        .scaleEffect(phase ? 1.05 : 0.94)
                }
                Circle().fill(.green.opacity(0.08)).frame(width: 130, height: 130)
                VStack { Text("T A R S").font(.title2).tracking(8); Text(state).font(.caption) }
            }.frame(width: g.size.width, height: g.size.height)
        }
        .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: phase)
        .onAppear { phase = true }
    }
}

struct EngineeringPanel: View {
    @ObservedObject var model: TarsHUDViewModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("SYSTEM STATUS").bold(); Spacer(); Text(model.connected ? "LINK" : "OFFLINE") }
                Divider().overlay(.green.opacity(0.5))
                ForEach(model.systemRows, id: \.0) { row in
                    HStack { Text(row.0); Spacer(); Text(row.1).bold() }
                }
                Divider().overlay(.green.opacity(0.5))
                HStack(alignment: .top) {
                    metricColumn("SENSORS", rows: model.sensorRows)
                    metricColumn("COMPUTE", rows: model.computeRows)
                }
                Text("> \(model.logLine)").font(.caption).padding(.top, 4)
            }.padding(14)
        }
    }
    private func metricColumn(_ title: String, rows: [(String,String)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).bold()
            ForEach(rows, id: \.0) { r in HStack { Text(r.0); Spacer(); Text(r.1) } }
        }.frame(maxWidth: .infinity)
    }
}
