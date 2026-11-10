
import SwiftUI
import AppKit

struct TubeMainView: View {
    @StateObject private var motor = TubeEngine.shared

    @State private var enlace = ""
    @State private var formato = "MP3"
    @State private var alcance = "Toda la lista"
    @State private var desde = "1"
    @State private var hasta = "20"
    @State private var destino: URL?
    @State private var nombre = "Mi música"

    private var plataforma: String {
        let texto = enlace.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard let componentes = URLComponents(string: texto),
              componentes.scheme == "https",
              let host = componentes.host?.lowercased() else {
            return "Sin identificar"
        }

        if host == "youtu.be" ||
           host == "youtube.com" ||
           host.hasSuffix(".youtube.com") {
            return "YouTube"
        }

        if host == "open.spotify.com" {
            return "Spotify"
        }

        return "Enlace no reconocido"
    }

    private var rangoValido: Bool {
        if alcance == "Toda la lista" {
            return true
        }

        guard let inicio = Int(desde),
              let final = Int(hasta) else {
            return false
        }

        return inicio >= 1 && final >= inicio
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {

            // LOGOTIPO
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

                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 23, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 3) {
                    Text("↓Tube")
                        .font(.system(size: 30, weight: .bold))

                    Text("Música y video")
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Divider()

            // ENLACE
            VStack(alignment: .leading, spacing: 8) {
                Text("Enlace")
                    .font(.headline)

                TextField(
                    "Pega un enlace de YouTube o Spotify",
                    text: $enlace
                )
                .textFieldStyle(.roundedBorder)

                Text("Origen: \(plataforma)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // FORMATO
            VStack(alignment: .leading, spacing: 8) {
                Text("Formato de descarga")
                    .font(.headline)

                Picker("Formato", selection: $formato) {
                    Text("MP3").tag("MP3")
                    Text("MP4").tag("MP4")
                    Text("Ambos").tag("Ambos")
                }
                .pickerStyle(.segmented)

                Text(
                    plataforma == "Spotify" && formato != "MP3"
                    ? "Se buscarán videoclips reales. Las coincidencias no siempre serán exactas."
                    : "Selecciona el formato que necesitas."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // RANGO
            VStack(alignment: .leading, spacing: 8) {
                Text("Elementos")
                    .font(.headline)

                Picker("Alcance", selection: $alcance) {
                    Text("Toda la lista").tag("Toda la lista")
                    Text("Por rango").tag("Por rango")
                }
                .pickerStyle(.segmented)

                if alcance == "Por rango" {
                    HStack(spacing: 12) {
                        Text("Desde")

                        TextField("1", text: $desde)
                            .frame(width: 65)
                            .textFieldStyle(.roundedBorder)

                        Text("Hasta")

                        TextField("20", text: $hasta)
                            .frame(width: 65)
                            .textFieldStyle(.roundedBorder)
                    }

                    if !rangoValido {
                        Text("Introduce un rango válido.")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }

            // CARPETA
            VStack(alignment: .leading, spacing: 8) {
                Text("Guardar en")
                    .font(.headline)

                HStack {
                    Button {
                        elegirCarpeta()
                    } label: {
                        Label(
                            "Seleccionar ubicación",
                            systemImage: "folder"
                        )
                    }

                    Text(destino?.path ?? "Sin seleccionar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                TextField(
                    "Nombre de la carpeta",
                    text: $nombre
                )
                .textFieldStyle(.roundedBorder)
            }

            Spacer(minLength: 0)
            Divider()

            // ESTADO
            VStack(alignment: .leading, spacing: 12) {
                if motor.total > 0 {
                    ProgressView(
                        value: Double(motor.completados),
                        total: Double(motor.total)
                    )

                    Text(
                        "\(motor.porcentaje)% · \(motor.completados) de \(motor.total) procesados"
                    )
                    .font(.caption)
                }

                Text(motor.estado)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                HStack(spacing: 12) {
                    Button {
                        iniciarDescarga()
                    } label: {
                        Label(
                            "Iniciar descarga",
                            systemImage: "arrow.down.circle.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        motor.activo ||
                        destino == nil ||
                        (plataforma != "YouTube" &&
                         plataforma != "Spotify") ||
                        !rangoValido
                    )

                    if motor.activo {
                        Button("Cancelar") {
                            motor.cancelar()
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }

                    Spacer()
                }
            }
        }
        .padding(26)
        .frame(width: 590, height: 620)
    }

    private func elegirCarpeta() {
        let selector = NSOpenPanel()
        selector.canChooseFiles = false
        selector.canChooseDirectories = true
        selector.canCreateDirectories = true

        if selector.runModal() == .OK {
            destino = selector.url
        }
    }

    private func iniciarDescarga() {
        guard let destino else { return }

        let ventanaPrincipal = NSApp.keyWindow

        motor.iniciar(
            enlace: enlace,
            formato: formato,
            todo: alcance == "Toda la lista",
            desde: Int(desde) ?? 1,
            hasta: Int(hasta) ?? 20,
            destino: destino,
            nombre: nombre
        )

        if motor.activo {
            ventanaPrincipal?.miniaturize(nil)
        }
    }
}

