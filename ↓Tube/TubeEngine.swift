
import Foundation
import AppKit
import Combine

struct TubeItem {
    let id: String
    let titulo: String
    let artista: String
    let url: String
    let duracion: Double?
}

@MainActor
final class TubeEngine: ObservableObject {
    static let shared = TubeEngine()

    @Published private(set) var activo = false
    @Published private(set) var completados = 0
    @Published private(set) var total = 0
    @Published private(set) var fallidos = 0
    @Published private(set) var estado = "Listo para descargar"

    private let yt = "/opt/homebrew/bin/yt-dlp"
    private let ff = "/opt/homebrew/bin/ffmpeg"
    private let spot = NSHomeDirectory() + "/.local/bin/spotdl"

    private var proceso: Process?
    private var cancelado = false

    var porcentaje: Int {
        guard total > 0 else { return 0 }
        return min(100, Int(Double(completados) / Double(total) * 100))
    }

    func iniciar(
        enlace: String,
        formato: String,
        todo: Bool,
        desde: Int,
        hasta: Int,
        destino: URL,
        nombre: String
    ) {
        guard !activo else { return }

        let url = enlace.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard let componentes = URLComponents(string: url),
              componentes.scheme == "https",
              let host = componentes.host?.lowercased() else {
            estado = "Introduce un enlace HTTPS válido."
            return
        }

        let spotify = host == "open.spotify.com"
        let youtube = host == "youtu.be" ||
            host == "youtube.com" ||
            host.hasSuffix(".youtube.com")

        guard spotify || youtube else {
            estado = "Enlace no reconocido."
            return
        }

        let carpeta = nombre.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !carpeta.isEmpty,
              carpeta != ".",
              carpeta != "..",
              !carpeta.contains("/"),
              !carpeta.contains(":") else {
            estado = "Nombre de carpeta inválido."
            return
        }

        guard todo || (desde > 0 && hasta >= desde) else {
            estado = "Rango inválido."
            return
        }

        let herramientas = spotify
            ? [spot, yt, ff]
            : [yt, ff]

        guard herramientas.allSatisfy({
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            estado = "Falta una herramienta de descarga."
            return
        }

        activo = true
        cancelado = false
        completados = 0
        total = 0
        fallidos = 0
        estado = "Analizando enlace..."

        YTAppDelegate.actual?.mostrarIndicador()

        Task {
            await ejecutar(
                url: url,
                esSpotify: spotify,
                formato: formato,
                todo: todo,
                desde: desde,
                hasta: hasta,
                destino: destino,
                nombre: carpeta
            )
        }
    }

    func cancelar() {
        guard activo else { return }

        cancelado = true
        estado = "Cancelando operación..."

        if let proceso, proceso.isRunning {
            proceso.terminate()
        }
    }

    private func ejecutar(
        url: String,
        esSpotify: Bool,
        formato: String,
        todo: Bool,
        desde: Int,
        hasta: Int,
        destino: URL,
        nombre: String
    ) async {
        let base = destino.appendingPathComponent(nombre)
        let mp3 = base.appendingPathComponent("MP3")
        let mp4 = base.appendingPathComponent("MP4")
        let registro = base.appendingPathComponent("Registro")
        let temporales = registro.appendingPathComponent("Temporales")
        let log = registro.appendingPathComponent("ultima_ejecucion.log")

        do {
            let fm = FileManager.default

            for carpeta in [mp3, mp4, registro, temporales] {
                try fm.createDirectory(
                    at: carpeta,
                    withIntermediateDirectories: true
                )
            }

            try Data("Inicio de descarga\n".utf8).write(to: log)

            let elementos: [TubeItem]

            if esSpotify {
                elementos = try await listaSpotify(
                    url: url,
                    registro: registro,
                    log: log
                )
            } else {
                elementos = try await listaYouTube(
                    url: url,
                    registro: registro,
                    log: log
                )
            }

            if cancelado { throw error("Cancelado") }

            let seleccion: [TubeItem]

            if todo {
                seleccion = elementos
            } else {
                guard desde <= elementos.count else {
                    throw error("El rango supera la cantidad de elementos.")
                }

                seleccion = Array(
                    elementos.dropFirst(desde - 1)
                        .prefix(hasta - desde + 1)
                )
            }

            total = seleccion.count

            guard total > 0 else {
                throw error("La lista no contiene elementos disponibles.")
            }

            for elemento in seleccion {
                if cancelado { break }

                estado = "Procesando \(completados + 1) de \(total)"

                var tuvoError = false

                if formato == "MP3" || formato == "Ambos" {
                    do {
                        if esSpotify {
                            try await mp3Spotify(
                                elemento,
                                carpeta: mp3,
                                log: log
                            )
                        } else {
                            try await mp3YouTube(
                                elemento,
                                carpeta: mp3,
                                temporales: temporales,
                                log: log
                            )
                        }
                    } catch {
                        tuvoError = true
                        escribir(
                            "Error MP3 \(elemento.titulo): \(error.localizedDescription)",
                            en: log
                        )
                    }
                }

                if !cancelado &&
                   (formato == "MP4" || formato == "Ambos") {
                    do {
                        let videoID: String

                        if esSpotify {
                            estado = "Buscando videoclip: \(elemento.titulo)"

                            guard let encontrado = try await buscarVideoclip(
                                elemento,
                                registro: registro,
                                log: log
                            ) else {
                                throw error(
                                    "No se encontró un videoclip suficientemente relacionado."
                                )
                            }

                            videoID = encontrado
                        } else {
                            videoID = elemento.id
                        }

                        try await descargarVideo(
                            id: videoID,
                            titulo: esSpotify
                                ? "\(elemento.artista) - \(elemento.titulo)"
                                : elemento.titulo,
                            identificador: esSpotify
                                ? "SPOT-\(elemento.id)"
                                : elemento.id,
                            carpeta: mp4,
                            temporales: temporales,
                            log: log
                        )
                    } catch {
                        tuvoError = true
                        escribir(
                            "Error MP4 \(elemento.titulo): \(error.localizedDescription)",
                            en: log
                        )
                    }
                }

                if cancelado { break }

                if tuvoError { fallidos += 1 }
                completados += 1
            }

            if cancelado {
                estado = "Descarga cancelada. Se conservaron los archivos completados."
            } else if fallidos > 0 {
                estado = "Proceso terminado con \(fallidos) elementos con incidencias."
            } else {
                estado = "Descarga terminada correctamente."
            }

        } catch {
            if cancelado {
                estado = "Descarga cancelada."
            } else {
                estado = "Error: \(error.localizedDescription)"
            }
        }

        activo = false
        YTAppDelegate.actual?.finalizarIndicador()

        if FileManager.default.fileExists(atPath: base.path) {
            NSWorkspace.shared.open(base)
        }

        NSApp.activate(ignoringOtherApps: true)

        let alerta = NSAlert()
        alerta.messageText = "↓Tube"
        alerta.informativeText = estado
        alerta.addButton(withTitle: "Aceptar")
        alerta.runModal()
    }

    // MARK: - Consultar YouTube

    private func listaYouTube(
        url: String,
        registro: URL,
        log: URL
    ) async throws -> [TubeItem] {
        estado = "Analizando lista de YouTube..."

        let json = registro.appendingPathComponent("lista_youtube.json")

        let codigo = try await comando(
            yt,
            [
                "--no-config",
                "--flat-playlist",
                "--dump-single-json",
                "--yes-playlist",
                url
            ],
            log: log,
            salida: json
        )

        guard codigo == 0 else {
            throw error("No se pudo consultar YouTube.")
        }

        let objeto = try leerObjeto(json)
        let entradas = objeto["entries"] as? [[String: Any]]
            ?? [objeto]

        return entradas.compactMap { dato in
            guard let id = dato["id"] as? String,
                  !id.isEmpty else { return nil }

            return TubeItem(
                id: id,
                titulo: dato["title"] as? String ?? id,
                artista: "",
                url: "https://www.youtube.com/watch?v=\(id)",
                duracion: (dato["duration"] as? NSNumber)?.doubleValue
            )
        }
    }

    // MARK: - Consultar Spotify

    private func listaSpotify(
        url: String,
        registro: URL,
        log: URL
    ) async throws -> [TubeItem] {
        estado = "Consultando canciones de Spotify..."

        let archivo = registro.appendingPathComponent(
            "catalogo_spotify.spotdl"
        )

        let codigo = try await comando(
            spot,
            [
                "save",
                url,
                "--save-file",
                archivo.path
            ],
            log: log
        )

        guard codigo == 0 else {
            throw error("No se pudo consultar la lista de Spotify.")
        }

        let datos = try Data(contentsOf: archivo)
        let objeto = try JSONSerialization.jsonObject(with: datos)

        guard let canciones = objeto as? [[String: Any]] else {
            throw error("Spotify devolvió una lista no reconocida.")
        }

        return canciones.compactMap { cancion in
            guard let id = cancion["song_id"] as? String,
                  let titulo = cancion["name"] as? String else {
                return nil
            }

            let artista = cancion["artist"] as? String
                ?? ((cancion["artists"] as? [String])?.first ?? "")

            return TubeItem(
                id: id,
                titulo: titulo,
                artista: artista,
                url: cancion["url"] as? String
                    ?? "https://open.spotify.com/track/\(id)",
                duracion: (cancion["duration"] as? NSNumber)?.doubleValue
            )
        }
    }

    // MARK: - MP3 de Spotify con metadatos

    private func mp3Spotify(
        _ cancion: TubeItem,
        carpeta: URL,
        log: URL
    ) async throws {
        if existe(
            id: "[\(cancion.id)]",
            extension: "mp3",
            en: carpeta
        ) {
            return
        }

        estado = "MP3 Spotify: \(cancion.titulo)"

        let codigo = try await comando(
            spot,
            [
                "download",
                cancion.url,
                "--format", "mp3",
                "--bitrate", "192k",
                "--ffmpeg", ff,
                "--overwrite", "skip",
                "--restrict", "ascii",
                "--threads", "1",
                "--output",
                carpeta.path + "/{artist} - {title} [{track-id}].{output-ext}"
            ],
            log: log
        )

        guard codigo == 0, !cancelado else {
            throw error("No se pudo obtener el MP3 de Spotify.")
        }
    }

    // MARK: - MP3 de YouTube con carátula

    private func mp3YouTube(
        _ video: TubeItem,
        carpeta: URL,
        temporales: URL,
        log: URL
    ) async throws {
        if existe(id: "[\(video.id)]", extension: "mp3", en: carpeta) {
            return
        }

        estado = "MP3 YouTube: \(video.titulo)"

        let temp = temporales.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: temp,
            withIntermediateDirectories: true
        )

        let codigo = try await comando(
            yt,
            [
                "--no-config",
                "--no-playlist",
                "--no-overwrites",
                "-f", "bestaudio/best",
                "-x",
                "--audio-format", "mp3",
                "--audio-quality", "192K",
                "--embed-thumbnail",
                "--convert-thumbnails", "jpg",
                "--embed-metadata",
                "-o", temp.path + "/audio.%(ext)s",
                video.url
            ],
            log: log
        )

        guard codigo == 0, !cancelado else {
            throw error("Falló la extracción del MP3.")
        }

        let archivos = try FileManager.default.contentsOfDirectory(
            at: temp,
            includingPropertiesForKeys: nil
        )

        guard let original = archivos.first(where: {
            $0.pathExtension.lowercased() == "mp3"
        }) else {
            throw error("No se generó un MP3 válido.")
        }

        let destino = carpeta.appendingPathComponent(
            "\(nombreSeguro(video.titulo)) [\(video.id)].mp3"
        )

        if !FileManager.default.fileExists(atPath: destino.path) {
            try FileManager.default.moveItem(at: original, to: destino)
        }

        try? FileManager.default.removeItem(at: temp)
    }

