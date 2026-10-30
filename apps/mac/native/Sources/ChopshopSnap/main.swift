import AppKit
import ChopshopNative

// uso: ChopshopSnap <directorio de salida> [demo|demo-keys|city-keys|city-video [vídeo.mp4]|machine-room|floor|stable-floor|city-office|real-office|shell|login|roles|settings|multimachine [fixture]]
//   sin 2º argumento: capturas de proyecto/oficina
//   demo: fotogramas clave de la demo (key-*.png) + secuencia seq/f0000.jpg a 12 fps (demo-keys: solo las claves)
//   city-keys: claves de la ciudad (city-0N-*.png, 1400×900 @1x) desde city-fixture.jsonl
//   city-video: la cronología de la ciudad en MP4 H.264, 1400×900 a 30 fps (por defecto <salida>/city.mp4)
//   machine-room: panel de la sala de máquinas de Awesome GB desde machine-room-fixture.jsonl (machine-room-dark/-light.png)
//   floor: previews de FloorOfficeView (floor-*.png: piso Producto con su sala de máquinas oscuro/claro, triage seleccionado,
//          armario del repo principal seleccionado, vestíbulo)
//   city-office: ciudad v3 de CityOfficeFixture (city-office-*.png: varios pisos y vestíbulo, zoom al piso Docs y el piso montado,
//                zoom al piso Producto con la sala de máquinas)
//   shell: armazón de la oficina sobre CityOfficeFixture (shell-*.png: HUD, minimapa, paneles Atención/Lotes, hilo, paleta)
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
if let mode = args.dropFirst().first, mode == "settings" {
    MainActor.assumeIsolated { Snapshots.renderAccountSettings(to: out) }
    exit(0)
}
if let mode = args.dropFirst().first, mode == "login" {
    MainActor.assumeIsolated { Snapshots.renderBackendLogin(to: out) }
    exit(0)
}
if let mode = args.dropFirst().first, mode == "machines" {
    MainActor.assumeIsolated { Snapshots.renderMachines(to: out) }
    exit(0)
}
if let mode = args.dropFirst().first, mode == "watchers" {
    MainActor.assumeIsolated { Snapshots.renderWatchers(to: out) }
    exit(0)
}
if let mode = args.dropFirst().first, mode == "roles" {
    MainActor.assumeIsolated { Snapshots.renderEmployeesScreen(to: out) }
    exit(0)
}
if let mode = args.dropFirst().first, mode == "real-office" {
    MainActor.assumeIsolated { Snapshots.renderRealOffice(to: out) }
    exit(0)
}
if let mode = args.dropFirst().first, mode == "stable-floor" {
    MainActor.assumeIsolated { Snapshots.renderStableFloor(to: out) }
    exit(0)
}
if let mode = args.dropFirst().first, mode == "employees" {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../..").standardized
    let office = repo.appendingPathComponent("packages/api/fixtures/snapshot.office.json").path
    let fixture = args.count > 2 ? args[2] : office
    MainActor.assumeIsolated { Snapshots.renderEmployees(fixture: fixture, office: args.count > 3 ? args[3] : office, to: out) }
    exit(0)
}
if let mode = args.dropFirst().first, mode == "multimachine" {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../..").standardized
    let fixture = args.count > 2 ? args[2] : repo.appendingPathComponent("packages/api/fixtures/relay.multimachine.json").path
    MainActor.assumeIsolated { Snapshots.renderMultiMachine(fixture: fixture, to: out) }
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
