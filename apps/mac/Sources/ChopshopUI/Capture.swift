import AppKit
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

    static func snap(to path: String, sheet: Bool = false) -> Bool {
        guard let main = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0.sheetParent == nil }),
              let win = sheet ? main.attachedSheet : main else { return false }
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
