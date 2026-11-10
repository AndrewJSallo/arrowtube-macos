
import SwiftUI

struct Hexagono: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        for i in 0..<6 {
            let angle = Double(i) * .pi / 3 - .pi / 2
            let punto = CGPoint(
                x: rect.midX + CGFloat(cos(angle)) * rect.width * 0.48,
                y: rect.midY + CGFloat(sin(angle)) * rect.height * 0.48
            )

            if i == 0 {
                path.move(to: punto)
            } else {
                path.addLine(to: punto)
            }
        }

        path.closeSubpath()
        return path
    }
}

struct ContentView: View {
    @State private var girando = false
    @State private var expandido = false
    @State private var completados = 18

    private let total = 50

    private var porcentaje: Int {
        Int(Double(completados) / Double(total) * 100)
    }

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 12) {
                ZStack {
                    Hexagono()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 1, green: 0.46, blue: 0.40),
                                    Color(red: 0.96, green: 0.09, blue: 0.26),
                                    Color(red: 0.58, green: 0, blue: 0.24)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 84, height: 84)
                        .rotationEffect(.degrees(girando ? 360 : 0))
                        .animation(
                            .linear(duration: 1.4)
                                .repeatForever(autoreverses: false),
                            value: girando
                        )

                    Text("\(porcentaje)%")
                        .font(.system(
                            size: 18,
                            weight: .bold,
                            design: .rounded
                        ))
                        .foregroundStyle(.white)
                }

                if expandido {
                    Text("\(completados) / \(total)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .transition(.opacity.combined(with: .scale))
                }
            }
            .padding(10)
            .background(
                Color.black.opacity(0.90),
                in: RoundedRectangle(cornerRadius: 20)
            )
            .onHover { encima in
                withAnimation(.easeInOut(duration: 0.25)) {
                    expandido = encima
                }
            }
            .onAppear {
                girando = true
            }

            Button("Simular avance") {
                completados = min(total, completados + 1)
            }

            Text("Vista previa de YT Downloader")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 340, minHeight: 260)
    }
}

#Preview {
    ContentView()
}

