import AppKit
import ChopshopNative
import Foundation

/// Captura de pantalla desde dentro de la app (para documentación/iteración de diseño).
/// `screencapture` por ssh no tiene permiso de grabación de pantalla; una app sí puede
/// leer sus propias ventanas. Protocolo: escribir "<sección> <ruta.png>" en /tmp/chopshop-shot.req.
/// `settings` abre la hoja de ajustes y captura la hoja; cualquier otra sección la cierra.
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
        if parts[0].hasPrefix("size:") {
            // `size:<ancho>x<alto> <salida.png>`: la ventana a ese tamaño (puntos), arriba a la izquierda de su pantalla
            let wh = parts[0].dropFirst(5).split(separator: "x").compactMap { Double($0) }
            if wh.count == 2, let win = mainWindow, let scr = win.screen ?? NSScreen.main {
                win.setFrame(NSRect(x: scr.frame.minX, y: scr.frame.maxY - wh[1], width: wh[0], height: wh[1]), display: true)
            }
            after(2.5, parts[1])
            return
        }
        if parts[0].hasPrefix("drag:") {
            // `drag:<x>,<y>,<dx>,<dy> <salida.png>`: arrastre de ~1 s (120 eventos/s) y, en la salida `.txt` hermana, los fotogramas
            let v = parts[0].dropFirst(5).split(separator: ",").compactMap { Double($0) }
            if v.count == 4 { drag(x: v[0], y: v[1], dx: v[2], dy: v[3], report: parts[1]) }
            return
        }
        let sheet = parts[0] == "settings"
        model.showSettings = sheet
        if sheet {
            // la hoja se abre encima de la sección actual
        } else if parts[0].hasPrefix("project:") { model.nav = .project(String(parts[0].dropFirst(8))) }
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
            let ok = snap(to: out, sheet: sheet)
            try? (ok ? "ok" : "fail").write(toFile: out + ".done", atomically: true, encoding: .utf8)
        }
    }

    private static func after(_ s: Double, _ out: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s) {
            let ok = snap(to: out)
            try? (ok ? "ok" : "fail").write(toFile: out + ".done", atomically: true, encoding: .utf8)
        }
    }

    private static func mouse(_ type: NSEvent.EventType, _ win: NSWindow, _ x: Double, _ y: Double) {
        if let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: win.frame.height - y), modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 1) {
            win.sendEvent(e)
        }
    }

    /// Arrastre sintético dentro del proceso: 120 pasos en ~1 s. Al terminar escribe `FrameMeter.summary()` en `<out>` y captura.
    static func drag(x: Double, y: Double, dx: Double, dy: Double, report out: String) {
        guard let win = mainWindow else { return }
        FrameMeter.reset()
        mouse(.leftMouseDown, win, x, y)
        let n = 120
        for k in 1...n {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) / 120) {
                let f: Double = Double(k) / Double(n)
                let px: Double = x + dx * f, py: Double = y + dy * f
                mouse(.leftMouseDragged, win, px, py)
                if k == n {
                    mouse(.leftMouseUp, win, x + dx, y + dy)
                    let txt = FrameMeter.summary()
                    NSLog("%@", "FrameMeter\n" + txt)
                    try? txt.write(toFile: out + ".txt", atomically: true, encoding: .utf8)
                    after(0.5, out)
                }
            }
        }
    }

    /// Ventana principal (con título y que no sea una hoja).
    private static var mainWindow: NSWindow? {
        NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0.sheetParent == nil })
    }

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

    static func snap(to path: String, sheet: Bool = false) -> Bool {
        guard let main = mainWindow, let win = sheet ? main.attachedSheet : main else { return false }
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