    // MARK: - Buscar videoclip para Spotify

    private func buscarVideoclip(
        _ cancion: TubeItem,
        registro: URL,
        log: URL
    ) async throws -> String? {
        let consultas = [
            "\(cancion.artista) \(cancion.titulo) official music video",
            "\(cancion.artista) \(cancion.titulo) lyric video visualizer"
        ]

        var mejorID: String?
        var mejorPuntaje = -999

        for consulta in consultas {
            if cancelado { return nil }

            let archivo = registro.appendingPathComponent(
                "busqueda_video.json"
            )

            let codigo = try await comando(
                yt,
                [
                    "--no-config",
                    "--flat-playlist",
                    "--dump-single-json",
                    "ytsearch8:\(consulta)"
                ],
                log: log,
                salida: archivo
            )

            guard codigo == 0 else { continue }

            let objeto = try leerObjeto(archivo)
            let resultados = objeto["entries"] as? [[String: Any]] ?? []

            for resultado in resultados {
                guard let id = resultado["id"] as? String else {
                    continue
                }

                let puntaje = evaluar(
                    resultado: resultado,
                    cancion: cancion
                )

                if puntaje > mejorPuntaje {
                    mejorPuntaje = puntaje
                    mejorID = id
                }
            }

            if mejorPuntaje >= 90 { break }
        }

        guard mejorPuntaje >= 35 else {
            return nil
        }

        escribir(
            "Coincidencia Spotify MP4: \(cancion.artista) - \(cancion.titulo), video \(mejorID ?? "?"), puntuación \(mejorPuntaje)",
            en: log
        )

        return mejorID
    }

