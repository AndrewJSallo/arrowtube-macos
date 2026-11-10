
import SwiftUI
import AppKit
import Combine

@main
struct MyApp: App {
    @NSApplicationDelegateAdaptor(YTAppDelegate.self)
    var delegado

    var body: some Scene {
        WindowGroup("↓Tube") {
            TubeMainView()
        }
        .windowResizability(.contentSize)

        Settings {
            EmptyView()
        }
    }
}

// MARK: - Bordes

enum Borde: Equatable {
    case izquierda
    case derecha
    case superior
    case inferior
}

// MARK: - Ventana flotante y movimiento

@MainActor
final class YTAppDelegate: NSObject,
                           NSApplicationDelegate,
                           ObservableObject {

    static weak var actual: YTAppDelegate?

    var panel: NSPanel?

    @Published var golpes = 0
    @Published var borde: Borde = .derecha
    @Published var instanteGolpe = Date.distantPast

    private var arrastrando = false
    private var ratonInicial = NSPoint.zero
    private var ventanaInicial = NSPoint.zero

    private var velocidad = CGVector(dx: 0, dy: 0)
    private var ultimaVelocidad = CGVector(dx: 0, dy: 0)
    private var ultimoMovimiento: TimeInterval = 0
    private var ultimoTiempo: TimeInterval = 0

    private var reloj: Timer?
    private let clavePosicion = "YTDownloader.Posicion"

    private struct Muestra {
        let punto: NSPoint
        let tiempo: TimeInterval
    }

    private var muestraAnterior: Muestra?

    // MARK: - Iniciar

    func applicationDidFinishLaunching(
        _ notification: Notification
    ) {
        YTAppDelegate.actual = self

        let tamano = NSSize(width: 110, height: 110)

        let ventana = NSPanel(
            contentRect: NSRect(
                origin: .zero,
                size: tamano
            ),
            styleMask: [
                .borderless,
                .nonactivatingPanel
            ],
            backing: .buffered,
            defer: false
        )

        ventana.level = .floating
        ventana.isOpaque = false
        ventana.backgroundColor = .clear
        ventana.hasShadow = false
        ventana.hidesOnDeactivate = false
        ventana.isMovableByWindowBackground = false

        ventana.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary
        ]

        ventana.contentView = NSHostingView(
            rootView: IndicadorFlotante(motor: self)
        )

        panel = ventana

        let area = NSScreen.main?.visibleFrame
            ?? NSRect(
                x: 0, y: 0,
                width: 1200, height: 800
            )

        var posicion = NSPoint(
            x: area.midX - tamano.width / 2,
            y: area.midY - tamano.height / 2
        )

        if let guardada = UserDefaults.standard.array(
            forKey: clavePosicion
        ) as? [Double],
           guardada.count == 2 {

            posicion = NSPoint(
                x: guardada[0],
                y: guardada[1]
            )
        }

        posicion.x = min(
            max(posicion.x, area.minX),
            area.maxX - tamano.width
        )

        posicion.y = min(
            max(posicion.y, area.minY),
            area.maxY - tamano.height
        )

        ventana.setFrameOrigin(posicion)

        // El hexágono comienza oculto.
        ventana.orderOut(nil)
    }

    // MARK: - Mostrar y ocultar

    func mostrarIndicador() {
        panel?.level = .floating
        panel?.orderFrontRegardless()
    }

    func finalizarIndicador() {
        Task {
            try? await Task.sleep(for: .seconds(1.3))

            if !TubeEngine.shared.activo {
                panel?.orderOut(nil)
            }
        }
    }

    private var areaVisible: NSRect {
        (panel?.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(
                x: 0, y: 0,
                width: 1200, height: 800
            )
    }

    // MARK: - Arrastre

    func arrastrar(hasta raton: NSPoint) {
        guard let panel else { return }

        let ahora = ProcessInfo.processInfo.systemUptime

        if !arrastrando {
            detenerFisica()

            arrastrando = true
            ratonInicial = raton
            ventanaInicial = panel.frame.origin

            ultimaVelocidad = CGVector(dx: 0, dy: 0)
            ultimoMovimiento = ahora

            muestraAnterior = Muestra(
                punto: raton,
                tiempo: ahora
            )
        }

        let area = areaVisible

        let x = min(
            max(
                ventanaInicial.x + raton.x - ratonInicial.x,
                area.minX
            ),
            area.maxX - panel.frame.width
        )

        let y = min(
            max(
                ventanaInicial.y + raton.y - ratonInicial.y,
                area.minY
            ),
            area.maxY - panel.frame.height
        )

        panel.setFrameOrigin(NSPoint(x: x, y: y))

        if let anterior = muestraAnterior {
            let dt = ahora - anterior.tiempo
            let dx = raton.x - anterior.punto.x
            let dy = raton.y - anterior.punto.y

            if dt > 0.002 && hypot(dx, dy) > 0.4 {
                let factor: CGFloat = 0.45

                ultimaVelocidad.dx =
                    ultimaVelocidad.dx * (1 - factor)
                    + (dx / dt) * factor

                ultimaVelocidad.dy =
                    ultimaVelocidad.dy * (1 - factor)
                    + (dy / dt) * factor

                ultimoMovimiento = ahora
            }
        }

        muestraAnterior = Muestra(
            punto: raton,
            tiempo: ahora
        )
    }

    // MARK: - Lanzamiento

    func soltar(velocidadGesto: CGSize) {
        guard arrastrando else { return }
        arrastrando = false

        let ahora = ProcessInfo.processInfo.systemUptime
        let tiempoQuieto = ahora - ultimoMovimiento

        var vx = ultimaVelocidad.dx
        var vy = ultimaVelocidad.dy

        // Conservar la inercia de los gestos recientes.
        if tiempoQuieto > 1.10 {
            vx = 0
            vy = 0
        }

        if hypot(vx, vy) < 5 && tiempoQuieto < 0.12 {
            vx = velocidadGesto.width
            vy = -velocidadGesto.height
        }

        muestraAnterior = nil

        if hypot(vx, vy) < 5 {
            guardarPosicion()
            return
        }

        velocidad = CGVector(
            dx: min(max(vx, -2400), 2400),
            dy: min(max(vy, -2400), 2400)
        )

        ultimoTiempo = ahora - 1.0 / 60.0

        detenerFisica()

        let nuevoReloj = Timer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(actualizarFisica),
            userInfo: nil,
            repeats: true
        )

        reloj = nuevoReloj

        RunLoop.main.add(
            nuevoReloj,
            forMode: .common
        )

        actualizarFisica()
    }

    // MARK: - Rebotes

    private func registrarGolpe(_ nuevoBorde: Borde) {
        borde = nuevoBorde
        instanteGolpe = Date()
        golpes += 1
    }

    @objc private func actualizarFisica() {
        guard let panel else {
            detenerFisica()
            return
        }

        let ahora = ProcessInfo.processInfo.systemUptime

        let dt = min(
            max(ahora - ultimoTiempo, 0),
            0.035
        )

        ultimoTiempo = ahora

        var x = panel.frame.minX + velocidad.dx * dt
        var y = panel.frame.minY + velocidad.dy * dt

        let area = areaVisible

        let minX = area.minX
        let maxX = area.maxX - panel.frame.width
        let minY = area.minY
        let maxY = area.maxY - panel.frame.height

        if x < minX {
            x = minX + (minX - x)
            velocidad.dx = abs(velocidad.dx) * 0.72
            registrarGolpe(.izquierda)

        } else if x > maxX {
            x = maxX - (x - maxX)
            velocidad.dx = -abs(velocidad.dx) * 0.72
            registrarGolpe(.derecha)
        }

        if y < minY {
            y = minY + (minY - y)
            velocidad.dy = abs(velocidad.dy) * 0.72
            registrarGolpe(.inferior)

        } else if y > maxY {
            y = maxY - (y - maxY)
            velocidad.dy = -abs(velocidad.dy) * 0.72
            registrarGolpe(.superior)
        }

        panel.setFrameOrigin(
            NSPoint(x: x, y: y)
        )

        let friccion = pow(0.985, dt * 60)

        velocidad.dx *= friccion
        velocidad.dy *= friccion

        if hypot(velocidad.dx, velocidad.dy) < 6 {
            detenerFisica()
            guardarPosicion()
        }
    }

    private func detenerFisica() {
        reloj?.invalidate()
        reloj = nil
    }

    private func guardarPosicion() {
        guard let panel else { return }

        let posicion = panel.frame.origin

        UserDefaults.standard.set(
            [
                Double(posicion.x),
                Double(posicion.y)
            ],
            forKey: clavePosicion
        )
    }
}

