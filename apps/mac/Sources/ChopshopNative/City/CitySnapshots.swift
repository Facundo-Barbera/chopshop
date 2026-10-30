import SwiftUI
import AppKit
import AVFoundation
import CoreVideo

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

/// Lo que pinta la cronología en `t`: fotograma, instantánea (con el reloj del fixture) y zoom fijo. Lo comparten las capturas,
/// el vídeo y el playground.
@available(macOS 26.0, *)
struct CityTimelineState {
    let frame: CityTimeline.Frame
    let snapshot: MockSnapshot
    let zoom: CityFocus?
    /// Reloj del fixture en `t` (semivida de los pisos v3).
    let now: Date

    init(timeline: CityTimeline, t: Double) {
        let f = timeline.frame(at: t)
        let t0: Date = timeline.envelopes.lazy.compactMap { SnapshotMapper.date($0.ts) }.first ?? Date(timeIntervalSince1970: 0)
        frame = f
        now = t0.addingTimeInterval(t)
        snapshot = SnapshotMapper.snapshot(f.state, now: now)
        zoom = t >= CityTimeline.zoomStart ? CityFocus(project: timeline.target, p: CityTimeline.zoom(t)) : nil
    }

    /// Fundido de la cabecera "ciudad" → proyecto (el mismo que la cabecera de la tarjeta).
    var chrome: Double { zoom.map { CityTransition.chrome($0.p) } ?? 0 }

    /// La ciudad congelada en `t` (crecimiento y zoom de la cronología).
    func cityView(t: Double) -> CityView {
        CityView(model: frame.model, lights: frame.lights, snapshot: snapshot, state: frame.state, frozenTime: t, frozenNow: now, growth: t,
                 frozenZoom: zoom, flatChrome: true)
    }
}

/// Fotograma de captura/vídeo: barra de título emulada (ImageRenderer no dibuja la toolbar) + la ciudad, como `Snapshots.Frame`.
@available(macOS 26.0, *)
struct CitySnapshotFrame: View {
    let timeline: CityTimeline
    let t: Double
    let dark: Bool

    var body: some View {
        let s = CityTimelineState(timeline: timeline, t: t)
        let ch: Double = s.chrome
        let pr: String = timeline.target
        let model: CityModel = s.frame.model
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ZStack(alignment: .leading) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("ciudad").font(.headline)
                        Text("\(model.campuses.count) empresas · \(model.projectCount) proyectos")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .opacity(CityTransition.chromeOut(ch))
                    if ch > 0 {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(pr).font(.headline)
                            Text(ProjectContent.subtitle(s.snapshot.summary(of: pr))).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .opacity(CityTransition.chromeIn(ch))
                    }
                }
                Spacer()
                MachineStatusLabel(machines: s.snapshot.machines)
            }
            .padding(.horizontal, 20).frame(height: 48)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            s.cityView(t: t)
                .padding(.horizontal, 26).padding(.vertical, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

/// Bandera de fin de `finishWriting` (el completion llega en otra cola).
private final class CityWriteDone: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var done: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// Capturas y vídeo de la ciudad (los usa `ChopshopSnap city-keys` / `city-video`). Deterministas: cada fotograma es
/// `CityTimeline.frame(at: t)` con el tiempo congelado (como `renderDemo`).
@available(macOS 26.0, *)
@MainActor
public extension Snapshots {
    /// Un fotograma de la cronología de la ciudad en `t` (PNG, o JPEG con `jpeg`).
    static func renderCity(timeline: CityTimeline, t: Double, dark: Bool = true, width: CGFloat = 1400, height: CGFloat = 900,
                           scale: CGFloat = 1, jpeg: Bool = false, to path: String) {
        NSApp?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let v = CitySnapshotFrame(timeline: timeline, t: t, dark: dark).frame(width: width, height: height)
        let r = ImageRenderer(content: v); r.scale = scale
        guard let cg = r.cgImage else { print("sin imagen: \(path)"); return }
        let rep = NSBitmapImageRep(cgImage: cg)
        let data: Data? = jpeg ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88])
                               : rep.representation(using: .png, properties: [:])
        guard let data else { print("sin imagen: \(path)"); return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// La cronología completa como MP4 H.264 (AVAssetWriter + CVPixelBuffer), `fps` fotogramas por segundo.
    /// Devuelve false si no pudo escribir el vídeo.
    @discardableResult
    static func renderCityVideo(timeline: CityTimeline, to path: String, dark: Bool = true, width: Int = 1400, height: Int = 900,
                                fps: Double = CityTimeline.fps, duration: Double = CityTimeline.duration,
                                progress: ((Int, Int) -> Void)? = nil) -> Bool {
        NSApp?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: path) { try? fm.removeItem(at: url) }

        guard fps > 0, width > 0, height > 0, let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: 12_000_000,
            AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
            AVVideoMaxKeyFrameIntervalKey: Int(fps.rounded()) * 2,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ]
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ] as [String: Any],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { print("vídeo: \(writer.error?.localizedDescription ?? "no arranca")"); return false }
        writer.startSession(atSourceTime: .zero)

        let n = max(1, Int(duration * fps))
        let timescale = CMTimeScale(max(1, Int32(fps.rounded())))
        let space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let w = CGFloat(width), h = CGFloat(height)

        for k in 0..<n {
            let t = Double(k) / fps
            let v = CitySnapshotFrame(timeline: timeline, t: t, dark: dark).frame(width: w, height: h)
            let r = ImageRenderer(content: v); r.scale = 1
            guard let cg = r.cgImage else { print("vídeo: sin imagen en \(k)"); writer.cancelWriting(); return false }

            var pbOut: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pbOut)
            }
            if pbOut == nil {
                CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pbOut)
            }
            guard let pb = pbOut else { writer.cancelWriting(); return false }

            CVPixelBufferLockBaseAddress(pb, [])
            var drawn = false
            if let base = CVPixelBufferGetBaseAddress(pb),
               let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: space, bitmapInfo: bitmapInfo) {
                ctx.setFillColor(CGColor(gray: dark ? 0 : 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                drawn = true
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            guard drawn else { writer.cancelWriting(); return false }

            // el hilo principal tiene que seguir girando (ImageRenderer y el codificador)
            while !input.isReadyForMoreMediaData {
                if writer.status != .writing { print("vídeo: \(writer.error?.localizedDescription ?? "falló")"); return false }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.002))
            }
            if !adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(k), timescale: timescale)) {
                print("vídeo: \(writer.error?.localizedDescription ?? "no añade el fotograma \(k)")")
                writer.cancelWriting()
                return false
            }
            progress?(k, n)
        }

        input.markAsFinished()
        let done = CityWriteDone()
        writer.finishWriting { done.set() }
        while !done.done { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
        if writer.status != .completed { print("vídeo: \(writer.error?.localizedDescription ?? "no terminó")") }
        return writer.status == .completed
    }
}