    private func evaluar(
        resultado: [String: Any],
        cancion: TubeItem
    ) -> Int {
        let titulo = normalizar(
            resultado["title"] as? String ?? ""
        )
        let canal = normalizar(
            resultado["channel"] as? String
                ?? resultado["uploader"] as? String
                ?? ""
        )

        let nombre = normalizar(cancion.titulo)
        let artista = normalizar(cancion.artista)

        let palabras = nombre.split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 3 }

        let coincidencias = palabras.filter {
            titulo.contains($0)
        }.count

        guard !palabras.isEmpty,
              coincidencias >= max(1, palabras.count / 2) else {
            return -100
        }

        var puntos = coincidencias * 12

        if titulo.contains(artista) || canal.contains(artista) {
            puntos += 25
        }

        if titulo.contains("official music video") ||
           titulo.contains("video oficial") {
            puntos += 75
        } else if titulo.contains("official video") {
            puntos += 65
        } else if titulo.contains("lyric video") ||
                  titulo.contains("visualizer") {
            puntos += 30
        }

        if titulo.contains("karaoke") ||
           titulo.contains("reaction") ||
           titulo.contains("cover") ||
           titulo.contains("tutorial") {
            puntos -= 110
        }

        if titulo.contains("official audio") ||
           titulo.contains("audio only") ||
           titulo.contains("static image") {
            puntos -= 90
        }