// MARK: - Gotitas de impacto

struct GotasImpacto: View {
    @ObservedObject var motor: YTAppDelegate

    var body: some View {
        TimelineView(
            .animation(minimumInterval: 1.0 / 30.0)
        ) { linea in

            Canvas { contexto, tamano in
                let tiempo = linea.date.timeIntervalSince(
                    motor.instanteGolpe
                )

                guard tiempo >= 0 && tiempo < 0.38 else {
                    return
                }

                let progreso = CGFloat(tiempo / 0.38)

                for i in 0..<4 {
                    let angulo = -0.65 + Double(i) * 0.43
                    let seno = CGFloat(sin(angulo))
                    let coseno = CGFloat(cos(angulo))

                    var dx: CGFloat = 0
                    var dy: CGFloat = 0

                    switch motor.borde {
                    case .izquierda:
                        dx = -coseno
                        dy = seno
                    case .derecha:
                        dx = coseno
                        dy = seno
                    case .superior:
                        dx = seno
                        dy = -coseno
                    case .inferior:
                        dx = seno
                        dy = coseno
                    }

                    let distancia: CGFloat =
                        29 + progreso * 18

                    let radio: CGFloat = 2

                    let punto = CGRect(
                        x: tamano.width / 2
                            + dx * distancia - radio,
                        y: tamano.height / 2
                            + dy * distancia - radio,
                        width: radio * 2,
                        height: radio * 2
                    )

                    var pincel = contexto

                    pincel.opacity =
                        Double(1 - progreso) * 0.85

                    let color: Color = i.isMultiple(of: 2)
                        ? Color(
                            red: 0.63,
                            green: 0.43,
                            blue: 0.97
                        )
                        : Color(
                            red: 0.29,
                            green: 0.72,
                            blue: 1
                        )

                    pincel.fill(
                        Path(ellipseIn: punto),
                        with: .color(color)
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Indicador con progreso real

struct IndicadorFlotante: View {
    @ObservedObject var motor: YTAppDelegate
    @ObservedObject private var descargas = TubeEngine.shared

    @State private var girando = false
    @State private var ampliado = false

    var body: some View {
        ZStack {
            GotasImpacto(motor: motor)

            ZStack {
                Hexagono()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(
                                    red: 1,
                                    green: 0.46,
                                    blue: 0.40
                                ),
                                Color(
                                    red: 0.96,
                                    green: 0.09,
                                    blue: 0.26
                                ),
                                Color(
                                    red: 0.58,
                                    green: 0,
                                    blue: 0.24
                                )
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .rotationEffect(
                        .degrees(girando ? 360 : 0)
                    )
                    .animation(
                        .linear(duration: 1.4)
                            .repeatForever(
                                autoreverses: false
                            ),
                        value: girando
                    )

                VStack(spacing: -2) {
                    Text("\(descargas.porcentaje)%")
                        .font(
                            .system(
                                size: ampliado ? 19 : 15,
                                weight: .black,
                                design: .rounded
                            )
                        )
                        .monospacedDigit()

                    if ampliado {
                        Text(
                            "\(descargas.completados) / \(descargas.total)"
                        )
                        .font(
                            .system(
                                size: 11,
                                weight: .bold,
                                design: .rounded
                            )
                        )
                        .monospacedDigit()
                        .transition(.opacity)
                    }
                }
                .foregroundStyle(.white)
            }
            .frame(
                width: ampliado ? 76 : 53,
                height: ampliado ? 76 : 53
            )
            .phaseAnimator(
                [1.0, 0.88, 1.04, 1.0],
                trigger: motor.golpes
            ) { contenido, fase in

                let horizontal =
                    motor.borde == .izquierda ||
                    motor.borde == .derecha

                contenido.scaleEffect(
                    x: horizontal ? fase : 2 - fase,
                    y: horizontal ? 2 - fase : fase
                )

            } animation: { _ in
                .easeOut(duration: 0.075)
            }
            .animation(
                .easeInOut(duration: 0.2),
                value: ampliado
            )
        }
        .frame(width: 110, height: 110)
        .contentShape(Rectangle())
        .onHover { encima in
            withAnimation(.easeInOut(duration: 0.2)) {
                ampliado = encima
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { _ in
                    motor.arrastrar(
                        hasta: NSEvent.mouseLocation
                    )
                }
                .onEnded { gesto in
                    motor.soltar(
                        velocidadGesto: gesto.velocity
                    )
                }
        )
        .onAppear {
            girando = true
        }
    }
}

