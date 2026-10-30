import SwiftUI
import AppKit
import ChopshopNative

@available(macOS 26.0, *)
struct FloorLabApp: App {
    @NSApplicationDelegateAdaptor(FloorLabDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Chopshop · FloorLab") {
            FloorLabRoot()
                .frame(minWidth: 1100, minHeight: 700)
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified)
    }
}

@available(macOS 26.0, *)
struct FloorLabRoot: View {
    @State private var config = FloorLabConfig()
    @State private var mode: FloorLabMode = .floor
    @State private var floor = 0
    @State private var campus: String?
    @State private var zoomThreshold = 0.55
    @State private var layerOpacity = 0.18

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 290, ideal: 330, max: 420)
        } detail: {
            FloorLabView(config: config, mode: mode, floor: min(floor, config.floorCount - 1), campus: campus,
                         zoomThreshold: zoomThreshold, layerOpacity: layerOpacity, onPickCampus: { campus = $0 })
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .navigationTitle("FloorLab")
                .navigationSubtitle(subtitle)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Picker("Modo", selection: $mode) {
                            ForEach(FloorLabMode.allCases) { m in Text(m.title).tag(m) }
                        }
                        .pickerStyle(.segmented)
                    }
                    ToolbarItemGroup {
                        Button("Piso inferior", systemImage: "chevron.down") { step(-1) }
                            .keyboardShortcut(.downArrow, modifiers: [])
                            .disabled(mode == .campus || floor <= 0)
                        Button("Piso superior", systemImage: "chevron.up") { step(1) }
                            .keyboardShortcut(.upArrow, modifiers: [])
                            .disabled(mode == .campus || floor >= config.floorCount - 1)
                    }
                }
                .background {
                    Group {
                        Button("") { step(-1) }.keyboardShortcut(.pageDown, modifiers: [])
                        Button("") { step(1) }.keyboardShortcut(.pageUp, modifiers: [])
                    }
                    .opacity(0)
                    .allowsHitTesting(false)
                }
        }
        .onChange(of: config.floors) { _, _ in floor = min(floor, config.floorCount - 1) }
        .onChange(of: config.companies) { _, _ in
            if let c = campus, !config.campusNames.contains(c) { campus = nil }
        }
    }

    private func step(_ d: Int) {
        guard mode != .campus else { return }
        floor = min(max(0, min(floor, config.floorCount - 1) + d), config.floorCount - 1)
    }

    private var subtitle: String {
        switch mode {
        case .floor: return config.floorTitle(min(floor, config.floorCount - 1))
        case .building: return "\(config.floorTitle(min(floor, config.floorCount - 1))) · \(config.floorCount) pisos y vestíbulo"
        case .campus: return campus ?? "Toda la ciudad"
        }
    }

    private var sidebar: some View {
        Form {
            Section("Vista") {
                Picker("Modo", selection: $mode) {
                    ForEach(FloorLabMode.allCases) { m in Text(m.title).tag(m) }
                }
                Picker("Piso", selection: $floor) {
                    ForEach(0..<config.floorCount, id: \.self) { k in Text(config.floorTitle(k)).tag(k) }
                }
                .disabled(mode == .campus)
                Picker("Campus", selection: $campus) {
                    Text("Toda la ciudad").tag(String?.none)
                    ForEach(config.campusNames, id: \.self) { c in Text(c).tag(String?.some(c)) }
                }
                .disabled(mode != .campus)
            }
            Section("Capas") {
                fraction("Umbral de zoom", $zoomThreshold, 0.1...1.5)
                fraction("Opacidad inactivas", $layerOpacity, 0...1)
            }
            .disabled(mode != .building)
            Section("Huella") {
                slider("Ancho", $config.width, 300...2600)
                slider("Fondo", $config.depth, 300...2600)
                Button("Huella por defecto") {
                    config.width = FloorLabConfig.defaultWidth
                    config.depth = FloorLabConfig.defaultDepth
                }
            }
            Section("Edificio") {
                Stepper("Pisos: \(config.floors)", value: $config.floors, in: 1...8)
                Stepper("Roles por piso: \(config.roles)", value: $config.roles, in: 0...12)
                Stepper("Escritorios por rol: \(config.desksPerRole)", value: $config.desksPerRole, in: 1...16)
                Stepper("Salas de máquinas: \(config.machineRooms)", value: $config.machineRooms, in: 0...6)
                Toggle("Oficina de Grok", isOn: $config.grok)
            }
            Section("Ciudad") {
                Stepper("Empresas: \(config.companies)", value: $config.companies, in: 1...10)
                Stepper("Proyectos por empresa: \(config.projectsPerCompany)", value: $config.projectsPerCompany, in: 1...8)
            }
            Section("Semillas") {
                LabeledContent("Edificio") { Text(hex(config.buildingSeed)).font(.callout.monospaced()) }
                Button("Re-tirar semilla del edificio") { config.buildingSeed = UInt64.random(in: 1...UInt64.max) }
                LabeledContent("Setup") { Text(hex(config.setupSeed)).font(.callout.monospaced()) }
                Button("Re-tirar semilla del setup") { config.setupSeed = UInt64.random(in: 1...UInt64.max) }
                Button("Restablecer todo") { config = FloorLabConfig() }
            }
        }
        .formStyle(.grouped)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: 10)
        }
    }

    private func fraction(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func hex(_ v: UInt64) -> String { String(v, radix: 16) }
}

final class FloorLabDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

func relaunchAsBundle() -> Bool {
    guard Bundle.main.bundleURL.pathExtension != "app", let exe = Bundle.main.executableURL?.resolvingSymlinksInPath(),
          let info = Bundle.main.infoDictionary else { return false }
    let fm = FileManager.default
    let app = exe.deletingLastPathComponent().appendingPathComponent("FloorLab.app")
    let macos = app.appendingPathComponent("Contents/MacOS")
    do {
        try? fm.removeItem(at: app)
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.copyItem(at: exe, to: macos.appendingPathComponent("FloorLab"))
        let plist = info.filter { $0.key.hasPrefix("CF") || $0.key.hasPrefix("NS") }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--deep", "--sign", "-", app.path]
        try sign.run()
        sign.waitUntilExit()
    } catch {
        return false
    }
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = true
    cfg.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: app, configuration: cfg) { _, err in
        if let err { print("FloorLab: \(err.localizedDescription)") }
        exit(err == nil ? 0 : 1)
    }
    RunLoop.main.run()
    return true
}

if relaunchAsBundle() { exit(0) }
if #available(macOS 26.0, *) {
    FloorLabApp.main()
} else {
    print("FloorLab necesita macOS 26.")
    exit(1)
}