        if titulo.contains("live") &&
           !nombre.contains("live") {
            puntos -= 65
        }

        if let original = cancion.duracion,
           let encontrado = (resultado["duration"] as? NSNumber)?.doubleValue {
            let diferencia = abs(original - encontrado)

            if diferencia <= 25 {
                puntos += 15
            } else if diferencia > 90 {
                puntos -= 60
            }
        }

        return puntos
    }

    // MARK: - Descargar y convertir video

    private func descargarVideo(
        id: String,
        titulo: String,
        identificador: String,
        carpeta: URL,
        temporales: URL,
        log: URL
    ) async throws {
        if existe(
            id: "[\(identificador)]",
            extension: "mp4",
            en: carpeta
        ) {
            return
        }

        let fm = FileManager.default
        let temp = temporales.appendingPathComponent(UUID().uuidString)

        try fm.createDirectory(
            at: temp,
            withIntermediateDirectories: true
        )

        estado = "Descargando video: \(titulo)"

        let codigo = try await comando(
            yt,
            [
                "--no-config",
                "--no-playlist",
                "-f", "bv*+ba/b",
                "--merge-output-format", "mkv",
                "-o", temp.path + "/video.%(ext)s",
                "https://www.youtube.com/watch?v=\(id)"
            ],
            log: log
        )

        guard codigo == 0, !cancelado else {
            throw error("No se pudo obtener el video.")
        }

        let archivos = try fm.contentsOfDirectory(
            at: temp,
            includingPropertiesForKeys: nil
        )

        guard let original = archivos.first(where: {
            ["mkv", "webm", "mp4", "mov"]
                .contains($0.pathExtension.lowercased())
        }) else {
            throw error("No se encontró el video temporal.")
        }

        estado = "Convirtiendo MP4: \(titulo)"

        let salida = carpeta.appendingPathComponent(
            "\(nombreSeguro(titulo)) [\(identificador)].mp4"
        )

        let parcial = temp.appendingPathComponent("convertido.mp4")

        let conversion = try await comando(
            ff,
            [
                "-y", "-nostdin",
                "-hide_banner", "-loglevel", "error",
                "-i", original.path,
                "-map", "0:v:0",
                "-map", "0:a:0",
                "-vf",
                "fps=30,scale=640:360:force_original_aspect_ratio=decrease,pad=640:360:(ow-iw)/2:(oh-ih)/2,format=yuv420p",
                "-c:v", "libx264",
                "-preset", "veryfast",
                "-profile:v", "baseline",
                "-level:v", "3.0",
                "-b:v", "1000k",
                "-maxrate", "1200k",
                "-bufsize", "2400k",
                "-c:a", "aac",
                "-b:a", "128k",
                "-ar", "44100",
                "-ac", "2",
                "-movflags", "+faststart",
                parcial.path
            ],
            log: log
        )

        guard conversion == 0,
              !cancelado,
              fm.fileExists(atPath: parcial.path) else {
            throw error("Falló la conversión del video.")
        }

        if !fm.fileExists(atPath: salida.path) {
            try fm.moveItem(at: parcial, to: salida)
        }

        try? fm.removeItem(at: temp)
    }

    // MARK: - Utilidades

    private func normalizar(_ texto: String) -> String {
        texto.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "es")
        ).lowercased()
    }

    private func nombreSeguro(_ texto: String) -> String {
        let limpio = texto.folding(
            options: .diacriticInsensitive,
            locale: Locale(identifier: "es")
        ).replacingOccurrences(
            of: "[^A-Za-z0-9 _-]",
            with: "",
            options: .regularExpression
        )

        let corto = String(limpio.prefix(70))
            .trimmingCharacters(in: .whitespaces)

        return corto.isEmpty ? "Archivo" : corto
    }

    private func existe(
        id: String,
        extension tipo: String,
        en carpeta: URL
    ) -> Bool {
        let archivos = (try? FileManager.default.contentsOfDirectory(
            at: carpeta,
            includingPropertiesForKeys: nil
        )) ?? []

        return archivos.contains {
            $0.pathExtension.lowercased() == tipo &&
            $0.lastPathComponent.contains(id)
        }
    }

    private func leerObjeto(_ url: URL) throws -> [String: Any] {
        let datos = try Data(contentsOf: url)

        guard let objeto = try JSONSerialization.jsonObject(
            with: datos
        ) as? [String: Any] else {
            throw error("No se pudo interpretar la respuesta.")
        }

        return objeto
    }

    private func error(_ mensaje: String) -> NSError {
        NSError(
            domain: "↓Tube",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: mensaje]
        )
    }

    private func escribir(_ texto: String, en log: URL) {
        guard let datos = (texto + "\n").data(using: .utf8),
              let archivo = try? FileHandle(forWritingTo: log) else {
            return
        }

        defer { try? archivo.close() }

        _ = try? archivo.seekToEnd()
        try? archivo.write(contentsOf: datos)
    }

    private func comando(
        _ ejecutable: String,
        _ argumentos: [String],
        log: URL,
        salida: URL? = nil
    ) async throws -> Int32 {
        let fm = FileManager.default

        if let salida {
            _ = fm.createFile(atPath: salida.path, contents: Data())
        }

        let registro = try FileHandle(forWritingTo: log)
        _ = try registro.seekToEnd()

        let salidaHandle = try salida.map {
            try FileHandle(forWritingTo: $0)
        }

        defer {
            try? registro.close()
            try? salidaHandle?.close()
            proceso = nil
        }

        let tarea = Process()
        tarea.executableURL = URL(fileURLWithPath: ejecutable)
        tarea.arguments = argumentos
        tarea.standardInput = FileHandle.nullDevice
        tarea.standardOutput = salidaHandle ?? registro
        tarea.standardError = registro

        var entorno = ProcessInfo.processInfo.environment
        entorno["PATH"] =
            "/opt/homebrew/bin:" +
            NSHomeDirectory() + "/.local/bin:" +
            "/usr/bin:/bin:/usr/sbin:/sbin"

        tarea.environment = entorno
        proceso = tarea

        return try await withCheckedThrowingContinuation {
            (continuacion: CheckedContinuation<Int32, Error>) in

            tarea.terminationHandler = { terminado in
                continuacion.resume(
                    returning: terminado.terminationStatus
                )
            }

            do {
                try tarea.run()
            } catch {
                continuacion.resume(throwing: error)
            }
        }
    }
}
