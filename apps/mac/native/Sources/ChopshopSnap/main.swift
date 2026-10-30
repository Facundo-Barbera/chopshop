import AppKit
import ChopshopNative

let args = Array(CommandLine.arguments.dropFirst())
let out = args.first ?? "/tmp/chopshop-snaps"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
_ = NSApplication.shared
if let mode = args.dropFirst().first, mode == "demo" || mode == "demo-keys" {
    MainActor.assumeIsolated {
        let keys: [(String, Double)] = [("01-vacio", 1.5), ("02-salas-suben", 3.1), ("03-escritorios-brotan", 5.6), ("04-cables", 9.0),
                                        ("05-trabajando", 15.0), ("06-pregunta", 22.0), ("07-atascada", 25.5), ("08-crece", 29.0),
                                        ("09-respondida", 35.0), ("10-en-calma", 54.0)]
        for (name, t) in keys { Snapshots.renderDemo(t: t, to: "\(out)/key-\(name).png"); print("ok \(name)") }
        if mode == "demo-keys" { return }
        try? FileManager.default.createDirectory(atPath: "\(out)/seq", withIntermediateDirectories: true)
        let fps = 12.0, n = Int(Snapshots.demoDuration * fps)
        for k in 0..<n {
            Snapshots.renderDemo(t: Double(k) / fps, width: 1120, height: 720, scale: 1.25, jpeg: true, to: String(format: "\(out)/seq/f%04d.jpg", k))
            if k % 60 == 0 { print("seq \(k)/\(n)") }
        }
        print("done seq \(n)")
    }
    exit(0)
}
if let mode = args.dropFirst().first, mode == "city-keys" || mode == "city-video" {
    MainActor.assumeIsolated {
        let tl = CityTimeline.bundled()
        if mode == "city-keys" {
            let keys: [(String, Double, Bool)] = [("01-ciudad", 10.6, true), ("02-subiendo", 2.4, true), ("03-ambar-rojo", 10.2, true),
                                                  ("04-zoom-mitad", 14.2, true), ("05-paredes", 16.0, true), ("06-oficina", 19.0, true),
                                                  ("07-claro", 10.6, false)]
            for (name, t, dark) in keys {
                Snapshots.renderCity(timeline: tl, t: t, dark: dark, scale: 1, to: "\(out)/city-\(name).png")
                print("ok city-\(name)")
            }
            return
        }
        let path = args.count > 2 ? args[2] : "\(out)/city.mp4"
        let ok = Snapshots.renderCityVideo(timeline: tl, to: path, width: 1400, height: 900, fps: 30) { k, n in
            if k % 90 == 0 { print("vídeo \(k)/\(n)"); fflush(stdout) }
        }
        print(ok ? "ok \(path)" : "error: no se pudo escribir \(path)")
    }
    exit(0)
}
if let mode = args.dropFirst().first, mode == "machine-room" {
    MainActor.assumeIsolated {
        for dark in [true, false] {
            Snapshots.renderMachineRoom(dark: dark, to: "\(out)/machine-room-\(dark ? "dark" : "light").png")
            print("ok machine-room-\(dark ? "dark" : "light")")
        }
    }
    exit(0)
}
if let mode = args.dropFirst().first, mode == "shell" {
    MainActor.assumeIsolated { Snapshots.renderShell(to: out) }
    exit(0)
}
if let mode = args.dropFirst().first, mode == "floor" || mode == "city-office" {
    MainActor.assumeIsolated {
        if mode == "floor" { Snapshots.renderFloors(to: out) } else { Snapshots.renderCityOffice(to: out) }
    }
    exit(0)
}
MainActor.assumeIsolated {
    for p in ["nuskills", "bixku-utilities", "chopshop"] {
        for dark in [true, false] {
            let h: CGFloat = p == "nuskills" ? 1060 : 860
            Snapshots.render(project: p, dark: dark, time: 2.0, height: h, to: "\(out)/\(p)-\(dark ? "dark" : "light").png")
        }
    }
    Snapshots.render(project: "nuskills", dark: true, time: 3.3, height: 1060, to: "\(out)/nuskills-dark-t2.png")
    Snapshots.render(project: "nuskills", dark: true, time: 2.0, selected: "n9", height: 1060, to: "\(out)/nuskills-dark-selected.png")
    Snapshots.render(project: "nuskills", dark: false, time: 2.0, selected: "n9", height: 1060, to: "\(out)/nuskills-light-selected.png")
    Snapshots.renderOffice(project: "nuskills", dark: true, hovered: "n4", to: "\(out)/office-hover-dark.png")
    Snapshots.renderOffice(project: "nuskills", dark: false, hovered: "n9", to: "\(out)/office-hover-light.png")
}
