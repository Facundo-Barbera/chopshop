import AppKit
import Foundation

/// Captura de pantalla desde dentro de la app (para documentación/iteración de diseño).
/// `screencapture` por ssh no tiene permiso de grabación de pantalla; una app sí puede
/// leer sus propias ventanas. Protocolo: escribir "<sección> <ruta.png>" en /tmp/chopshop-shot.req.
@MainActor
enum Capture {
    static let requestPath = "/tmp/chopshop-shot.req"

    static func watch(model: AppModel) {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in poll(model) }
        }
    }

    private static func poll(_ model: AppModel) {
        guard let txt = try? String(contentsOfFile: requestPath, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: requestPath)
        let parts = txt.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        // al frente: con Stage Manager, una ventana de fondo se captura como miniatura
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
        if parts[0].hasPrefix("click:") {
            // `click:<x>,<y> <salida.png>`: clic en esos puntos de la ventana (origen arriba a la izquierda) y captura tras el zoom
            let xy = parts[0].dropFirst(6).split(separator: ",").compactMap { Double($0) }
            if xy.count == 2 { click(x: xy[0], y: xy[1]) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                let ok = snap(to: parts[1])
                try? (ok ? "ok" : "fail").write(toFile: parts[1] + ".done", atomically: true, encoding: .utf8)
            }
            return
        }
        if parts[0].hasPrefix("project:") { model.nav = .project(String(parts[0].dropFirst(8))) }
        else if parts[0].hasPrefix("machine:") { model.nav = .machine(String(parts[0].dropFirst(8))) }
        else if let s = Section(rawValue: parts[0]) { model.nav = s == .machines ? .machines : .section(s) }
        let out = parts[1]
        // JS opcional (scroll, expandir filas…) en /tmp/chopshop-shot.js
        var delay = 1.2
        if let js = try? String(contentsOfFile: "/tmp/chopshop-shot.js", encoding: .utf8) {
            try? FileManager.default.removeItem(atPath: "/tmp/chopshop-shot.js")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { model.web?.evaluateJavaScript(js, completionHandler: nil) }
            delay = 2.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let ok = snap(to: out)
            try? (ok ? "ok" : "fail").write(toFile: out + ".done", atomically: true, encoding: .utf8)
        }
    }

    private static var mainWindow: NSWindow? { NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) }

    /// Clic dentro del proceso (sin permiso de Accesibilidad): mouseDown/mouseUp entregados a la ventana principal.
    static func click(x: Double, y: Double) {
        guard let win = mainWindow else { return }
        let p = NSPoint(x: x, y: win.frame.height - y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                win.sendEvent(e)
            }
        }
    }

    static func snap(to path: String) -> Bool {
        guard let win = mainWindow else { return false }
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return false }
        let fn = unsafeBitCast(sym, to: Fn.self)
        // 8 = kCGWindowListOptionIncludingWindow; 1|8 = boundsIgnoreFraming | bestResolution
        guard let img = fn(.null, 8, UInt32(win.windowNumber), 9)?.takeRetainedValue() else { return false }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
