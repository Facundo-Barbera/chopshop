import SwiftUI
import AppKit

#if NATIVE_PREVIEWS
public extension CityTimeline {
    /// `city-fixture.jsonl` incluido en el banco de pruebas (apps/mac/native).
    static func bundled(target: String = CityTimeline.defaultTarget) -> CityTimeline {
        guard let url = Bundle.module.url(forResource: "city-fixture", withExtension: "jsonl"),
              let data = try? Data(contentsOf: url) else { return CityTimeline(envelopes: [], target: target) }
        return CityTimeline(jsonl: data, target: target)
    }
}
#endif

/// Capturas y vídeo de la ciudad (los usa `ChopshopSnap city-keys` / `city-video`). Deterministas: cada fotograma es
/// `CityTimeline.frame(at: t)` con el tiempo congelado (como `renderDemo`).
@available(macOS 26.0, *)
@MainActor
public extension Snapshots {
    /// Un fotograma de la cronología de la ciudad en `t` (PNG, o JPEG con `jpeg`).
    static func renderCity(timeline: CityTimeline, t: Double, dark: Bool = true, width: CGFloat = 1400, height: CGFloat = 900,
                           scale: CGFloat = 1, jpeg: Bool = false, to path: String) {
        // frente 4: pendiente
    }

    /// La cronología completa como MP4 H.264 (AVAssetWriter + CVPixelBuffer), `fps` fotogramas por segundo.
    /// Devuelve false si no pudo escribir el vídeo.
    @discardableResult
    static func renderCityVideo(timeline: CityTimeline, to path: String, dark: Bool = true, width: Int = 1400, height: Int = 900,
                                fps: Double = CityTimeline.fps, duration: Double = CityTimeline.duration,
                                progress: ((Int, Int) -> Void)? = nil) -> Bool {
        // frente 4: pendiente
        return false
    }
}
